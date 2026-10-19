import 'package:twm_model/twm_model.dart';

import 'simulated_digitizer.dart';
import 'virtual_digitizer.dart';

/// Registry of digitizer driver constructors. Hardware drivers register
/// themselves here (see `drivers/`), so the core does not depend on any
/// particular instrument library.
class DigitizerFactory {
  static final Map<DigitizerType, VirtualDigitizer Function(DigitizerConfig)> _drivers = {
    DigitizerType.simulated: SimulatedDigitizer.new,
  };

  static void register(DigitizerType t, VirtualDigitizer Function(DigitizerConfig) ctor) => _drivers[t] = ctor;

  static bool isAvailable(DigitizerType t) => _drivers.containsKey(t);

  static VirtualDigitizer create(DigitizerConfig cfg) {
    final ctor = _drivers[cfg.type];
    if (ctor == null) {
      throw DigitizerException('Driver for "${cfg.type.label}" is not available in this build.');
    }
    return ctor(cfg);
  }
}
