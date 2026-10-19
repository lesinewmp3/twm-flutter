/// Configuration of the virtual digitizer and of all driver specific pages
/// of the "Digitizer configuration" panel (TWM guide 3.1.4.2, TPQA guide
/// 3.3.3.1). All driver configs are kept at once, like the TWM "adc session",
/// so switching the digitizer type does not lose settings.
library;

import '../json.dart';
import 'digitizer.dart';

enum OnCloseAction { immediateReset, delayedReset }

// ------------------------------------------------------------- multiplexer --

enum MultiplexerType {
  comPort('Generic - COM port (DTR/RTS)'),
  niScopePfi('Generic - niScope PFI'),
  visaCommands('Generic - VISA commands'),
  qpmx('QPMX');

  final String label;
  const MultiplexerType(this.label);
}

class MultiplexerPath {
  String name;
  bool primary; // DTR / PFI0
  bool secondary; // RTS / PFI1
  String command; // for VISA commands mode
  MultiplexerPath({this.name = 'A', this.primary = false, this.secondary = false, this.command = ''});

  Json toJson() => {'name': name, 'primary': primary, 'secondary': secondary, 'command': command};
  factory MultiplexerPath.fromJson(Json j) => MultiplexerPath(
    name: jString(j['name'], 'A'),
    primary: jBool(j['primary']),
    secondary: jBool(j['secondary']),
    command: jString(j['command']),
  );
}

class MultiplexerConfig {
  bool enabled;
  MultiplexerType type;
  String visa;
  int niScopeChannelIndex;
  List<MultiplexerPath> paths;
  List<String> sequence;
  double delayBeforeSwitch;
  double delayAfterSwitch;

  MultiplexerConfig({
    this.enabled = false,
    this.type = MultiplexerType.comPort,
    this.visa = 'ASRL1::INSTR',
    this.niScopeChannelIndex = 0,
    List<MultiplexerPath>? paths,
    List<String>? sequence,
    this.delayBeforeSwitch = 0.1,
    this.delayAfterSwitch = 0.1,
  }) : paths = paths ?? [MultiplexerPath(name: 'A', primary: false), MultiplexerPath(name: 'B', primary: true)],
       sequence = sequence ?? ['A', 'B'];

  int get cycles => enabled ? sequence.length : 1;

  Json toJson() => {
    'enabled': enabled,
    'type': type.name,
    'visa': visa,
    'niScopeChannelIndex': niScopeChannelIndex,
    'paths': [for (final p in paths) p.toJson()],
    'sequence': sequence,
    'delayBeforeSwitch': delayBeforeSwitch,
    'delayAfterSwitch': delayAfterSwitch,
  };

  factory MultiplexerConfig.fromJson(Json j) => MultiplexerConfig(
    enabled: jBool(j['enabled']),
    type: enumByName(MultiplexerType.values, j['type'], MultiplexerType.comPort),
    visa: jString(j['visa'], 'ASRL1::INSTR'),
    niScopeChannelIndex: jInt(j['niScopeChannelIndex']),
    paths: j['paths'] == null ? null : [for (final p in jMapList(j['paths'])) MultiplexerPath.fromJson(p)],
    sequence: j['sequence'] == null ? null : jStringList(j['sequence']),
    delayBeforeSwitch: jDouble(j['delayBeforeSwitch'], 0.1),
    delayAfterSwitch: jDouble(j['delayAfterSwitch'], 0.1),
  );
}

// --------------------------------------------------------------- simulated --

class SimHarmonic {
  double freq; // [Hz]
  double amp; // [V] peak
  double phase; // [rad]
  SimHarmonic(this.freq, this.amp, [this.phase = 0]);
  Json toJson() => {'f': freq, 'A': amp, 'ph': phase};
  factory SimHarmonic.fromJson(Json j) => SimHarmonic(jDouble(j['f']), jDouble(j['A']), jDouble(j['ph']));
}

class SimChannelConfig {
  String name;
  double range; // [V] peak
  double dc;
  double noiseRms;
  List<SimHarmonic> harmonics;
  double timeShift; // simulated channel delay [s]

  SimChannelConfig({
    this.name = 'channel',
    this.range = 10,
    this.dc = 0,
    this.noiseRms = 1e-6,
    List<SimHarmonic>? harmonics,
    this.timeShift = 0,
  }) : harmonics = harmonics ?? [SimHarmonic(50, 1)];

  Json toJson() => {
    'name': name,
    'range': range,
    'dc': dc,
    'noiseRms': noiseRms,
    'timeShift': timeShift,
    'harmonics': [for (final h in harmonics) h.toJson()],
  };

  factory SimChannelConfig.fromJson(Json j) => SimChannelConfig(
    name: jString(j['name'], 'channel'),
    range: jDouble(j['range'], 10),
    dc: jDouble(j['dc']),
    noiseRms: jDouble(j['noiseRms'], 1e-6),
    timeShift: jDouble(j['timeShift']),
    harmonics: j['harmonics'] == null ? null : [for (final h in jMapList(j['harmonics'])) SimHarmonic.fromJson(h)],
  );
}

class SimulatedConfig {
  List<SimChannelConfig> channels;
  int bits;
  double maxFs;
  double jitterRms; // sampling jitter [s]
  double realtimeFactor; // 1 = simulated acquisition takes real time, 0 = instant

  SimulatedConfig({
    List<SimChannelConfig>? channels,
    this.bits = 24,
    this.maxFs = 1e6,
    this.jitterRms = 0,
    this.realtimeFactor = 1,
  }) : channels =
           channels ??
           [
             SimChannelConfig(
               name: 'u',
               range: 10,
               harmonics: [SimHarmonic(50, 7.0710678, 0), SimHarmonic(150, 0.07, 0.3)],
             ),
             SimChannelConfig(
               name: 'i',
               range: 1,
               harmonics: [SimHarmonic(50, 0.5, -0.2), SimHarmonic(250, 0.02, 1.0)],
             ),
           ];

  Json toJson() => {
    'channels': [for (final c in channels) c.toJson()],
    'bits': bits,
    'maxFs': maxFs,
    'jitterRms': jitterRms,
    'realtimeFactor': realtimeFactor,
  };

  factory SimulatedConfig.fromJson(Json j) => SimulatedConfig(
    channels: j['channels'] == null ? null : [for (final c in jMapList(j['channels'])) SimChannelConfig.fromJson(c)],
    bits: jInt(j['bits'], 24),
    maxFs: jDouble(j['maxFs'], 1e6),
    jitterRms: jDouble(j['jitterRms']),
    realtimeFactor: jDouble(j['realtimeFactor'], 1),
  );
}

// ----------------------------------------------------------------- niScope --

enum NiScopeInputZ { megaOhm1, ohm50 }

enum NiScopeCoupling { dc, ac, gnd }

class NiScopeChannelConfig {
  String resource; // e.g. PXI1Slot2 / "ADC1"
  int channelId;
  double range; // [Vpk]
  NiScopeInputZ inputZ;
  NiScopeCoupling coupling;
  double offset; // vertical offset [V] (TPQA)
  double probeAttenuation; // (TPQA)
  double maxInputFrequency; // -1 = default bandwidth (TPQA)
  int? lowChannelId; // pseudo-differential pairing (TPQA "Channel: 0,1")

  NiScopeChannelConfig({
    this.resource = 'PXI1Slot2',
    this.channelId = 0,
    this.range = 5,
    this.inputZ = NiScopeInputZ.megaOhm1,
    this.coupling = NiScopeCoupling.dc,
    this.offset = 0,
    this.probeAttenuation = 1,
    this.maxInputFrequency = -1,
    this.lowChannelId,
  });

  Json toJson() => {
    'resource': resource,
    'channelId': channelId,
    'range': range,
    'inputZ': inputZ.name,
    'coupling': coupling.name,
    'offset': offset,
    'probeAttenuation': probeAttenuation,
    'maxInputFrequency': maxInputFrequency,
    'lowChannelId': lowChannelId,
  };

  factory NiScopeChannelConfig.fromJson(Json j) => NiScopeChannelConfig(
    resource: jString(j['resource'], 'PXI1Slot2'),
    channelId: jInt(j['channelId']),
    range: jDouble(j['range'], 5),
    inputZ: enumByName(NiScopeInputZ.values, j['inputZ'], NiScopeInputZ.megaOhm1),
    coupling: enumByName(NiScopeCoupling.values, j['coupling'], NiScopeCoupling.dc),
    offset: jDouble(j['offset']),
    probeAttenuation: jDouble(j['probeAttenuation'], 1),
    maxInputFrequency: jDouble(j['maxInputFrequency'], -1),
    lowChannelId: j['lowChannelId'] == null ? null : jInt(j['lowChannelId']),
  );
}

enum NiScopeClockSource { clkIn, pxiClk, pfi0, pfi1, none }

enum NiScopeTriggerType { edge, hysteresis, window, digital, software, immediate }

/// Advanced trigger parameters of the TPQA WB setup panel.
class NiScopeTriggerAdvanced {
  NiScopeTriggerType type;
  String source; // "0", "1", "VAL_EXTERNAL", "VAL_PFI_0" ...
  double refPosition; // [%]
  double holdoff; // [s]
  double delay; // [s]
  double hysteresis; // [V]
  bool windowEntering;
  double lowLevel;
  double highLevel;
  NiScopeTriggerAdvanced({
    this.type = NiScopeTriggerType.immediate,
    this.source = '0',
    this.refPosition = 0,
    this.holdoff = 0,
    this.delay = 0,
    this.hysteresis = 0.1,
    this.windowEntering = true,
    this.lowLevel = -0.1,
    this.highLevel = 0.1,
  });
  Json toJson() => {
    'type': type.name,
    'source': source,
    'refPosition': refPosition,
    'holdoff': holdoff,
    'delay': delay,
    'hysteresis': hysteresis,
    'windowEntering': windowEntering,
    'lowLevel': lowLevel,
    'highLevel': highLevel,
  };
  factory NiScopeTriggerAdvanced.fromJson(Json j) => NiScopeTriggerAdvanced(
    type: enumByName(NiScopeTriggerType.values, j['type'], NiScopeTriggerType.immediate),
    source: jString(j['source'], '0'),
    refPosition: jDouble(j['refPosition']),
    holdoff: jDouble(j['holdoff']),
    delay: jDouble(j['delay']),
    hysteresis: jDouble(j['hysteresis'], 0.1),
    windowEntering: jBool(j['windowEntering'], true),
    lowLevel: jDouble(j['lowLevel'], -0.1),
    highLevel: jDouble(j['highLevel'], 0.1),
  );
}

class NiScopeConfig {
  List<NiScopeChannelConfig> channels;
  double extClockHz; // 0 = internal
  NiScopeClockSource extClockSource;
  bool streaming;
  double fetchTimeout; // [s]
  NiScopeTriggerAdvanced trigger;

  NiScopeConfig({
    List<NiScopeChannelConfig>? channels,
    this.extClockHz = 0,
    this.extClockSource = NiScopeClockSource.clkIn,
    this.streaming = false,
    this.fetchTimeout = 20,
    NiScopeTriggerAdvanced? trigger,
  }) : channels = channels ?? [NiScopeChannelConfig(channelId: 0), NiScopeChannelConfig(channelId: 1)],
       trigger = trigger ?? NiScopeTriggerAdvanced();

  Json toJson() => {
    'channels': [for (final c in channels) c.toJson()],
    'extClockHz': extClockHz,
    'extClockSource': extClockSource.name,
    'streaming': streaming,
    'fetchTimeout': fetchTimeout,
    'trigger': trigger.toJson(),
  };

  factory NiScopeConfig.fromJson(Json j) => NiScopeConfig(
    channels: j['channels'] == null
        ? null
        : [for (final c in jMapList(j['channels'])) NiScopeChannelConfig.fromJson(c)],
    extClockHz: jDouble(j['extClockHz']),
    extClockSource: enumByName(NiScopeClockSource.values, j['extClockSource'], NiScopeClockSource.clkIn),
    streaming: jBool(j['streaming']),
    fetchTimeout: jDouble(j['fetchTimeout'], 20),
    trigger: j['trigger'] == null ? null : NiScopeTriggerAdvanced.fromJson(jMap(j['trigger'])),
  );
}

// ------------------------------------------------------------------- 3458A --

enum Dmm3458Mode { dcv, dsdc, dsac }

enum Dmm3458Sync {
  masterSlaveTimer('MASTER-SLAVE, MASTER clocked by TIMER'),
  masterSlaveAwg('MASTER-SLAVE, MASTER clocked by AWG'),
  allAwg('ALL clocked by AWG'),
  allTimer('ALL clocked by TIMER');

  final String label;
  const Dmm3458Sync(this.label);
}

enum Dmm3458IdnMode { auto, sequential, calibrationString }

enum Dmm3458ApertureMode { manual, table, maximum }

enum Dmm3458Format { auto, sint, dint }

enum Dmm3458Memory { standard, option001, memoryOff }

enum AwgType { dummy, agilent33xxx, agilent3352x, tektronixAfg3000, rasHmf2500, cmiClockDivider, cmiSyncV3 }

enum CounterType { none, picotestU62xx }

class DmmChannelConfig {
  String visa;
  double range;
  bool isF8588;
  DmmChannelConfig({this.visa = 'GPIB0::22::INSTR', this.range = 1, this.isF8588 = false});
  Json toJson() => {'visa': visa, 'range': range, 'isF8588': isF8588};
  factory DmmChannelConfig.fromJson(Json j) => DmmChannelConfig(
    visa: jString(j['visa'], 'GPIB0::22::INSTR'),
    range: jDouble(j['range'], 1),
    isF8588: jBool(j['isF8588']),
  );
}

class ApertureRule {
  double fsMax;
  double aperture;
  ApertureRule(this.fsMax, this.aperture);
  Json toJson() => {'fsMax': fsMax, 'aperture': aperture};
  factory ApertureRule.fromJson(Json j) => ApertureRule(jDouble(j['fsMax']), jDouble(j['aperture']));
}

class Hp3458aConfig {
  List<DmmChannelConfig> channels;
  Dmm3458IdnMode idnMode;
  Dmm3458Mode mode;
  Dmm3458Sync sync;
  AwgType awgType;
  String awgVisa;
  CounterType counterType;
  String counterVisa;
  bool streaming;
  bool measureTemperature;
  bool disableDisplay;
  Dmm3458ApertureMode apertureMode;
  List<ApertureRule> apertureTable;
  Dmm3458Format format;
  Dmm3458Memory memory;
  // Fluke 8588A specific
  String f8588Filter;
  bool f8588ExtRefLock;

  Hp3458aConfig({
    List<DmmChannelConfig>? channels,
    this.idnMode = Dmm3458IdnMode.auto,
    this.mode = Dmm3458Mode.dcv,
    this.sync = Dmm3458Sync.masterSlaveTimer,
    this.awgType = AwgType.dummy,
    this.awgVisa = 'GPIB0::10::INSTR',
    this.counterType = CounterType.none,
    this.counterVisa = 'GPIB0::3::INSTR',
    this.streaming = false,
    this.measureTemperature = false,
    this.disableDisplay = true,
    this.apertureMode = Dmm3458ApertureMode.manual,
    List<ApertureRule>? apertureTable,
    this.format = Dmm3458Format.auto,
    this.memory = Dmm3458Memory.standard,
    this.f8588Filter = 'OFF',
    this.f8588ExtRefLock = false,
  }) : channels = channels ?? [DmmChannelConfig(visa: 'GPIB0::22::INSTR'), DmmChannelConfig(visa: 'GPIB0::23::INSTR')],
       apertureTable =
           apertureTable ?? [ApertureRule(8000, 102e-6), ApertureRule(10000, 70e-6), ApertureRule(100000, 1.4e-6)];

  bool get hasF8588 => channels.any((c) => c.isF8588);

  Json toJson() => {
    'channels': [for (final c in channels) c.toJson()],
    'idnMode': idnMode.name,
    'mode': mode.name,
    'sync': sync.name,
    'awgType': awgType.name,
    'awgVisa': awgVisa,
    'counterType': counterType.name,
    'counterVisa': counterVisa,
    'streaming': streaming,
    'measureTemperature': measureTemperature,
    'disableDisplay': disableDisplay,
    'apertureMode': apertureMode.name,
    'apertureTable': [for (final r in apertureTable) r.toJson()],
    'format': format.name,
    'memory': memory.name,
    'f8588Filter': f8588Filter,
    'f8588ExtRefLock': f8588ExtRefLock,
  };

  factory Hp3458aConfig.fromJson(Json j) => Hp3458aConfig(
    channels: j['channels'] == null ? null : [for (final c in jMapList(j['channels'])) DmmChannelConfig.fromJson(c)],
    idnMode: enumByName(Dmm3458IdnMode.values, j['idnMode'], Dmm3458IdnMode.auto),
    mode: enumByName(Dmm3458Mode.values, j['mode'], Dmm3458Mode.dcv),
    sync: enumByName(Dmm3458Sync.values, j['sync'], Dmm3458Sync.masterSlaveTimer),
    awgType: enumByName(AwgType.values, j['awgType'], AwgType.dummy),
    awgVisa: jString(j['awgVisa'], 'GPIB0::10::INSTR'),
    counterType: enumByName(CounterType.values, j['counterType'], CounterType.none),
    counterVisa: jString(j['counterVisa'], 'GPIB0::3::INSTR'),
    streaming: jBool(j['streaming']),
    measureTemperature: jBool(j['measureTemperature']),
    disableDisplay: jBool(j['disableDisplay'], true),
    apertureMode: enumByName(Dmm3458ApertureMode.values, j['apertureMode'], Dmm3458ApertureMode.manual),
    apertureTable: j['apertureTable'] == null
        ? null
        : [for (final r in jMapList(j['apertureTable'])) ApertureRule.fromJson(r)],
    format: enumByName(Dmm3458Format.values, j['format'], Dmm3458Format.auto),
    memory: enumByName(Dmm3458Memory.values, j['memory'], Dmm3458Memory.standard),
    f8588Filter: jString(j['f8588Filter'], 'OFF'),
    f8588ExtRefLock: jBool(j['f8588ExtRefLock']),
  );
}

// -------------------------------------------------------------------- cDAQ --

enum CdaqClockMode { freeRunning, importMasterClock, exportMasterClock }

class CdaqConfig {
  String device;
  List<int> channelIds;
  double fixedRate;
  CdaqClockMode clockMode;
  String clockSource; // e.g. /cDAQ1/PFI0
  double extClockHz;

  CdaqConfig({
    this.device = 'cDAQ1Mod1',
    List<int>? channelIds,
    this.fixedRate = 50000,
    this.clockMode = CdaqClockMode.freeRunning,
    this.clockSource = '/cDAQ1/PFI0',
    this.extClockHz = 12.8e6,
  }) : channelIds = channelIds ?? [0, 1];

  Json toJson() => {
    'device': device,
    'channelIds': channelIds,
    'fixedRate': fixedRate,
    'clockMode': clockMode.name,
    'clockSource': clockSource,
    'extClockHz': extClockHz,
  };

  factory CdaqConfig.fromJson(Json j) => CdaqConfig(
    device: jString(j['device'], 'cDAQ1Mod1'),
    channelIds: j['channelIds'] == null ? null : jIntList(j['channelIds']),
    fixedRate: jDouble(j['fixedRate'], 50000),
    clockMode: enumByName(CdaqClockMode.values, j['clockMode'], CdaqClockMode.freeRunning),
    clockSource: jString(j['clockSource'], '/cDAQ1/PFI0'),
    extClockHz: jDouble(j['extClockHz'], 12.8e6),
  );
}

// ----------------------------------------------------------------- DSO -----

enum DsoCoupling { dc1M, ac1M, dc50 }

class DsoChannelConfig {
  int channelId;
  double range;
  double offset;
  DsoCoupling coupling;
  DsoChannelConfig({this.channelId = 1, this.range = 1, this.offset = 0, this.coupling = DsoCoupling.dc1M});
  Json toJson() => {'channelId': channelId, 'range': range, 'offset': offset, 'coupling': coupling.name};
  factory DsoChannelConfig.fromJson(Json j) => DsoChannelConfig(
    channelId: jInt(j['channelId'], 1),
    range: jDouble(j['range'], 1),
    offset: jDouble(j['offset']),
    coupling: enumByName(DsoCoupling.values, j['coupling'], DsoCoupling.dc1M),
  );
}

class DsoConfig {
  String visa;
  List<DsoChannelConfig> channels;
  double bwLimit; // -1 disabled
  String bitResolution; // Auto / 10..16
  String noiseReject; // Normal / ON

  DsoConfig({
    this.visa = 'USB0::0x2A8D::0x9049::MY00000000::0::INSTR',
    List<DsoChannelConfig>? channels,
    this.bwLimit = -1,
    this.bitResolution = 'Auto',
    this.noiseReject = 'Normal',
  }) : channels = channels ?? [DsoChannelConfig(channelId: 1), DsoChannelConfig(channelId: 2)];

  Json toJson() => {
    'visa': visa,
    'channels': [for (final c in channels) c.toJson()],
    'bwLimit': bwLimit,
    'bitResolution': bitResolution,
    'noiseReject': noiseReject,
  };

  factory DsoConfig.fromJson(Json j) => DsoConfig(
    visa: jString(j['visa'], 'USB0::0x2A8D::0x9049::MY00000000::0::INSTR'),
    channels: j['channels'] == null ? null : [for (final c in jMapList(j['channels'])) DsoChannelConfig.fromJson(c)],
    bwLimit: jDouble(j['bwLimit'], -1),
    bitResolution: jString(j['bitResolution'], 'Auto'),
    noiseReject: jString(j['noiseReject'], 'Normal'),
  );
}

// ------------------------------------------------------------ sound card ---

class SoundCardConfig {
  String device;
  int channels; // 1 or 2
  int bits; // 16 / 24 / 32
  double range; // assumed full scale [Vpk]

  SoundCardConfig({this.device = 'default', this.channels = 2, this.bits = 16, this.range = 1});

  Json toJson() => {'device': device, 'channels': channels, 'bits': bits, 'range': range};
  factory SoundCardConfig.fromJson(Json j) => SoundCardConfig(
    device: jString(j['device'], 'default'),
    channels: jInt(j['channels'], 2),
    bits: jInt(j['bits'], 16),
    range: jDouble(j['range'], 1),
  );
}

// --------------------------------------------------------------- ADS127 -----

class Ads127Config {
  String visa; // serial port / TCP resource
  int channels;
  double range;
  bool extRef; // external 10 MHz
  String inputMode; // SE / DIFF
  String inputZ; // 1M / 10M / HiZ

  Ads127Config({
    this.visa = 'ASRL3::INSTR',
    this.channels = 2,
    this.range = 10,
    this.extRef = false,
    this.inputMode = 'DIFF',
    this.inputZ = '1M',
  });

  Json toJson() => {
    'visa': visa,
    'channels': channels,
    'range': range,
    'extRef': extRef,
    'inputMode': inputMode,
    'inputZ': inputZ,
  };
  factory Ads127Config.fromJson(Json j) => Ads127Config(
    visa: jString(j['visa'], 'ASRL3::INSTR'),
    channels: jInt(j['channels'], 2),
    range: jDouble(j['range'], 10),
    extRef: jBool(j['extRef']),
    inputMode: jString(j['inputMode'], 'DIFF'),
    inputZ: jString(j['inputZ'], '1M'),
  );
}

// ------------------------------------------------------------- top level ---

class DigitizerConfig {
  DigitizerType type;
  OnCloseAction onClose;
  double delayedResetTimeout; // [s]
  bool forceResetOnOpen;
  bool ignoreOverload;
  MultiplexerConfig multiplexer;

  SimulatedConfig simulated;
  NiScopeConfig niScope;
  Hp3458aConfig hp3458a;
  CdaqConfig cdaq;
  DsoConfig dso;
  SoundCardConfig soundCard;
  Ads127Config ads127;

  DigitizerConfig({
    this.type = DigitizerType.simulated,
    this.onClose = OnCloseAction.delayedReset,
    this.delayedResetTimeout = 300,
    this.forceResetOnOpen = false,
    this.ignoreOverload = false,
    MultiplexerConfig? multiplexer,
    SimulatedConfig? simulated,
    NiScopeConfig? niScope,
    Hp3458aConfig? hp3458a,
    CdaqConfig? cdaq,
    DsoConfig? dso,
    SoundCardConfig? soundCard,
    Ads127Config? ads127,
  }) : multiplexer = multiplexer ?? MultiplexerConfig(),
       simulated = simulated ?? SimulatedConfig(),
       niScope = niScope ?? NiScopeConfig(),
       hp3458a = hp3458a ?? Hp3458aConfig(),
       cdaq = cdaq ?? CdaqConfig(),
       dso = dso ?? DsoConfig(),
       soundCard = soundCard ?? SoundCardConfig(),
       ads127 = ads127 ?? Ads127Config();

  /// Number of physical virtual channels of the selected digitizer.
  int get physicalChannelsCount => switch (type) {
    DigitizerType.simulated => simulated.channels.length,
    DigitizerType.niScope => niScope.channels.length,
    DigitizerType.hp3458a => hp3458a.channels.length,
    DigitizerType.cdaq => cdaq.channelIds.length,
    DigitizerType.keysightDso => dso.channels.length,
    DigitizerType.soundCard => soundCard.channels,
    DigitizerType.ads127l21 => ads127.channels,
  };

  /// Channel count including time multiplexing.
  int get virtualChannelsCount => physicalChannelsCount * multiplexer.cycles;

  /// Default ranges per physical channel.
  List<double> get defaultRanges => switch (type) {
    DigitizerType.simulated => [for (final c in simulated.channels) c.range],
    DigitizerType.niScope => [for (final c in niScope.channels) c.range],
    DigitizerType.hp3458a => [for (final c in hp3458a.channels) c.range],
    DigitizerType.cdaq => [for (final _ in cdaq.channelIds) 10.0],
    DigitizerType.keysightDso => [for (final c in dso.channels) c.range],
    DigitizerType.soundCard => List.filled(soundCard.channels, soundCard.range),
    DigitizerType.ads127l21 => List.filled(ads127.channels, ads127.range),
  };

  /// Short channel labels for selectors in the corrections panel
  /// ("#1", "#2", ... and with multiplexer "#1 (A)").
  List<String> get channelLabels {
    final n = physicalChannelsCount;
    if (!multiplexer.enabled) return [for (var i = 1; i <= n; i++) '#$i'];
    return [
      for (final p in multiplexer.sequence)
        for (var i = 1; i <= n; i++) '#$i ($p)',
    ];
  }

  Json toJson() => {
    'type': type.name,
    'onClose': onClose.name,
    'delayedResetTimeout': delayedResetTimeout,
    'forceResetOnOpen': forceResetOnOpen,
    'ignoreOverload': ignoreOverload,
    'multiplexer': multiplexer.toJson(),
    'simulated': simulated.toJson(),
    'niScope': niScope.toJson(),
    'hp3458a': hp3458a.toJson(),
    'cdaq': cdaq.toJson(),
    'dso': dso.toJson(),
    'soundCard': soundCard.toJson(),
    'ads127': ads127.toJson(),
  };

  factory DigitizerConfig.fromJson(Json j) => DigitizerConfig(
    type: enumByName(DigitizerType.values, j['type'], DigitizerType.simulated),
    onClose: enumByName(OnCloseAction.values, j['onClose'], OnCloseAction.delayedReset),
    delayedResetTimeout: jDouble(j['delayedResetTimeout'], 300),
    forceResetOnOpen: jBool(j['forceResetOnOpen']),
    ignoreOverload: jBool(j['ignoreOverload']),
    multiplexer: j['multiplexer'] == null ? null : MultiplexerConfig.fromJson(jMap(j['multiplexer'])),
    simulated: j['simulated'] == null ? null : SimulatedConfig.fromJson(jMap(j['simulated'])),
    niScope: j['niScope'] == null ? null : NiScopeConfig.fromJson(jMap(j['niScope'])),
    hp3458a: j['hp3458a'] == null ? null : Hp3458aConfig.fromJson(jMap(j['hp3458a'])),
    cdaq: j['cdaq'] == null ? null : CdaqConfig.fromJson(jMap(j['cdaq'])),
    dso: j['dso'] == null ? null : DsoConfig.fromJson(jMap(j['dso'])),
    soundCard: j['soundCard'] == null ? null : SoundCardConfig.fromJson(jMap(j['soundCard'])),
    ads127: j['ads127'] == null ? null : Ads127Config.fromJson(jMap(j['ads127'])),
  );

  DigitizerConfig copy() => DigitizerConfig.fromJson(toJson());
}
