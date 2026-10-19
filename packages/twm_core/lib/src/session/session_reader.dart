import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

import 'record_file.dart';

/// Reader of a TWM measurement session folder (counterpart of
/// `tpq_load_record.m` used by the record viewer).
class SessionReader {
  final String root;
  final Info header;

  SessionReader._(this.root, this.header);

  static Future<SessionReader> open(String pathOrRoot) async {
    var file = pathOrRoot;
    if (await FileSystemEntity.isDirectory(pathOrRoot)) {
      file = p.join(pathOrRoot, 'session.info');
    }
    final txt = await File(file).readAsString();
    return SessionReader._(p.dirname(file), Info.parse(txt));
  }

  int get groupsCount => header.number('groups count').round();
  int get channelsCount => header.number('channels count').round();
  List<String> get channelDescriptors => header.textList('channel descriptors');
  String get dataVariable => header.textOrNull('sample data variable name') ?? 'y';

  Info group(int g) => header.section('measurement group $g');

  int repetitions(int g) => group(g).number('repetitions count').round();

  /// Reads record [rep] of group [g]; returns scaled channels, optionally
  /// decimated (min/max envelope preserving) to [maxPoints] per channel.
  Future<RecordData> readRecord(int g, int rep, {int maxPoints = 0}) async {
    final gi = group(g);
    final files = gi.textList('record sample data files');
    final rel = files[rep - 1].replaceAll('\\', '/');
    final gains = gi.matrix('record sample data gains [V]')[rep - 1];
    final offs = gi.matrix('record sample data offsets [V]')[rep - 1];
    final ts = gi.vector('record time increments [s]')[rep - 1];
    final tstamps = gi.matrix('record relative timestamps [s]')[rep - 1];
    final v = await RecordFileReader.read(p.join(root, rel), varName: dataVariable);
    final ch = <Float64List>[];
    var step = 1;
    if (maxPoints > 0 && v.cols > maxPoints) step = (v.cols / maxPoints).ceil();
    for (var c = 0; c < v.rows; c++) {
      final full = v.row(c, gain: gains[c], offset: offs[c]);
      ch.add(step == 1 ? full : _decimate(full, step));
    }
    return RecordData(channels: ch, ts: ts * step, fullLength: v.cols, timestamps: tstamps, names: channelDescriptors);
  }

  static Float64List _decimate(Float64List x, int step) {
    // simple stride decimation keeping every step-th sample
    final n = (x.length / step).ceil();
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = x[math.min(i * step, x.length - 1)];
    }
    return out;
  }
}

class RecordData {
  final List<Float64List> channels;
  final double ts;
  final int fullLength;
  final List<double> timestamps;
  final List<String> names;
  RecordData({
    required this.channels,
    required this.ts,
    required this.fullLength,
    required this.timestamps,
    required this.names,
  });
}
