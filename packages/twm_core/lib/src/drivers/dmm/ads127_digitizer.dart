import 'package:twm_model/twm_model.dart';

import '../../digitizer/virtual_digitizer.dart';

/// CMI ADS127L21 experimental digitizer. Its communication protocol is not
/// public (TWM contains only binary LabVIEW VIs), so this port cannot
/// implement it without the protocol description or the device.
class Ads127Digitizer extends VirtualDigitizer {
  Ads127Digitizer(super.config);

  static const _msg =
      'CMI ADS127L21: communication protocol is not public - driver not available in this port. '
      'Contact CMI (TWM authors) for the protocol description.';

  @override
  bool get isOpen => false;
  @override
  Future<void> initialize({bool reset = false}) async => throw DigitizerException(_msg);
  @override
  DigitizerCapabilities capabilities({double? fs, double? aperture}) =>
      DigitizerCapabilities(maxSamplesCount: 0, maxFs: 0, minFs: 0, channelsCount: config.ads127.channels);
  @override
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  }) async => throw DigitizerException(_msg);
  @override
  Future<void> initiate() async => throw DigitizerException(_msg);
  @override
  Future<FetchResult> fetch() async => throw DigitizerException(_msg);
  @override
  Future<void> abort() async {}
  @override
  Future<void> cleanup() async {}
  @override
  Future<void> close({bool resetToPreset = true}) async {}
  @override
  DigitizerSetup currentSetup() => DigitizerSetup(
    samplesCount: 0,
    channelsCount: config.ads127.channels,
    fs: 0,
    ranges: const [],
    trigger: TriggerConfig(),
    bitResolution: 24,
  );
  @override
  String info() => _msg;
}
