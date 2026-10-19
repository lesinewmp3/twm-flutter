/// Registration of the hardware digitizer drivers into [DigitizerFactory].
library;

import 'package:twm_model/twm_model.dart';

import '../digitizer/digitizer_factory.dart';
import 'daqmx/cdaq_digitizer.dart';
import 'dmm/ads127_digitizer.dart';
import 'dmm/hp3458a_digitizer.dart';
import 'dso/keysight_dso_digitizer.dart';
import 'emu/emu_3458a.dart';
import 'emu/emu_dso.dart';
import 'io/instrument_io.dart';
import 'niscope/niscope_digitizer.dart';
import 'sound/sound_card_digitizer.dart';

bool _registered = false;

/// Registers all hardware drivers and instrument emulators (`SIM::...`
/// VISA resources) available in this build. Call once at application start.
void registerHardwareDrivers() {
  if (_registered) return;
  _registered = true;
  DigitizerFactory.register(DigitizerType.hp3458a, Hp3458aDigitizer.new);
  DigitizerFactory.register(DigitizerType.soundCard, SoundCardDigitizer.new);
  DigitizerFactory.register(DigitizerType.niScope, NiScopeDigitizer.new);
  DigitizerFactory.register(DigitizerType.cdaq, CdaqDigitizer.new);
  DigitizerFactory.register(DigitizerType.keysightDso, KeysightDsoDigitizer.new);
  DigitizerFactory.register(DigitizerType.ads127l21, Ads127Digitizer.new);
  InstrumentIoFactory.registerEmulator('3458A', (r) async => Emu3458a(r));
  InstrumentIoFactory.registerEmulator('DSO', (r) async => EmuDso(r));
}
