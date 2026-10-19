import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'instrument_io.dart';

// VISA types: ViSession/ViStatus/ViUInt32 are 32 bit, ViAttrState is
// ULONG_PTR (pointer sized) in VISA 5+ 64-bit libraries.
typedef _OpenDefaultRMN = Int32 Function(Pointer<Uint32>);
typedef _OpenDefaultRMD = int Function(Pointer<Uint32>);
typedef _OpenN = Int32 Function(Uint32, Pointer<Utf8>, Uint32, Uint32, Pointer<Uint32>);
typedef _OpenD = int Function(int, Pointer<Utf8>, int, int, Pointer<Uint32>);
typedef _CloseN = Int32 Function(Uint32);
typedef _CloseD = int Function(int);
typedef _RwN = Int32 Function(Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _RwD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _SetAttrN = Int32 Function(Uint32, Uint32, UintPtr);
typedef _SetAttrD = int Function(int, int, int);
typedef _StatusDescN = Int32 Function(Uint32, Int32, Pointer<Utf8>);
typedef _StatusDescD = int Function(int, int, Pointer<Utf8>);
typedef _FindRsrcN = Int32 Function(Uint32, Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf8>);
typedef _FindRsrcD = int Function(int, Pointer<Utf8>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf8>);
typedef _FindNextN = Int32 Function(Uint32, Pointer<Utf8>);
typedef _FindNextD = int Function(int, Pointer<Utf8>);
typedef _GpibCtrlRenN = Int32 Function(Uint32, Uint16);
typedef _GpibCtrlRenD = int Function(int, int);

/// VISA constants (visa.h).
class Visa {
  static const attrTmoValue = 0x3FFF001A;
  static const attrTermChar = 0x3FFF0018;
  static const attrTermCharEn = 0x3FFF0038;
  static const attrSendEndEn = 0x3FFF0016;
  static const attrAsrlDtrState = 0x3FFF00B1;
  static const attrAsrlRtsState = 0x3FFF00C0;
  static const errorTmo = -1073807339; // 0xBFFF0015
  static const gpibRenGtl = 6; // VI_GPIB_REN_ADDRESS_GTL
}

/// NI-VISA (or compatible: Keysight IO Libraries, R&S VISA) binding.
class VisaLib {
  final DynamicLibrary lib;
  late final _OpenDefaultRMD openDefaultRM = lib.lookupFunction<_OpenDefaultRMN, _OpenDefaultRMD>('viOpenDefaultRM');
  late final _OpenD open = lib.lookupFunction<_OpenN, _OpenD>('viOpen');
  late final _CloseD close = lib.lookupFunction<_CloseN, _CloseD>('viClose');
  late final _RwD write = lib.lookupFunction<_RwN, _RwD>('viWrite');
  late final _RwD read = lib.lookupFunction<_RwN, _RwD>('viRead');
  late final _SetAttrD setAttribute = lib.lookupFunction<_SetAttrN, _SetAttrD>('viSetAttribute');
  late final _CloseD clear = lib.lookupFunction<_CloseN, _CloseD>('viClear');
  late final _StatusDescD statusDesc = lib.lookupFunction<_StatusDescN, _StatusDescD>('viStatusDesc');
  late final _FindRsrcD findRsrc = lib.lookupFunction<_FindRsrcN, _FindRsrcD>('viFindRsrc');
  late final _FindNextD findNext = lib.lookupFunction<_FindNextN, _FindNextD>('viFindNext');
  late final _GpibCtrlRenD gpibControlRen = lib.lookupFunction<_GpibCtrlRenN, _GpibCtrlRenD>('viGpibControlREN');

  VisaLib(this.lib);

  static VisaLib? _instance;
  static int _rm = 0;

  static List<String> get candidates {
    final env = Platform.environment['TWM_VISA_LIBRARY'];
    return [
      ?env,
      if (Platform.isWindows) ...['visa64.dll', 'visa32.dll'],
      if (Platform.isLinux) ...['libvisa.so', 'libvisa.so.0', 'librsvisa.so', 'libiovisa.so'],
      if (Platform.isMacOS) ...[
        '/Library/Frameworks/VISA.framework/VISA',
        '/Library/Frameworks/RsVisa.framework/RsVisa',
      ],
    ];
  }

  static VisaLib get instance {
    final i = _instance;
    if (i != null) return i;
    final errs = <String>[];
    for (final c in candidates) {
      try {
        _instance = VisaLib(DynamicLibrary.open(c));
        return _instance!;
      } catch (e) {
        errs.add(c);
      }
    }
    throw InstrumentException(
      'VISA library not found (tried ${errs.join(', ')}). Install NI-VISA or set '
      'TWM_VISA_LIBRARY to the library path.',
    );
  }

  /// Default resource manager session.
  static int get rm {
    if (_rm != 0) return _rm;
    final p = calloc<Uint32>();
    try {
      final st = instance.openDefaultRM(p);
      if (st < 0) throw InstrumentException('viOpenDefaultRM failed (${instance.describe(0, st)})');
      _rm = p.value;
      return _rm;
    } finally {
      calloc.free(p);
    }
  }

  String describe(int vi, int status) {
    final buf = calloc<Uint8>(512).cast<Utf8>();
    try {
      statusDesc(vi == 0 ? _rm : vi, status, buf);
      return '${buf.toDartString()} (0x${(status & 0xFFFFFFFF).toRadixString(16)})';
    } catch (_) {
      return 'status 0x${(status & 0xFFFFFFFF).toRadixString(16)}';
    } finally {
      calloc.free(buf);
    }
  }

  /// Lists instrument resources (e.g. `?*INSTR`).
  static List<String> find([String expr = '?*INSTR']) {
    final l = instance;
    final list = calloc<Uint32>();
    final cnt = calloc<Uint32>();
    final desc = calloc<Uint8>(256).cast<Utf8>();
    final e = expr.toNativeUtf8();
    try {
      final st = l.findRsrc(rm, e, list, cnt, desc);
      if (st < 0) return [];
      final out = [desc.toDartString()];
      for (var i = 1; i < cnt.value; i++) {
        if (l.findNext(list.value, desc) < 0) break;
        out.add(desc.toDartString());
      }
      l.close(list.value);
      return out;
    } finally {
      calloc.free(list);
      calloc.free(cnt);
      calloc.free(desc);
      calloc.free(e);
    }
  }
}

/// VISA instrument session. Calls are synchronous FFI calls bounded by the
/// VISA timeout; they are wrapped in futures to keep the driver API uniform.
class VisaIo extends InstrumentIo {
  @override
  final String resource;
  final int vi;
  final VisaLib _l;
  bool _closed = false;

  VisaIo._(this.resource, this.vi, this._l);

  static Future<VisaIo> open(String resource) async {
    final l = VisaLib.instance;
    final p = calloc<Uint32>();
    final r = resource.toNativeUtf8();
    try {
      final st = l.open(VisaLib.rm, r, 0, 5000, p);
      if (st < 0) throw InstrumentException('Cannot open "$resource": ${l.describe(0, st)}');
      final io = VisaIo._(resource, p.value, l);
      l.setAttribute(io.vi, Visa.attrTermChar, 10);
      l.setAttribute(io.vi, Visa.attrTermCharEn, 1);
      l.setAttribute(io.vi, Visa.attrSendEndEn, 1);
      return io;
    } finally {
      calloc.free(p);
      calloc.free(r);
    }
  }

  void _check(int st, String what) {
    if (st < 0) throw InstrumentException('$resource: $what failed: ${_l.describe(vi, st)}');
  }

  void _applyTimeout() => _l.setAttribute(vi, Visa.attrTmoValue, (timeout * 1000).round().clamp(1, 0x7FFFFFFF));

  @override
  Future<void> writeBytes(Uint8List data) async {
    _applyTimeout();
    final buf = calloc<Uint8>(data.length);
    final ret = calloc<Uint32>();
    try {
      buf.asTypedList(data.length).setAll(0, data);
      _check(_l.write(vi, buf, data.length, ret), 'write');
    } finally {
      calloc.free(buf);
      calloc.free(ret);
    }
  }

  @override
  Future<Uint8List> readBytes(int max, {bool term = true}) async {
    _applyTimeout();
    _l.setAttribute(vi, Visa.attrTermCharEn, term ? 1 : 0);
    final buf = calloc<Uint8>(max);
    final ret = calloc<Uint32>();
    try {
      final st = _l.read(vi, buf, max, ret);
      if (st == Visa.errorTmo) {
        if (ret.value == 0) throw InstrumentException('$resource: read timeout');
      } else {
        _check(st, 'read');
      }
      return Uint8List.fromList(buf.asTypedList(ret.value));
    } finally {
      calloc.free(buf);
      calloc.free(ret);
    }
  }

  @override
  Future<void> clear() async => _check(_l.clear(vi), 'device clear');

  @override
  Future<void> setControlLines({bool? dtr, bool? rts}) async {
    if (dtr != null) _check(_l.setAttribute(vi, Visa.attrAsrlDtrState, dtr ? 1 : 0), 'set DTR');
    if (rts != null) _check(_l.setAttribute(vi, Visa.attrAsrlRtsState, rts ? 1 : 0), 'set RTS');
  }

  @override
  Future<void> local() async {
    if (resource.toUpperCase().startsWith('GPIB')) {
      _l.gpibControlRen(vi, Visa.gpibRenGtl);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _l.close(vi);
  }
}
