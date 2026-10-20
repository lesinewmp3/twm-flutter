/// Virtual digitizer - the TWM driver abstraction layer (A245 "Virtual
/// driver function reference manual"). Each physical digitizer driver
/// implements this interface; the acquisition engine never talks to the
/// instruments directly.
library;

import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

/// Block of samples returned by [VirtualDigitizer.fetch].
///
/// Samples are interleaved per sample (`s0c0, s0c1, ... s1c0, s1c1 ...`),
/// which is exactly the column-major layout of the MAT v4 `y` variable with
/// one row per channel, so blocks can be streamed straight to the file.
class DataPacket {
  final Int32List samples;
  final int channels;

  /// Offset of the first sample of the block from start of acquisition.
  final int offset;

  /// Samples per channel in this block.
  int get count => channels == 0 ? 0 : samples.length ~/ channels;

  /// Data fit into int16 (stored as int16 in the record file).
  final bool isInt16;

  const DataPacket(this.samples, this.channels, this.offset, {this.isInt16 = false});

  /// Channel [c] of the block as doubles.
  Float64List channel(int c, {double gain = 1, double offset = 0}) {
    final n = count;
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = samples[i * channels + c] * gain + offset;
    }
    return out;
  }
}

/// Scaling and timing information of a record ("aux data" cluster).
class AuxData {
  /// u = gain*y + offset, one per channel.
  final List<double> gains;
  final List<double> offsets;

  /// Relative time stamp of the first sample of each channel [s].
  final List<double> timestamps;

  /// Sampling period [s].
  final double increment;

  /// Optional temperature readings per channel [deg C].
  final List<double> temperatures;

  const AuxData({
    required this.gains,
    required this.offsets,
    required this.timestamps,
    required this.increment,
    this.temperatures = const [],
  });
}

class FetchResult {
  final DataPacket? packet;
  final AuxData? aux;
  final bool done;
  final DigitizerStatus status;
  const FetchResult({this.packet, this.aux, this.done = false, this.status = const DigitizerStatus()});
}

/// Common attributes returned by [VirtualDigitizer.currentSetup].
class DigitizerSetup {
  final int samplesCount;
  final int channelsCount;
  final double fs;
  final List<double> ranges;
  final TriggerConfig trigger;
  final double aperture;
  final bool extFreqLocked;
  final bool streaming;
  final bool isInt16;
  final int bitResolution;
  final List<DeviceAttribute> deviceAttributes;

  const DigitizerSetup({
    required this.samplesCount,
    required this.channelsCount,
    required this.fs,
    required this.ranges,
    required this.trigger,
    this.aperture = 0,
    this.extFreqLocked = false,
    this.streaming = false,
    this.isInt16 = false,
    required this.bitResolution,
    this.deviceAttributes = const [],
  });
}

class DigitizerException implements Exception {
  final String message;
  DigitizerException(this.message);
  @override
  String toString() => message;
}

abstract class VirtualDigitizer {
  DigitizerConfig config;
  VirtualDigitizer(this.config);

  /// Identifiers of the virtual channels (must match digitizer correction
  /// 'channel identifiers'). Valid after [initialize].
  List<String> channelIdns = [];

  /// Identifiers of auxiliary instruments (AWG, counter...).
  List<String> auxIdns = [];

  bool get isOpen;

  /// Optional one time driver initialization (on application start).
  Future<void> initializeDriver() async {}

  /// Enumerates devices for the configuration panel (optional).
  Future<List<String>> enumerateDevices() async => [];

  /// Opens and identifies all instruments of the virtual digitizer.
  Future<void> initialize({bool reset = false});

  /// Capabilities; must not touch HW (uses state from last [initialize]).
  DigitizerCapabilities capabilities({double? fs, double? aperture});

  /// Configures the digitizer for a group of records.
  Future<void> setup({
    required double fs,
    required int samplesCount,
    required TriggerConfig trigger,
    required double aperture,
    required List<double> ranges,
  });

  /// Arms the digitizer and returns immediately.
  Future<void> initiate();

  /// Polls for data. Must eventually return [FetchResult.done] = true.
  Future<FetchResult> fetch();

  /// Signals abort of the running acquisition.
  Future<void> abort();

  /// Cleans after a record (always called, even on error).
  Future<void> cleanup();

  /// Closes the instruments; [resetToPreset] puts them in a safe state.
  Future<void> close({bool resetToPreset = true});

  Future<void> selfCalibrate() async {
    throw DigitizerException('Self-calibration is not supported by this digitizer.');
  }

  /// Last used configuration (does not touch HW).
  DigitizerSetup currentSetup();

  /// Brief description of the configuration for the digitizer panel.
  String info();
}
