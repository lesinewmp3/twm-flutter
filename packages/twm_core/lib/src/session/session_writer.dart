import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

import '../digitizer/virtual_digitizer.dart';
import 'record_file.dart';

/// Data of one acquired record for the session header.
class RecordEntry {
  final String file; // relative path, e.g. RAW\G0001-A0001.mat
  final int samplesCount;
  final double increment;
  final List<double> gains;
  final List<double> offsets;
  final List<double> timestamps;
  final DateTime absoluteTime;
  final double aperture;
  final List<double> temperatures;

  /// Sub-record (or multiplexer cycle) sample offsets and time stamps.
  final List<int> subRecordOffsets;
  final List<double> subRecordTimestamps;

  const RecordEntry({
    required this.file,
    required this.samplesCount,
    required this.increment,
    required this.gains,
    required this.offsets,
    required this.timestamps,
    required this.absoluteTime,
    this.aperture = 0,
    this.temperatures = const [],
    this.subRecordOffsets = const [],
    this.subRecordTimestamps = const [],
  });
}

/// Setup of a measurement group (constant for all its records).
class GroupSetup {
  final int samplesCount; // per sub-record
  final double fs;
  final List<double> ranges;
  final TriggerConfig trigger;
  final int bitResolution;
  final int subRecordsCount;
  final List<DeviceAttribute> attributes;

  const GroupSetup({
    required this.samplesCount,
    required this.fs,
    required this.ranges,
    required this.trigger,
    required this.bitResolution,
    this.subRecordsCount = 1,
    this.attributes = const [],
  });
}

/// Writer of the TWM measurement session folder:
/// ```
///   session.info       measurement header
///   qwtb.info          processing setup
///   RAW/Gxxxx-Axxxx.mat
///   DIGITIZER/...      copy of digitizer corrections
///   TRANSDUCERS/Txx/   copies of transducer corrections
///   RESULTS/           written by the processing module (Octave)
/// ```
/// Format follows `tpq_load_record.m` and `twm_selftest.m`.
class SessionWriter {
  final String root;
  final List<String> channelDescriptors;
  final List<String> auxDescriptors;
  final bool temperatureAvailable;
  final bool temperatureLogAvailable;
  final List<DeviceAttribute> sessionAttributes;
  final MultiplexerConfig? multiplexer;
  final String comment;

  final List<GroupSetup> _groups = [];
  final List<List<RecordEntry>> _records = [];
  Info? _setupSection;

  SessionWriter({
    required this.root,
    required this.channelDescriptors,
    this.auxDescriptors = const [],
    this.temperatureAvailable = false,
    this.temperatureLogAvailable = false,
    this.sessionAttributes = const [],
    this.multiplexer,
    this.comment = '',
  });

  String get headerPath => p.join(root, 'session.info');
  int get groupsCount => _groups.length;

  static String recordName(int group, int repetition) =>
      'G${group.toString().padLeft(4, '0')}-A${repetition.toString().padLeft(4, '0')}.mat';

  /// Relative path as stored in the header (DOS separators like TWM).
  static String recordRelPath(int group, int repetition) => 'RAW\\${recordName(group, repetition)}';

  String recordAbsPath(int group, int repetition) => p.join(root, 'RAW', recordName(group, repetition));

  Future<RecordFileWriter> openRecord(int group, int repetition, {required bool int16}) =>
      RecordFileWriter.create(recordAbsPath(group, repetition), channelDescriptors.length, int16: int16);

  /// Starts a new measurement group; returns its 1-based index.
  int addGroup(GroupSetup g) {
    _groups.add(g);
    _records.add([]);
    return _groups.length;
  }

  void addRecord(int group, RecordEntry r) => _records[group - 1].add(r);

  int recordsCount(int group) => _records[group - 1].length;

  // ---------------------------------------------------------- corrections --

  /// Copies corrections into the session folder and creates the section
  /// 'measurement setup configuration'.
  Future<void> storeCorrections(CorrectionsConfig corr, {int adcChannels = 0}) async {
    final s = Info();
    // digitizer
    var digRel = '';
    if (corr.digitizerPath.isNotEmpty && File(corr.digitizerPath).existsSync()) {
      digRel = await _copyCorrection(corr.digitizerPath, 'DIGITIZER', null);
    }
    // transducers
    final trPaths = <String>[];
    final phases = <int>[];
    final map = <List<int>>[];
    final mpx = <int>[];
    final inv = <int>[];
    final mux = multiplexer;
    for (var k = 0; k < corr.transducers.length; k++) {
      final t = corr.transducers[k];
      var src = t.path;
      if (!p.isAbsolute(src) && corr.transducersRoot.isNotEmpty) {
        src = p.join(corr.transducersRoot, src);
      }
      final tdir = 'T${(k + 1).toString().padLeft(2, '0')}';
      trPaths.add(await _copyCorrection(src, 'TRANSDUCERS', tdir));
      phases.add(t.phaseIndex);
      map.add([t.highChannel, t.lowChannel]);
      if (mux != null && mux.enabled) {
        final i = mux.sequence.indexOf(t.multiplexerPath);
        mpx.add(i < 0 ? 1 : i + 1);
      } else {
        mpx.add(1);
      }
      inv.add(t.inverted ? 1 : 0);
    }
    s.comment('relative path to the digitizer corrections:');
    s.setText('digitizer corrections path', digRel);
    s.comment('relative paths to the transducer corrections (one per transducer):');
    s.setTextList('transducer paths', trPaths);
    s.comment('phase index of each transducer:');
    s.setVector('channel phase indexes', phases);
    s.comment('mapping of the transducers to digitizer channels (high; low), 0 - not used:');
    s.setMatrix('transducer to digitizer channels mapping', map);
    s.comment('index of multiplexer cycle for each transducer:');
    s.setVector('transducer to multiplexing cycle mapping', mpx);
    s.comment('transducer inverted polarity flag:');
    s.setVector('transducer inverted', inv);
    _setupSection = s;
  }

  /// Copies folder containing the correction INFO file and returns relative
  /// path of the copied INFO file. Folder copy keeps relative CSV/channel links.
  Future<String> _copyCorrection(String infoPath, String dest, String? rename) async {
    final file = File(infoPath);
    if (!file.existsSync()) {
      throw FileSystemException('Correction file not found', infoPath);
    }
    var srcDir = file.parent;
    // digitizer corrections may reference '..\channel\x.info'
    final txt = await file.readAsString();
    if (RegExp(r'^\s*\.\.[\\/]', multiLine: true).hasMatch(txt)) {
      srcDir = srcDir.parent;
    }
    final name = rename ?? p.basename(srcDir.path);
    final dst = Directory(p.join(root, dest, name));
    await _copyDir(srcDir, dst);
    final rel = p.relative(infoPath, from: srcDir.path);
    return [dest, name, ...p.split(rel)].join('\\');
  }

  static Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(recursive: false)) {
      final target = p.join(dst.path, p.basename(e.path));
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }

  // --------------------------------------------------------------- header --

  Info buildHeader() {
    final h = Info();
    if (comment.trim().isNotEmpty) {
      h.comment('user comment of the measurement:');
      h.setTextList('measurement comment', comment.trim().split('\n'));
    }
    h.comment('====== COMMON SETUP ======');
    h.comment('unique identifiers of each channel:');
    h.setTextList('channel descriptors', channelDescriptors);
    h.comment('unique identifiers of auxiliary HW (AWG, Counter, ...):');
    h.setTextList('auxiliary HW descriptors', auxDescriptors);
    h.comment('number of virtual channel of the digitizer:');
    h.setNumber('channels count', channelDescriptors.length);
    h.comment('file format of the sample data:');
    h.setText('sample data format', 'mat-v4');
    h.setText('sample data variable name', 'y');
    h.comment('number of measurement groups:');
    h.setNumber('groups count', _groups.length);
    h.setBool('temperature available', temperatureAvailable);
    h.setBool('temperature log available', temperatureLogAvailable);
    final mux = multiplexer;
    if (mux != null && mux.enabled) {
      h.comment('time multiplexing:');
      h.setNumber('multiplexer enabled', 1);
      h.setNumber('multiplexer sequence cycles', mux.sequence.length);
      h.setTextList('multiplexer sequence', mux.sequence);
    }
    _writeAttributes(h, sessionAttributes);
    for (var g = 0; g < _groups.length; g++) {
      h.blank();
      h.setSection('measurement group ${g + 1}', _buildGroup(_groups[g], _records[g]));
    }
    if (_setupSection != null) {
      h.blank();
      h.setSection('measurement setup configuration', _setupSection!);
    }
    return h;
  }

  static void _writeAttributes(Info h, List<DeviceAttribute> attrs) {
    for (final a in attrs) {
      if (a.values.length == 1) {
        h.setText(a.name, a.values.first);
      } else {
        h.setTextList(a.name, a.values);
      }
    }
  }

  Info _buildGroup(GroupSetup g, List<RecordEntry> recs) {
    final i = Info();
    i.comment('====== MEASUREMENT GROUP ======');
    i.comment('number of repetition cycles (records):');
    i.setNumber('repetitions count', recs.length);
    i.comment('number of samples per record (sub-record):');
    i.setNumber('samples count', g.samplesCount);
    i.setNumber('sub-records count', g.subRecordsCount);
    i.setNumber('sampling rate [Sa/s]', g.fs);
    i.setNumber('bit resolution', g.bitResolution);
    i.comment('voltage ranges for each channel:');
    i.setRowVector('voltage ranges [V]', g.ranges);
    i.comment('ADC aperture for each record:');
    i.setVector('aperture [s]', [for (final r in recs) r.aperture]);
    i.setText('trigger mode', g.trigger.modeName);
    if (g.trigger.source == TriggerSource.level) {
      i.setNumber('trigger level [V]', g.trigger.level);
    }
    _writeAttributes(i, g.attributes);
    i.comment('====== RECORDS ======');
    i.setTextList('record sample data files', [for (final r in recs) r.file]);
    i.setVector('record samples counts', [for (final r in recs) r.samplesCount]);
    i.setVector('record time increments [s]', [for (final r in recs) r.increment]);
    i.comment('gain factors for scaling of the sample data for each record (row) and channel (column):');
    i.setMatrix('record sample data gains [V]', [for (final r in recs) r.gains]);
    i.setMatrix('record sample data offsets [V]', [for (final r in recs) r.offsets]);
    i.comment('relative timestamp of the first sample for each record and channel:');
    i.setMatrix('record relative timestamps [s]', [for (final r in recs) r.timestamps]);
    i.setTextList('record absolute timestamps', [for (final r in recs) r.absoluteTime.toIso8601String()]);
    if (recs.isNotEmpty && recs.first.subRecordOffsets.isNotEmpty) {
      i.setMatrix('sub-record sample offsets', [for (final r in recs) r.subRecordOffsets]);
      i.setMatrix('sub-record relative timestamps [s]', [for (final r in recs) r.subRecordTimestamps]);
    }
    if (temperatureAvailable) {
      i.setMatrix('record channel temperatures [deg C]', [for (final r in recs) r.temperatures]);
    }
    return i;
  }

  Future<void> save() async {
    await Directory(root).create(recursive: true);
    await File(headerPath).writeAsString(buildHeader().toString());
  }

  // ------------------------------------------------------------ processing --

  /// Writes `qwtb.info` with the processing setup (the LabVIEW VI
  /// "Meas Proc QWTB Write Algorithm Processing Header").
  static Future<void> writeQwtbSetup(String root, ProcessingSetup ps) async {
    final i = Info();
    i.setText('algorithm id', ps.algorithmId);
    i.setNumber('calculate whole average at once', ps.wholeAverageAtOnce ? 1 : 0);
    i.setText('uncertainty mode', ps.uncertainty.key);
    i.setNumber('level of confidence [-]', ps.levelOfConfidence);
    i.setNumber('monte carlo cycles', ps.monteCarloCycles);
    i.setNumber('sample data offset', ps.sampleOffset);
    i.setNumber('sample data limit', ps.sampleLimit);
    i.setText('time stamp mode', ps.timeStampMode.key);
    i.setNumber('calculate uncertainty once', ps.uncertaintyOnce ? 1 : 0);
    final params = ps.parameters.where((p) => p.values.any((v) => v.trim().isNotEmpty)).toList();
    i.setTextList('list of parameter names', [for (final p in params) p.name]);
    for (final p in params) {
      i.setTextList(p.name, p.values);
    }
    final root2 = Info()..setSection('QWTB processing setup', i);
    await Directory(root).create(recursive: true);
    await File(p.join(root, 'qwtb.info')).writeAsString(root2.toString());
  }

  /// Lists files that would be overwritten by a new measurement in [root]
  /// (TWM "clear last measurement session data" warning).
  static List<String> collidingFiles(String root) {
    final d = Directory(root);
    if (!d.existsSync()) return [];
    return [
      for (final e in d.listSync(recursive: true))
        if (e is File) p.relative(e.path, from: root),
    ]..sort();
  }

  static Future<void> clearSession(String root) async {
    final d = Directory(root);
    if (!d.existsSync()) return;
    for (final name in ['session.info', 'qwtb.info', 'results.info']) {
      final f = File(p.join(root, name));
      if (f.existsSync()) await f.delete();
    }
    for (final name in ['RAW', 'RESULTS', 'DIGITIZER', 'TRANSDUCERS']) {
      final s = Directory(p.join(root, name));
      if (s.existsSync()) await s.delete(recursive: true);
    }
  }
}

/// Convenience: header scaling info for one record from aux data.
RecordEntry recordFromAux(
  String file,
  int samples,
  AuxData aux,
  DateTime when, {
  double aperture = 0,
  List<int> subOffsets = const [],
  List<double> subTimestamps = const [],
}) => RecordEntry(
  file: file,
  samplesCount: samples,
  increment: aux.increment,
  gains: aux.gains,
  offsets: aux.offsets,
  timestamps: aux.timestamps,
  absoluteTime: when,
  aperture: aperture,
  temperatures: aux.temperatures,
  subRecordOffsets: subOffsets,
  subRecordTimestamps: subTimestamps,
);
