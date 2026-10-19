import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Low level sound capture backends (TWM "dsdll" DirectSound driver
/// replacement): ALSA on Linux, winmm waveIn on Windows. Capture runs in
/// a separate isolate (blocking reads).
abstract class SoundBackend {
  List<String> devices();
}

// ---------------------------------------------------------------- ALSA -----

typedef _PcmOpenN = Int32 Function(Pointer<Pointer<Void>>, Pointer<Utf8>, Int32, Int32);
typedef _PcmOpenD = int Function(Pointer<Pointer<Void>>, Pointer<Utf8>, int, int);
typedef _SetParamsN = Int32 Function(Pointer<Void>, Int32, Int32, Uint32, Uint32, Int32, Uint32);
typedef _SetParamsD = int Function(Pointer<Void>, int, int, int, int, int, int);
typedef _ReadiN = Long Function(Pointer<Void>, Pointer<Void>, UnsignedLong);
typedef _ReadiD = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _PcmN = Int32 Function(Pointer<Void>);
typedef _PcmD = int Function(Pointer<Void>);
typedef _RecoverN = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _RecoverD = int Function(Pointer<Void>, int, int);
typedef _StrerrorN = Pointer<Utf8> Function(Int32);
typedef _StrerrorD = Pointer<Utf8> Function(int);
typedef _HintN = Int32 Function(Int32, Pointer<Utf8>, Pointer<Pointer<Pointer<Void>>>);
typedef _HintD = int Function(int, Pointer<Utf8>, Pointer<Pointer<Pointer<Void>>>);
typedef _GetHintN = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetHintD = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _FreeHintN = Int32 Function(Pointer<Pointer<Void>>);
typedef _FreeHintD = int Function(Pointer<Pointer<Void>>);

class Alsa {
  static const captureStream = 1;
  static const accessRwInterleaved = 3;
  static const formatS16le = 2;
  static const formatS32le = 10;

  final DynamicLibrary lib;
  late final open = lib.lookupFunction<_PcmOpenN, _PcmOpenD>('snd_pcm_open');
  late final setParams = lib.lookupFunction<_SetParamsN, _SetParamsD>('snd_pcm_set_params');
  late final readi = lib.lookupFunction<_ReadiN, _ReadiD>('snd_pcm_readi');
  late final close = lib.lookupFunction<_PcmN, _PcmD>('snd_pcm_close');
  late final drop = lib.lookupFunction<_PcmN, _PcmD>('snd_pcm_drop');
  late final recover = lib.lookupFunction<_RecoverN, _RecoverD>('snd_pcm_recover');
  late final strerror = lib.lookupFunction<_StrerrorN, _StrerrorD>('snd_strerror');
  late final nameHint = lib.lookupFunction<_HintN, _HintD>('snd_device_name_hint');
  late final getHint = lib.lookupFunction<_GetHintN, _GetHintD>('snd_device_name_get_hint');
  late final freeHint = lib.lookupFunction<_FreeHintN, _FreeHintD>('snd_device_name_free_hint');

  Alsa() : lib = DynamicLibrary.open('libasound.so.2');

  String error(int e) => strerror(e).toDartString();

  /// Capture capable PCM device names.
  List<String> devices() {
    final out = <String>['default'];
    final hints = calloc<Pointer<Pointer<Void>>>();
    final iface = 'pcm'.toNativeUtf8();
    final kName = 'NAME'.toNativeUtf8();
    final kIo = 'IOID'.toNativeUtf8();
    try {
      if (nameHint(-1, iface, hints) < 0) return out;
      for (var i = 0; ; i++) {
        final h = hints.value[i];
        if (h == nullptr) break;
        final n = getHint(h, kName);
        final io = getHint(h, kIo);
        final name = n == nullptr ? '' : n.toDartString();
        final ioid = io == nullptr ? '' : io.toDartString();
        if (n != nullptr) malloc.free(n);
        if (io != nullptr) malloc.free(io);
        if (name.isNotEmpty && name != 'null' && ioid != 'Output' && !out.contains(name)) out.add(name);
      }
      freeHint(hints.value);
    } finally {
      calloc.free(hints);
      calloc.free(iface);
      calloc.free(kName);
      calloc.free(kIo);
    }
    return out;
  }
}

// ------------------------------------------------------------- winmm -------

final class _WaveFormatEx extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

final class _WaveHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<Void> lpNext;
  @IntPtr()
  external int reserved;
}

final class _WaveInCapsW extends Struct {
  @Uint16()
  external int wMid;
  @Uint16()
  external int wPid;
  @Uint32()
  external int vDriverVersion;
  @Array(32)
  external Array<Uint16> szPname;
  @Uint32()
  external int dwFormats;
  @Uint16()
  external int wChannels;
  @Uint16()
  external int wReserved1;
}

typedef _WiOpenN = Uint32 Function(Pointer<IntPtr>, Uint32, Pointer<_WaveFormatEx>, IntPtr, IntPtr, Uint32);
typedef _WiOpenD = int Function(Pointer<IntPtr>, int, Pointer<_WaveFormatEx>, int, int, int);
typedef _WiHdrN = Uint32 Function(IntPtr, Pointer<_WaveHdr>, Uint32);
typedef _WiHdrD = int Function(int, Pointer<_WaveHdr>, int);
typedef _WiN = Uint32 Function(IntPtr);
typedef _WiD = int Function(int);
typedef _WiNumN = Uint32 Function();
typedef _WiNumD = int Function();
typedef _WiCapsN = Uint32 Function(UintPtr, Pointer<_WaveInCapsW>, Uint32);
typedef _WiCapsD = int Function(int, Pointer<_WaveInCapsW>, int);

class WinMM {
  final DynamicLibrary lib = DynamicLibrary.open('winmm.dll');
  late final open = lib.lookupFunction<_WiOpenN, _WiOpenD>('waveInOpen');
  late final prepare = lib.lookupFunction<_WiHdrN, _WiHdrD>('waveInPrepareHeader');
  late final unprepare = lib.lookupFunction<_WiHdrN, _WiHdrD>('waveInUnprepareHeader');
  late final addBuffer = lib.lookupFunction<_WiHdrN, _WiHdrD>('waveInAddBuffer');
  late final start = lib.lookupFunction<_WiN, _WiD>('waveInStart');
  late final reset = lib.lookupFunction<_WiN, _WiD>('waveInReset');
  late final close = lib.lookupFunction<_WiN, _WiD>('waveInClose');
  late final numDevs = lib.lookupFunction<_WiNumN, _WiNumD>('waveInGetNumDevs');
  late final caps = lib.lookupFunction<_WiCapsN, _WiCapsD>('waveInGetDevCapsW');

  static const waveMapper = 0xFFFFFFFF;
  static const whdrDone = 1;

  List<String> devices() {
    final out = <String>['default'];
    final c = calloc<_WaveInCapsW>();
    try {
      for (var i = 0; i < numDevs(); i++) {
        if (caps(i, c, sizeOf<_WaveInCapsW>()) != 0) continue;
        final chars = <int>[];
        for (var k = 0; k < 32; k++) {
          final ch = c.ref.szPname[k];
          if (ch == 0) break;
          chars.add(ch);
        }
        out.add('$i: ${String.fromCharCodes(chars)}');
      }
    } finally {
      calloc.free(c);
    }
    return out;
  }
}

List<String> soundDevices() {
  if (Platform.isLinux) return Alsa().devices();
  if (Platform.isWindows) return WinMM().devices();
  return const [];
}

// ------------------------------------------------------- capture isolate ----

class CaptureRequest {
  final String device;
  final int channels;
  final int rate;
  final int bits; // 16 or 32 (24 bit cards deliver 32 bit containers)
  final int samples;
  final SendPort port;
  const CaptureRequest(this.device, this.channels, this.rate, this.bits, this.samples, this.port);
}

/// Isolate entry: captures [CaptureRequest.samples] frames and sends
/// Int32List blocks (interleaved), then `null` when done, or a String on
/// error.
void captureMain(CaptureRequest r) {
  try {
    if (Platform.isLinux) {
      _captureAlsa(r);
    } else if (Platform.isWindows) {
      _captureWinMM(r);
    } else {
      r.port.send('Sound capture is not supported on ${Platform.operatingSystem}.');
      return;
    }
    r.port.send(null);
  } catch (e) {
    r.port.send('$e');
  }
}

void _captureAlsa(CaptureRequest r) {
  final a = Alsa();
  final pcmp = calloc<Pointer<Void>>();
  final name = r.device.toNativeUtf8();
  var err = a.open(pcmp, name, Alsa.captureStream, 0);
  calloc.free(name);
  if (err < 0) throw 'snd_pcm_open(${r.device}): ${a.error(err)}';
  final pcm = pcmp.value;
  calloc.free(pcmp);
  try {
    final fmt = r.bits == 16 ? Alsa.formatS16le : Alsa.formatS32le;
    err = a.setParams(pcm, fmt, Alsa.accessRwInterleaved, r.channels, r.rate, 0, 200000);
    if (err < 0) throw 'snd_pcm_set_params(${r.rate} Hz, ${r.channels} ch, ${r.bits} bit): ${a.error(err)}';
    final bps = r.bits == 16 ? 2 : 4;
    const block = 4096;
    final buf = calloc<Uint8>(block * r.channels * bps);
    try {
      var got = 0;
      while (got < r.samples) {
        final want = r.samples - got < block ? r.samples - got : block;
        var n = a.readi(pcm, buf.cast(), want);
        if (n < 0) {
          n = a.recover(pcm, n, 1);
          if (n < 0) throw 'snd_pcm_readi: ${a.error(n)}';
          continue;
        }
        final out = Int32List(n * r.channels);
        if (bps == 2) {
          final s = buf.cast<Int16>().asTypedList(n * r.channels);
          for (var i = 0; i < out.length; i++) {
            out[i] = s[i];
          }
        } else {
          out.setAll(0, buf.cast<Int32>().asTypedList(n * r.channels));
        }
        r.port.send(TransferableTypedData.fromList([out]));
        got += n;
      }
    } finally {
      calloc.free(buf);
    }
  } finally {
    a.drop(pcm);
    a.close(pcm);
  }
}

void _captureWinMM(CaptureRequest r) {
  final w = WinMM();
  final bps = r.bits == 16 ? 2 : 4;
  final wf = calloc<_WaveFormatEx>();
  wf.ref
    ..wFormatTag =
        1 // WAVE_FORMAT_PCM
    ..nChannels = r.channels
    ..nSamplesPerSec = r.rate
    ..wBitsPerSample = r.bits
    ..nBlockAlign = r.channels * bps
    ..nAvgBytesPerSec = r.rate * r.channels * bps
    ..cbSize = 0;
  final h = calloc<IntPtr>();
  final dev = r.device == 'default' ? WinMM.waveMapper : int.tryParse(r.device.split(':').first) ?? WinMM.waveMapper;
  var err = w.open(h, dev, wf, 0, 0, 0);
  calloc.free(wf);
  if (err != 0) throw 'waveInOpen failed (MMRESULT $err)';
  final hwi = h.value;
  calloc.free(h);
  const nbuf = 8;
  final frames = (r.rate ~/ 20).clamp(256, 1 << 16);
  final hdrs = <Pointer<_WaveHdr>>[];
  try {
    for (var i = 0; i < nbuf; i++) {
      final hd = calloc<_WaveHdr>();
      hd.ref
        ..lpData = calloc<Uint8>(frames * r.channels * bps)
        ..dwBufferLength = frames * r.channels * bps
        ..dwFlags = 0;
      w.prepare(hwi, hd, sizeOf<_WaveHdr>());
      w.addBuffer(hwi, hd, sizeOf<_WaveHdr>());
      hdrs.add(hd);
    }
    err = w.start(hwi);
    if (err != 0) throw 'waveInStart failed (MMRESULT $err)';
    var got = 0;
    var k = 0;
    while (got < r.samples) {
      final hd = hdrs[k % nbuf];
      while (hd.ref.dwFlags & WinMM.whdrDone == 0) {
        sleep(const Duration(milliseconds: 5));
      }
      final n = hd.ref.dwBytesRecorded ~/ (r.channels * bps);
      final take = n < r.samples - got ? n : r.samples - got;
      final out = Int32List(take * r.channels);
      if (bps == 2) {
        final s = hd.ref.lpData.cast<Int16>().asTypedList(take * r.channels);
        for (var i = 0; i < out.length; i++) {
          out[i] = s[i];
        }
      } else {
        out.setAll(0, hd.ref.lpData.cast<Int32>().asTypedList(take * r.channels));
      }
      r.port.send(TransferableTypedData.fromList([out]));
      got += take;
      hd.ref.dwFlags &= ~WinMM.whdrDone;
      w.addBuffer(hwi, hd, sizeOf<_WaveHdr>());
      k++;
    }
  } finally {
    w.reset(hwi);
    for (final hd in hdrs) {
      w.unprepare(hwi, hd, sizeOf<_WaveHdr>());
      calloc.free(hd.ref.lpData);
      calloc.free(hd);
    }
    w.close(hwi);
  }
}
