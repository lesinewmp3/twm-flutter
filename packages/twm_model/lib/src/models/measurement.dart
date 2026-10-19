/// Measurement, corrections and processing configuration (TWM panels
/// "New measurement", "HW corrections", "Processing setup").
library;

import '../json.dart';
import 'digitizer.dart';

// ------------------------------------------------------------- corrections --

enum TransducerType { divider, shunt }

class TransducerConfig {
  /// Path of the transducer correction INFO file (absolute or relative to
  /// [CorrectionsConfig.transducersRoot]).
  String path;

  /// Loaded from the INFO file (for display only).
  TransducerType type;
  String name;
  String serial;
  double nominalRatio;

  int phaseIndex;

  /// 1-based virtual channel index (high side).
  int highChannel;

  /// 1-based low side channel, 0 = not used (single ended).
  int lowChannel;

  /// Multiplexer path name ('' when multiplexing disabled).
  String multiplexerPath;

  bool inverted;

  TransducerConfig({
    this.path = '',
    this.type = TransducerType.divider,
    this.name = '',
    this.serial = '',
    this.nominalRatio = 1,
    this.phaseIndex = 1,
    this.highChannel = 1,
    this.lowChannel = 0,
    this.multiplexerPath = '',
    this.inverted = false,
  });

  bool get isDifferential => lowChannel > 0;

  Json toJson() => {
        'path': path,
        'type': type.name,
        'name': name,
        'serial': serial,
        'nominalRatio': nominalRatio,
        'phaseIndex': phaseIndex,
        'highChannel': highChannel,
        'lowChannel': lowChannel,
        'multiplexerPath': multiplexerPath,
        'inverted': inverted,
      };

  factory TransducerConfig.fromJson(Json j) => TransducerConfig(
        path: jString(j['path']),
        type: enumByName(TransducerType.values, j['type'], TransducerType.divider),
        name: jString(j['name']),
        serial: jString(j['serial']),
        nominalRatio: jDouble(j['nominalRatio'], 1),
        phaseIndex: jInt(j['phaseIndex'], 1),
        highChannel: jInt(j['highChannel'], 1),
        lowChannel: jInt(j['lowChannel']),
        multiplexerPath: jString(j['multiplexerPath']),
        inverted: jBool(j['inverted']),
      );
}

class CorrectionsConfig {
  String transducersRoot;
  List<TransducerConfig> transducers;
  String digitizerPath;
  String digitizerName; // loaded for display

  CorrectionsConfig({
    this.transducersRoot = '',
    List<TransducerConfig>? transducers,
    this.digitizerPath = '',
    this.digitizerName = '',
  }) : transducers = transducers ?? [];

  /// Validates the transducer list against the virtual channels count
  /// (the "OK"/error message of the TWM corrections panel).
  List<String> validate(int channelsCount, {List<String> muxPaths = const []}) {
    final errs = <String>[];
    final used = <String>{};
    final keys = <String>{};
    for (var k = 0; k < transducers.length; k++) {
      final t = transducers[k];
      final id = '#${k + 1}';
      if (t.path.isEmpty) errs.add('$id: no correction file selected');
      if (t.highChannel < 1 || t.highChannel > channelsCount) {
        errs.add('$id: high side channel not assigned or out of range');
      }
      if (t.lowChannel < 0 || t.lowChannel > channelsCount) {
        errs.add('$id: low side channel out of range');
      }
      if (t.lowChannel == t.highChannel) {
        errs.add('$id: low and high side use the same channel');
      }
      if (muxPaths.isNotEmpty && !muxPaths.contains(t.multiplexerPath)) {
        errs.add('$id: multiplexer path not assigned');
      }
      for (final c in [t.highChannel, if (t.lowChannel > 0) t.lowChannel]) {
        final key = '${t.multiplexerPath}/$c';
        if (!used.add(key)) errs.add('$id: channel $c already used by other transducer');
      }
      final pk = '${t.type.name}${t.phaseIndex}';
      if (!keys.add(pk)) {
        errs.add('$id: duplicate ${t.type.name} with phase index ${t.phaseIndex}');
      }
    }
    return errs;
  }

  Json toJson() => {
        'transducersRoot': transducersRoot,
        'transducers': [for (final t in transducers) t.toJson()],
        'digitizerPath': digitizerPath,
        'digitizerName': digitizerName,
      };

  factory CorrectionsConfig.fromJson(Json j) => CorrectionsConfig(
        transducersRoot: jString(j['transducersRoot']),
        transducers: [for (final t in jMapList(j['transducers'])) TransducerConfig.fromJson(t)],
        digitizerPath: jString(j['digitizerPath']),
        digitizerName: jString(j['digitizerName']),
      );
}

// -------------------------------------------------------------- processing --

enum ProcessingMode { none, raw, qwtb }

enum UncertaintyMode {
  none('none'),
  guf('guf'),
  mcm('mcm');

  final String key;
  const UncertaintyMode(this.key);
}

enum TimeStampMode {
  enable('enable'),
  disable('disable'),
  relative('relative');

  final String key;
  const TimeStampMode(this.key);
}

enum ExecutionMode { singleCore, parallelRecords }

enum ParallelMode { singlecore, multicore, multistation }

class AlgorithmParameter {
  String name;

  /// One value per row (column vector); numeric values as text.
  List<String> values;
  AlgorithmParameter(this.name, [List<String>? values]) : values = values ?? [];

  Json toJson() => {'name': name, 'values': values};
  factory AlgorithmParameter.fromJson(Json j) =>
      AlgorithmParameter(jString(j['name']), jStringList(j['values']));
}

class ProcessingSetup {
  ProcessingMode mode;

  // RAW mode
  String rawCode;

  // QWTB mode
  String algorithmId;
  List<AlgorithmParameter> parameters;
  int sampleOffset;
  int sampleLimit; // 0 = all
  bool wholeAverageAtOnce;
  bool uncertaintyOnce;
  TimeStampMode timeStampMode;
  UncertaintyMode uncertainty;
  double levelOfConfidence;
  int monteCarloCycles;
  double timeout; // [s]

  // multicore
  ExecutionMode execution;
  ParallelMode parallel;
  int cores;
  String jobsFolder;

  ProcessingSetup({
    this.mode = ProcessingMode.qwtb,
    this.rawCode = '% sample data are in variable "data.y"\n',
    this.algorithmId = 'TWM-PSFE',
    List<AlgorithmParameter>? parameters,
    this.sampleOffset = 0,
    this.sampleLimit = 0,
    this.wholeAverageAtOnce = false,
    this.uncertaintyOnce = false,
    this.timeStampMode = TimeStampMode.enable,
    this.uncertainty = UncertaintyMode.none,
    this.levelOfConfidence = 0.95,
    this.monteCarloCycles = 1000,
    this.timeout = 600,
    this.execution = ExecutionMode.singleCore,
    this.parallel = ParallelMode.singlecore,
    this.cores = 4,
    this.jobsFolder = '',
  }) : parameters = parameters ?? [];

  Json toJson() => {
        'mode': mode.name,
        'rawCode': rawCode,
        'algorithmId': algorithmId,
        'parameters': [for (final p in parameters) p.toJson()],
        'sampleOffset': sampleOffset,
        'sampleLimit': sampleLimit,
        'wholeAverageAtOnce': wholeAverageAtOnce,
        'uncertaintyOnce': uncertaintyOnce,
        'timeStampMode': timeStampMode.name,
        'uncertainty': uncertainty.name,
        'levelOfConfidence': levelOfConfidence,
        'monteCarloCycles': monteCarloCycles,
        'timeout': timeout,
        'execution': execution.name,
        'parallel': parallel.name,
        'cores': cores,
        'jobsFolder': jobsFolder,
      };

  factory ProcessingSetup.fromJson(Json j) => ProcessingSetup(
        mode: enumByName(ProcessingMode.values, j['mode'], ProcessingMode.qwtb),
        rawCode: jString(j['rawCode']),
        algorithmId: jString(j['algorithmId'], 'TWM-PSFE'),
        parameters: [for (final p in jMapList(j['parameters'])) AlgorithmParameter.fromJson(p)],
        sampleOffset: jInt(j['sampleOffset']),
        sampleLimit: jInt(j['sampleLimit']),
        wholeAverageAtOnce: jBool(j['wholeAverageAtOnce']),
        uncertaintyOnce: jBool(j['uncertaintyOnce']),
        timeStampMode: enumByName(TimeStampMode.values, j['timeStampMode'], TimeStampMode.enable),
        uncertainty: enumByName(UncertaintyMode.values, j['uncertainty'], UncertaintyMode.none),
        levelOfConfidence: jDouble(j['levelOfConfidence'], 0.95),
        monteCarloCycles: jInt(j['monteCarloCycles'], 1000),
        timeout: jDouble(j['timeout'], 600),
        execution: enumByName(ExecutionMode.values, j['execution'], ExecutionMode.singleCore),
        parallel: enumByName(ParallelMode.values, j['parallel'], ParallelMode.singlecore),
        cores: jInt(j['cores'], 4),
        jobsFolder: jString(j['jobsFolder']),
      );

  ProcessingSetup copy() => ProcessingSetup.fromJson(toJson());
}

// ------------------------------------------------------------- measurement --

enum RangeMode { keepDefaults, allSame, oddEven }

class MeasurementConfig {
  double fs;
  double aperture;
  int samplesCount;
  int recordsCount;
  double preRecordDelay; // [s]
  int subRecordsCount;
  TriggerConfig trigger;

  RangeMode rangeMode;
  double rangeAll;
  double rangeOdd;
  double rangeEven;

  String folder;

  /// Measurement subfolder name, may contain `%id%`, `%date%`, `%time%`.
  String nameBase;
  int measurementId;
  String comment;

  bool processingEnabled;
  ProcessingSetup processing;

  /// TPQA continuous acquisition: repeat until STOP.
  bool continuous;

  /// Store records to the measurement folder (TPQA "Save Sampled Data").
  /// When false (continuous mode only) the data are just displayed and
  /// analysed on-line.
  bool saveRecords;

  MeasurementConfig({
    this.fs = 10000,
    this.aperture = 0,
    this.samplesCount = 10000,
    this.recordsCount = 1,
    this.preRecordDelay = 0,
    this.subRecordsCount = 1,
    TriggerConfig? trigger,
    this.rangeMode = RangeMode.keepDefaults,
    this.rangeAll = 1,
    this.rangeOdd = 1,
    this.rangeEven = 1,
    this.folder = '',
    this.nameBase = 'meas_%id%',
    this.measurementId = 1,
    this.comment = '',
    this.processingEnabled = false,
    ProcessingSetup? processing,
    this.continuous = false,
    this.saveRecords = true,
  })  : trigger = trigger ?? TriggerConfig(),
        processing = processing ?? ProcessingSetup();

  double get measurementTime => samplesCount / fs;

  /// Resolves `%id%`, `%date%`, `%time%` in [nameBase].
  String resolveName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return nameBase
        .replaceAll('%id%', measurementId.toString().padLeft(3, '0'))
        .replaceAll('%date%', '${now.year}-${two(now.month)}-${two(now.day)}')
        .replaceAll('%time%', '${two(now.hour)}-${two(now.minute)}-${two(now.second)}');
  }

  /// Ranges for each physical channel.
  List<double> ranges(List<double> defaults) => switch (rangeMode) {
        RangeMode.keepDefaults => defaults,
        RangeMode.allSame => List.filled(defaults.length, rangeAll),
        RangeMode.oddEven => [
            for (var i = 0; i < defaults.length; i++) i.isEven ? rangeOdd : rangeEven
          ],
      };

  Json toJson() => {
        'fs': fs,
        'aperture': aperture,
        'samplesCount': samplesCount,
        'recordsCount': recordsCount,
        'preRecordDelay': preRecordDelay,
        'subRecordsCount': subRecordsCount,
        'trigger': trigger.toJson(),
        'rangeMode': rangeMode.name,
        'rangeAll': rangeAll,
        'rangeOdd': rangeOdd,
        'rangeEven': rangeEven,
        'folder': folder,
        'nameBase': nameBase,
        'measurementId': measurementId,
        'comment': comment,
        'processingEnabled': processingEnabled,
        'processing': processing.toJson(),
        'continuous': continuous,
        'saveRecords': saveRecords,
      };

  factory MeasurementConfig.fromJson(Json j) => MeasurementConfig(
        fs: jDouble(j['fs'], 10000),
        aperture: jDouble(j['aperture']),
        samplesCount: jInt(j['samplesCount'], 10000),
        recordsCount: jInt(j['recordsCount'], 1),
        preRecordDelay: jDouble(j['preRecordDelay']),
        subRecordsCount: jInt(j['subRecordsCount'], 1),
        trigger: j['trigger'] == null ? null : TriggerConfig.fromJson(jMap(j['trigger'])),
        rangeMode: enumByName(RangeMode.values, j['rangeMode'], RangeMode.keepDefaults),
        rangeAll: jDouble(j['rangeAll'], 1),
        rangeOdd: jDouble(j['rangeOdd'], 1),
        rangeEven: jDouble(j['rangeEven'], 1),
        folder: jString(j['folder']),
        nameBase: jString(j['nameBase'], 'meas_%id%'),
        measurementId: jInt(j['measurementId'], 1),
        comment: jString(j['comment']),
        processingEnabled: jBool(j['processingEnabled']),
        processing:
            j['processing'] == null ? null : ProcessingSetup.fromJson(jMap(j['processing'])),
        continuous: jBool(j['continuous']),
        saveRecords: jBool(j['saveRecords'], true),
      );

  MeasurementConfig copy() => MeasurementConfig.fromJson(toJson());
}

// ------------------------------------------------------------ octave/matlab --

enum CalcEngine { octave, matlab }

class OctaveConfig {
  CalcEngine engine;
  String octavePath; // folder with octave-cli or the binary itself
  String matlabPath;
  String qwtbPath; // QWTB root, default <octprog>/qwtb
  String octprogPath; // TWM octprog folder (m-scripts)
  bool clearCache;
  bool showConsole;
  List<String> packages;

  OctaveConfig({
    this.engine = CalcEngine.octave,
    this.octavePath = '',
    this.matlabPath = '',
    this.qwtbPath = '',
    this.octprogPath = '',
    this.clearCache = false,
    this.showConsole = false,
    List<String>? packages,
  }) : packages = packages ?? ['signal', 'statistics', 'optim'];

  Json toJson() => {
        'engine': engine.name,
        'octavePath': octavePath,
        'matlabPath': matlabPath,
        'qwtbPath': qwtbPath,
        'octprogPath': octprogPath,
        'clearCache': clearCache,
        'showConsole': showConsole,
        'packages': packages,
      };

  factory OctaveConfig.fromJson(Json j) => OctaveConfig(
        engine: enumByName(CalcEngine.values, j['engine'], CalcEngine.octave),
        octavePath: jString(j['octavePath']),
        matlabPath: jString(j['matlabPath']),
        qwtbPath: jString(j['qwtbPath']),
        octprogPath: jString(j['octprogPath']),
        clearCache: jBool(j['clearCache']),
        showConsole: jBool(j['showConsole']),
        packages: j['packages'] == null ? null : jStringList(j['packages']),
      );
}
