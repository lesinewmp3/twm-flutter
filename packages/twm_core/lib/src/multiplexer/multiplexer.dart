import 'package:twm_model/twm_model.dart';

/// Time multiplexer driver (TWM "drivers/Multiplexers").
abstract class Multiplexer {
  final MultiplexerConfig config;
  Multiplexer(this.config);

  Future<void> open();
  Future<void> select(String path);
  Future<void> close();
}

/// Multiplexer used with the simulated digitizer / for testing: only
/// remembers the selected path.
class DummyMultiplexer extends Multiplexer {
  DummyMultiplexer(super.config);
  String? selected;

  @override
  Future<void> open() async {}

  @override
  Future<void> select(String path) async {
    if (!config.paths.any((p) => p.name == path)) {
      throw ArgumentError('Unknown multiplexer path "$path"');
    }
    selected = path;
  }

  @override
  Future<void> close() async {}
}
