import 'package:twm_model/twm_model.dart';

import '../../digitizer/virtual_digitizer.dart';
import '../../multiplexer/multiplexer.dart';
import '../io/instrument_io.dart';
import '../niscope/niscope_digitizer.dart';

/// Generic COM port multiplexer: up to four paths by DTR/RTS line states
/// (TWM "Generic COM" multiplexer driver).
class ComPortMultiplexer extends Multiplexer {
  ComPortMultiplexer(super.config);
  InstrumentIo? _io;

  @override
  Future<void> open() async => _io = await InstrumentIoFactory.open(config.visa);

  @override
  Future<void> select(String path) async {
    final p = config.paths.firstWhere(
      (e) => e.name == path,
      orElse: () => throw DigitizerException('Unknown multiplexer path "$path"'),
    );
    await _io!.setControlLines(dtr: p.primary, rts: p.secondary);
  }

  @override
  Future<void> close() async {
    await _io?.close();
    _io = null;
  }
}

/// Multiplexer controlled by text commands (TWM "Generic VISA commands",
/// also used for QPMX with the command strings of the device).
class VisaCommandMultiplexer extends Multiplexer {
  VisaCommandMultiplexer(super.config);
  InstrumentIo? _io;

  @override
  Future<void> open() async => _io = await InstrumentIoFactory.open(config.visa);

  @override
  Future<void> select(String path) async {
    final p = config.paths.firstWhere(
      (e) => e.name == path,
      orElse: () => throw DigitizerException('Unknown multiplexer path "$path"'),
    );
    if (p.command.isEmpty) throw DigitizerException('No command defined for multiplexer path "$path"');
    await _io!.write(p.command);
  }

  @override
  Future<void> close() async {
    await _io?.close();
    _io = null;
  }
}

/// Multiplexer switched by 10 MHz reference exported to PFI0/PFI1 of a NI
/// 5922 card (TWM "Generic niScope" experimental multiplexer).
class NiScopePfiMultiplexer extends Multiplexer {
  final NiScopeDigitizer digitizer;
  NiScopePfiMultiplexer(super.config, this.digitizer);

  @override
  Future<void> open() async {}

  @override
  Future<void> select(String path) async {
    final p = config.paths.firstWhere(
      (e) => e.name == path,
      orElse: () => throw DigitizerException('Unknown multiplexer path "$path"'),
    );
    digitizer.exportPfi(config.niScopeChannelIndex, p.primary ? 'VAL_PFI_0' : 'VAL_PFI_1');
  }

  @override
  Future<void> close() async {}
}

/// Creates the multiplexer driver for [cfg]; [digitizer] is needed for the
/// niScope PFI mode. Simulated digitizer uses the dummy multiplexer.
Multiplexer createMultiplexer(MultiplexerConfig cfg, VirtualDigitizer digitizer) {
  if (digitizer.config.type == DigitizerType.simulated) return DummyMultiplexer(cfg);
  return switch (cfg.type) {
    MultiplexerType.comPort => ComPortMultiplexer(cfg),
    MultiplexerType.visaCommands || MultiplexerType.qpmx => VisaCommandMultiplexer(cfg),
    MultiplexerType.niScopePfi =>
      digitizer is NiScopeDigitizer
          ? NiScopePfiMultiplexer(cfg, digitizer)
          : throw DigitizerException('niScope PFI multiplexer requires niScope digitizer.'),
  };
}
