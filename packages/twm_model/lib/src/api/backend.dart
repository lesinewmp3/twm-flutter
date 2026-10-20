/// Contract between the Flutter UI and the TWM backend. Implemented by the
/// in-process backend (desktop) and by the HTTP/WebSocket client (web).
/// All data types are JSON serializable.
library;

import '../json.dart';
import '../models/digitizer.dart';
import '../models/digitizer_config.dart';
import '../models/measurement.dart';
import '../models/qwtb.dart';
import '../dsp/online_analyzer.dart';
import 'events.dart';

/// Persistent application settings (TWM keeps them in config.ini).
class AppSettings {
  DigitizerConfig digitizer;
  MeasurementConfig measurement;
  CorrectionsConfig corrections;
  OctaveConfig octave;
  ResultViewConfig resultView;
  OnlineAnalysisConfig online;
  String lastSession;
  String serverPipe;

  /// UI language: 'auto' (system/browser), 'ru' or 'en'.
  String language;

  AppSettings({
    DigitizerConfig? digitizer,
    MeasurementConfig? measurement,
    CorrectionsConfig? corrections,
    OctaveConfig? octave,
    ResultViewConfig? resultView,
    OnlineAnalysisConfig? online,
    this.lastSession = '',
    this.serverPipe = 'twm_server',
    this.language = 'auto',
  }) : digitizer = digitizer ?? DigitizerConfig(),
       measurement = measurement ?? MeasurementConfig(),
       corrections = corrections ?? CorrectionsConfig(),
       octave = octave ?? OctaveConfig(),
       resultView = resultView ?? ResultViewConfig(),
       online = online ?? OnlineAnalysisConfig();

  Json toJson() => {
    'digitizer': digitizer.toJson(),
    'measurement': measurement.toJson(),
    'corrections': corrections.toJson(),
    'octave': octave.toJson(),
    'resultView': resultView.toJson(),
    'online': online.toJson(),
    'lastSession': lastSession,
    'serverPipe': serverPipe,
    'language': language,
  };

  factory AppSettings.fromJson(Json j) => AppSettings(
    digitizer: j['digitizer'] == null ? null : DigitizerConfig.fromJson(jMap(j['digitizer'])),
    measurement: j['measurement'] == null ? null : MeasurementConfig.fromJson(jMap(j['measurement'])),
    corrections: j['corrections'] == null ? null : CorrectionsConfig.fromJson(jMap(j['corrections'])),
    octave: j['octave'] == null ? null : OctaveConfig.fromJson(jMap(j['octave'])),
    resultView: j['resultView'] == null ? null : ResultViewConfig.fromJson(jMap(j['resultView'])),
    online: j['online'] == null ? null : OnlineAnalysisConfig.fromJson(jMap(j['online'])),
    lastSession: jString(j['lastSession']),
    serverPipe: jString(j['serverPipe'], 'twm_server'),
    language: jString(j['language'], 'auto'),
  );

  AppSettings copy() => AppSettings.fromJson(toJson());
}

class FileEntry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;
  const FileEntry(this.name, this.path, this.isDir, {this.size = 0, this.modified});

  Json toJson() => {'name': name, 'path': path, 'isDir': isDir, 'size': size, 'modified': modified?.toIso8601String()};
  factory FileEntry.fromJson(Json j) => FileEntry(
    jString(j['name']),
    jString(j['path']),
    jBool(j['isDir']),
    size: jInt(j['size']),
    modified: j['modified'] == null ? null : DateTime.tryParse(jString(j['modified'])),
  );
}

class DirListing {
  final String path;
  final String parent;
  final String separator;
  final List<FileEntry> entries;
  final List<String> roots; // drives / home / measurement folders
  const DirListing(this.path, this.parent, this.separator, this.entries, this.roots);

  Json toJson() => {
    'path': path,
    'parent': parent,
    'separator': separator,
    'entries': [for (final e in entries) e.toJson()],
    'roots': roots,
  };
  factory DirListing.fromJson(Json j) => DirListing(
    jString(j['path']),
    jString(j['parent']),
    jString(j['separator'], '/'),
    [for (final e in jMapList(j['entries'])) FileEntry.fromJson(e)],
    jStringList(j['roots']),
  );
}

/// Result of the digitizer TEST button.
class DigitizerTestResult {
  final bool ok;
  final List<String> channelIdns;
  final List<String> auxIdns;
  final DigitizerCapabilities? capabilities;
  final String message;
  const DigitizerTestResult({
    required this.ok,
    this.channelIdns = const [],
    this.auxIdns = const [],
    this.capabilities,
    this.message = '',
  });

  Json toJson() => {
    'ok': ok,
    'channelIdns': channelIdns,
    'auxIdns': auxIdns,
    'capabilities': capabilities?.toJson(),
    'message': message,
  };
  factory DigitizerTestResult.fromJson(Json j) => DigitizerTestResult(
    ok: jBool(j['ok']),
    channelIdns: jStringList(j['channelIdns']),
    auxIdns: jStringList(j['auxIdns']),
    capabilities: j['capabilities'] == null ? null : DigitizerCapabilities.fromJson(jMap(j['capabilities'])),
    message: jString(j['message']),
  );
}

/// Summary of a correction INFO file (for the corrections panel).
class CorrectionSummary {
  final String path;
  final String type; // shunt / divider / digitizer / channel
  final String name;
  final String serial;
  final double nominalRatio;
  final List<String> channelIdentifiers;
  final String error;
  const CorrectionSummary({
    required this.path,
    this.type = '',
    this.name = '',
    this.serial = '',
    this.nominalRatio = double.nan,
    this.channelIdentifiers = const [],
    this.error = '',
  });

  Json toJson() => {
    'path': path,
    'type': type,
    'name': name,
    'serial': serial,
    'nominalRatio': jNum(nominalRatio),
    'channelIdentifiers': channelIdentifiers,
    'error': error,
  };
  factory CorrectionSummary.fromJson(Json j) => CorrectionSummary(
    path: jString(j['path']),
    type: jString(j['type']),
    name: jString(j['name']),
    serial: jString(j['serial']),
    nominalRatio: jDouble(j['nominalRatio'], double.nan),
    channelIdentifiers: jStringList(j['channelIdentifiers']),
    error: jString(j['error']),
  );
}

/// Structure of a measurement session (batch processing, record viewer).
class SessionSummary {
  final String path; // session.info
  final List<String> channels;
  final List<int> recordsPerGroup;
  final List<String> transducerTags; // u1, i1 ...
  final String comment;
  final double fs;
  final int samplesCount;
  const SessionSummary({
    required this.path,
    this.channels = const [],
    this.recordsPerGroup = const [],
    this.transducerTags = const [],
    this.comment = '',
    this.fs = 0,
    this.samplesCount = 0,
  });

  Json toJson() => {
    'path': path,
    'channels': channels,
    'recordsPerGroup': recordsPerGroup,
    'transducerTags': transducerTags,
    'comment': comment,
    'fs': fs,
    'samplesCount': samplesCount,
  };
  factory SessionSummary.fromJson(Json j) => SessionSummary(
    path: jString(j['path']),
    channels: jStringList(j['channels']),
    recordsPerGroup: jIntList(j['recordsPerGroup']),
    transducerTags: jStringList(j['transducerTags']),
    comment: jString(j['comment']),
    fs: jDouble(j['fs']),
    samplesCount: jInt(j['samplesCount']),
  );
}

/// Waveform data of a record (record viewer).
class WaveformData {
  final List<String> names;
  final List<List<double>> channels;
  final double ts;
  final int fullLength;
  const WaveformData(this.names, this.channels, this.ts, this.fullLength);

  Json toJson() => {'names': names, 'channels': channels, 'ts': ts, 'fullLength': fullLength};
  factory WaveformData.fromJson(Json j) => WaveformData(
    jStringList(j['names']),
    [for (final c in (j['channels'] as List? ?? [])) jDoubleList(c)],
    jDouble(j['ts']),
    jInt(j['fullLength']),
  );
}

class OctaveStatus {
  final bool running;
  final String version;
  final bool isOctave;
  final List<String> installedPackages;
  final List<String> loadedPackages;
  final List<String> failedPackages;
  final bool hasQwtb;
  final String error;
  const OctaveStatus({
    this.running = false,
    this.version = '',
    this.isOctave = true,
    this.installedPackages = const [],
    this.loadedPackages = const [],
    this.failedPackages = const [],
    this.hasQwtb = false,
    this.error = '',
  });

  Json toJson() => {
    'running': running,
    'version': version,
    'isOctave': isOctave,
    'installedPackages': installedPackages,
    'loadedPackages': loadedPackages,
    'failedPackages': failedPackages,
    'hasQwtb': hasQwtb,
    'error': error,
  };
  factory OctaveStatus.fromJson(Json j) => OctaveStatus(
    running: jBool(j['running']),
    version: jString(j['version']),
    isOctave: jBool(j['isOctave'], true),
    installedPackages: jStringList(j['installedPackages']),
    loadedPackages: jStringList(j['loadedPackages']),
    failedPackages: jStringList(j['failedPackages']),
    hasQwtb: jBool(j['hasQwtb']),
    error: jString(j['error']),
  );
}

/// What the backend can do - the UI hides panels that are not available
/// (e.g. GNU Octave and instruments in the browser version).
class BackendFeatures {
  final bool octave;
  final bool hardware;
  final bool server;
  final bool fileTransfer; // upload/download of files (browser storage)
  final List<DigitizerType> digitizers;
  const BackendFeatures({
    this.octave = true,
    this.hardware = true,
    this.server = true,
    this.fileTransfer = false,
    this.digitizers = DigitizerType.values,
  });

  static const full = BackendFeatures();
  static const browser = BackendFeatures(
    octave: false,
    hardware: false,
    server: false,
    fileTransfer: true,
    digitizers: [DigitizerType.simulated],
  );
}

abstract class TwmBackend {
  /// Human readable description ("local", "server http://...").
  String get description;

  BackendFeatures get features;

  Stream<BackendEvent> get events;

  // settings
  Future<AppSettings> loadSettings();
  Future<void> saveSettings(AppSettings s);

  // files (server side file system)
  Future<DirListing> listDir(String path, {List<String> extensions = const []});
  Future<String> readText(String path);
  Future<void> writeText(String path, String content);
  Future<bool> exists(String path);

  // digitizer
  Future<DigitizerTestResult> testDigitizer(DigitizerConfig cfg);
  Future<String> digitizerInfo(DigitizerConfig cfg);
  Future<List<String>> enumerateDevices(DigitizerConfig cfg);
  Future<void> selfCalibrate(DigitizerConfig cfg);

  // corrections
  Future<CorrectionSummary> correctionSummary(String path);

  // measurement
  Future<List<String>> collidingFiles(MeasurementConfig cfg);
  Future<void> clearSession(MeasurementConfig cfg);
  Future<String> startMeasurement(AppSettings s);
  Future<void> stopMeasurement();
  bool get measuring;

  // sessions
  Future<SessionSummary> sessionSummary(String sessionPath);
  Future<WaveformData> readRecord(String sessionPath, int group, int record, {int maxPoints = 5000});

  // processing (GNU Octave / Matlab)
  Future<OctaveStatus> octaveStart(OctaveConfig cfg);
  Future<OctaveStatus> octaveRestart(OctaveConfig cfg);
  Future<OctaveStatus> octaveStatus();
  Future<String> octaveEval(String code);
  Future<void> octaveInstallPackage(String file);
  Future<List<AlgorithmSummary>> algorithms();
  Future<AlgorithmInfo> algorithmInfo(String id);
  Future<void> processRecords(
    String sessionPath,
    ProcessingSetup setup, {
    required int group,
    required List<int> records,
  });
  Future<void> stopProcessing();
  Future<ResultsInfo> resultsInfo(String sessionPath, {String algorithm = ''});
  Future<ResultsTable> results(String sessionPath, String algorithm, ResultViewConfig cfg);
  Future<ResultData> resultData(String sessionPath, String algorithm, ResultViewConfig cfg);
  Future<({double fs, int n, double err})> findCoherent(
    double f0,
    double tMin,
    double tMax,
    Map<String, Object?> rate,
    double maxErr,
    double timeout,
  );
}
