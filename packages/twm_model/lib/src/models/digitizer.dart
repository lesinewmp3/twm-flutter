/// Virtual digitizer data model (see "A245 TWM structure", chapter
/// "Modular driver design"). Shared by UI and backend.
library;

import '../json.dart';

/// Supported digitizer types (order matches TWM "ADC Type.ctl" as far as
/// known, new ones appended).
enum DigitizerType {
  simulated('Simulated'),
  niScope('NI PXI-5922 (niScope)'),
  hp3458a('HP/Keysight 3458A (+Fluke 8588A)'),
  cdaq('NI cDAQ 9238'),
  keysightDso('Keysight DSO 90000'),
  soundCard('Sound card'),
  ads127l21('CMI ADS127L21');

  final String label;
  const DigitizerType(this.label);
}

enum TriggerSource { immediate, external, level }

enum TriggerSlope { positive, negative }

enum TriggerCoupling { dc, ac }

class TriggerConfig {
  TriggerSource source;
  TriggerSlope slope;
  TriggerCoupling coupling;
  double level;

  TriggerConfig({
    this.source = TriggerSource.immediate,
    this.slope = TriggerSlope.positive,
    this.coupling = TriggerCoupling.dc,
    this.level = 0,
  });

  /// Value written to the session header ('trigger mode').
  String get modeName => switch (source) {
    TriggerSource.immediate => 'Immediate',
    TriggerSource.external => 'External',
    TriggerSource.level => 'Level',
  };

  Json toJson() => {'source': source.name, 'slope': slope.name, 'coupling': coupling.name, 'level': level};

  factory TriggerConfig.fromJson(Json j) => TriggerConfig(
    source: enumByName(TriggerSource.values, j['source'], TriggerSource.immediate),
    slope: enumByName(TriggerSlope.values, j['slope'], TriggerSlope.positive),
    coupling: enumByName(TriggerCoupling.values, j['coupling'], TriggerCoupling.dc),
    level: jDouble(j['level']),
  );
}

enum SampleRateStepMode { constPeriod, constFrequency }

/// "Get Digitizer Capabilities" output.
class DigitizerCapabilities {
  final int maxSamplesCount;
  final double maxFs;
  final double minFs;
  final double tsStep;
  final double fsStep;
  final SampleRateStepMode stepMode;
  final double? aperMin;
  final double? aperMax;
  final int channelsCount;
  final bool allowsStreaming;
  final bool streamingOn;
  final bool hasLevelTrig;
  final bool hasExtTrig;
  final bool hasAperture;
  final bool hasRanges;
  final bool hasTemperature;
  final bool hasTemperatureLog;
  final bool hasSelfCal;

  /// Discrete sampling rates (e.g. sound card, cDAQ). Empty = continuous.
  final List<double> fixedRates;

  /// Available ranges [V] (for range override selectors).
  final List<double> ranges;

  const DigitizerCapabilities({
    required this.maxSamplesCount,
    required this.maxFs,
    required this.minFs,
    this.tsStep = double.nan,
    this.fsStep = double.nan,
    this.stepMode = SampleRateStepMode.constFrequency,
    this.aperMin,
    this.aperMax,
    required this.channelsCount,
    this.allowsStreaming = false,
    this.streamingOn = false,
    this.hasLevelTrig = false,
    this.hasExtTrig = false,
    this.hasAperture = false,
    this.hasRanges = false,
    this.hasTemperature = false,
    this.hasTemperatureLog = false,
    this.hasSelfCal = false,
    this.fixedRates = const [],
    this.ranges = const [],
  });

  /// Coerces requested rate to the nearest rate the digitizer can set.
  double coerceFs(double fs) {
    if (fixedRates.isNotEmpty) {
      return fixedRates.reduce((a, b) => (a - fs).abs() <= (b - fs).abs() ? a : b);
    }
    var r = fs.clamp(minFs, maxFs).toDouble();
    if (stepMode == SampleRateStepMode.constPeriod && tsStep.isFinite && tsStep > 0) {
      final n = (1 / r / tsStep).round();
      r = 1 / (n * tsStep);
    } else if (fsStep.isFinite && fsStep > 0) {
      r = (r / fsStep).round() * fsStep;
    }
    return r;
  }

  Json toJson() => {
    'maxSamplesCount': maxSamplesCount,
    'maxFs': maxFs,
    'minFs': minFs,
    'tsStep': jNum(tsStep),
    'fsStep': jNum(fsStep),
    'stepMode': stepMode.name,
    'aperMin': aperMin,
    'aperMax': aperMax,
    'channelsCount': channelsCount,
    'allowsStreaming': allowsStreaming,
    'streamingOn': streamingOn,
    'hasLevelTrig': hasLevelTrig,
    'hasExtTrig': hasExtTrig,
    'hasAperture': hasAperture,
    'hasRanges': hasRanges,
    'hasTemperature': hasTemperature,
    'hasTemperatureLog': hasTemperatureLog,
    'hasSelfCal': hasSelfCal,
    'fixedRates': fixedRates,
    'ranges': ranges,
  };

  factory DigitizerCapabilities.fromJson(Json j) => DigitizerCapabilities(
    maxSamplesCount: jInt(j['maxSamplesCount']),
    maxFs: jDouble(j['maxFs']),
    minFs: jDouble(j['minFs']),
    tsStep: jDouble(j['tsStep'], double.nan),
    fsStep: jDouble(j['fsStep'], double.nan),
    stepMode: enumByName(SampleRateStepMode.values, j['stepMode'], SampleRateStepMode.constFrequency),
    aperMin: jDoubleOrNull(j['aperMin']),
    aperMax: jDoubleOrNull(j['aperMax']),
    channelsCount: jInt(j['channelsCount']),
    allowsStreaming: jBool(j['allowsStreaming']),
    streamingOn: jBool(j['streamingOn']),
    hasLevelTrig: jBool(j['hasLevelTrig']),
    hasExtTrig: jBool(j['hasExtTrig']),
    hasAperture: jBool(j['hasAperture']),
    hasRanges: jBool(j['hasRanges']),
    hasTemperature: jBool(j['hasTemperature']),
    hasTemperatureLog: jBool(j['hasTemperatureLog']),
    hasSelfCal: jBool(j['hasSelfCal']),
    fixedRates: jDoubleList(j['fixedRates']),
    ranges: jDoubleList(j['ranges']),
  );
}

/// Device specific attribute stored to the session header.
class DeviceAttribute {
  final String name;
  final List<String> values;
  final bool constPerGroup;
  const DeviceAttribute(this.name, this.values, {this.constPerGroup = true});

  Json toJson() => {'name': name, 'values': values, 'constPerGroup': constPerGroup};
  factory DeviceAttribute.fromJson(Json j) =>
      DeviceAttribute(jString(j['name']), jStringList(j['values']), constPerGroup: jBool(j['constPerGroup'], true));
}

/// Channel overload/clipping etc. reported in fetch status.
class DigitizerStatus {
  final bool sampling;
  final bool done;
  final int fetched;
  final int total;
  final double instrBuffer;
  final double queueBuffer;
  final String message;
  const DigitizerStatus({
    this.sampling = false,
    this.done = false,
    this.fetched = 0,
    this.total = 0,
    this.instrBuffer = double.nan,
    this.queueBuffer = double.nan,
    this.message = '',
  });

  double get progress => total > 0 ? fetched / total : 0;
}
