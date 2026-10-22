import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:twm_engine/twm_engine.dart';

/// `struct niScope_wfmInfo` (niScope.h).
final class WfmInfo extends Struct {
  @Double()
  external double absoluteInitialX;
  @Double()
  external double relativeInitialX;
  @Double()
  external double xIncrement;
  @Int32()
  external int actualSamples;
  @Double()
  external double offset;
  @Double()
  external double gain;
  @Double()
  external double reserved1;
  @Double()
  external double reserved2;
}

typedef _InitN = Int32 Function(Pointer<Utf8>, Uint16, Uint16, Pointer<Uint32>);
typedef _InitD = int Function(Pointer<Utf8>, int, int, Pointer<Uint32>);
typedef _ViN = Int32 Function(Uint32);
typedef _ViD = int Function(int);
typedef _VertN = Int32 Function(Uint32, Pointer<Utf8>, Double, Double, Int32, Double, Uint16);
typedef _VertD = int Function(int, Pointer<Utf8>, double, double, int, double, int);
typedef _ChanCharN = Int32 Function(Uint32, Pointer<Utf8>, Double, Double);
typedef _ChanCharD = int Function(int, Pointer<Utf8>, double, double);
typedef _HorizN = Int32 Function(Uint32, Double, Int32, Double, Int32, Uint16);
typedef _HorizD = int Function(int, double, int, double, int, int);
typedef _TrigEdgeN = Int32 Function(Uint32, Pointer<Utf8>, Double, Int32, Int32, Double, Double);
typedef _TrigEdgeD = int Function(int, Pointer<Utf8>, double, int, int, double, double);
typedef _TrigHystN = Int32 Function(Uint32, Pointer<Utf8>, Double, Double, Int32, Int32, Double, Double);
typedef _TrigHystD = int Function(int, Pointer<Utf8>, double, double, int, int, double, double);
typedef _TrigDigN = Int32 Function(Uint32, Pointer<Utf8>, Int32, Double, Double);
typedef _TrigDigD = int Function(int, Pointer<Utf8>, int, double, double);
typedef _TrigWinN = Int32 Function(Uint32, Pointer<Utf8>, Double, Double, Int32, Int32, Double, Double);
typedef _TrigWinD = int Function(int, Pointer<Utf8>, double, double, int, int, double, double);
typedef _TrigSwN = Int32 Function(Uint32, Double, Double);
typedef _TrigSwD = int Function(int, double, double);
typedef _AcqN = Int32 Function(Uint32, Int32);
typedef _AcqD = int Function(int, int);
typedef _FetchN = Int32 Function(Uint32, Pointer<Utf8>, Double, Int32, Pointer<Int32>, Pointer<WfmInfo>);
typedef _FetchD = int Function(int, Pointer<Utf8>, double, int, Pointer<Int32>, Pointer<WfmInfo>);
typedef _Fetch16N = Int32 Function(Uint32, Pointer<Utf8>, Double, Int32, Pointer<Int16>, Pointer<WfmInfo>);
typedef _Fetch16D = int Function(int, Pointer<Utf8>, double, int, Pointer<Int16>, Pointer<WfmInfo>);
typedef _SetRealN = Int32 Function(Uint32, Pointer<Utf8>, Uint32, Double);
typedef _SetRealD = int Function(int, Pointer<Utf8>, int, double);
typedef _SetIntN = Int32 Function(Uint32, Pointer<Utf8>, Uint32, Int32);
typedef _SetIntD = int Function(int, Pointer<Utf8>, int, int);
typedef _SetStrN = Int32 Function(Uint32, Pointer<Utf8>, Uint32, Pointer<Utf8>);
typedef _SetStrD = int Function(int, Pointer<Utf8>, int, Pointer<Utf8>);
typedef _GetRealN = Int32 Function(Uint32, Pointer<Utf8>, Uint32, Pointer<Double>);
typedef _GetRealD = int Function(int, Pointer<Utf8>, int, Pointer<Double>);
typedef _GetErrN = Int32 Function(Uint32, Pointer<Int32>, Int32, Pointer<Utf8>);
typedef _GetErrD = int Function(int, Pointer<Int32>, int, Pointer<Utf8>);
typedef _CalN = Int32 Function(Uint32, Pointer<Utf8>, Int32);
typedef _CalD = int Function(int, Pointer<Utf8>, int);
typedef _ExportN = Int32 Function(Uint32, Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _ExportD = int Function(int, int, Pointer<Utf8>, Pointer<Utf8>);
typedef _AcqStatN = Int32 Function(Uint32, Pointer<Int32>);
typedef _AcqStatD = int Function(int, Pointer<Int32>);
typedef _SrN = Int32 Function(Uint32, Pointer<Double>);
typedef _SrD = int Function(int, Pointer<Double>);
typedef _TclkN = Int32 Function(Uint32, Pointer<Uint32>);
typedef _TclkD = int Function(int, Pointer<Uint32>);
typedef _TclkSyncN = Int32 Function(Uint32, Pointer<Uint32>, Double);
typedef _TclkSyncD = int Function(int, Pointer<Uint32>, double);
typedef _TclkErrN = Int32 Function(Pointer<Utf8>, Uint32);
typedef _TclkErrD = int Function(Pointer<Utf8>, int);

/// niScope / niTClk constants (niScope.h).
class NiScope {
  static const valDc = 1, valAc = 0, valGnd = 2;
  static const valPositive = 1, valNegative = 0;
  static const valNormal = 0, valFlexres = 1001;
  static const valAcqComplete = 1;
  static const valEntering = 0, valLeaving = 1;
  // attribute IDs: IVI_SPECIFIC_PUBLIC_ATTR_BASE (1150000) + n
  static const attrRefClkRate = 1150090;
  static const attrInputClockSource = 1150002;
  static const attrFetchRelativeTo = 1150077;
  static const attrFetchOffset = 1150078;
  static const valReadPointer = 388;
  static const valRefClock = 100; // NISCOPE_VAL_REF_CLOCK signal for niScope_ExportSignal
  static const calOptionStandard = 0;
}

/// FFI binding of NI-SCOPE and NI-TClk drivers.
class NiScopeLib {
  final DynamicLibrary scope;
  final DynamicLibrary? tclk;

  NiScopeLib(this.scope, this.tclk);

  late final init = scope.lookupFunction<_InitN, _InitD>('niScope_init');
  late final close = scope.lookupFunction<_ViN, _ViD>('niScope_close');
  late final reset = scope.lookupFunction<_ViN, _ViD>('niScope_reset');
  late final abort = scope.lookupFunction<_ViN, _ViD>('niScope_Abort');
  late final initiate = scope.lookupFunction<_ViN, _ViD>('niScope_InitiateAcquisition');
  late final commit = scope.lookupFunction<_ViN, _ViD>('niScope_Commit');
  late final disable = scope.lookupFunction<_ViN, _ViD>('niScope_Disable');
  late final configureVertical = scope.lookupFunction<_VertN, _VertD>('niScope_ConfigureVertical');
  late final configureChanCharacteristics = scope.lookupFunction<_ChanCharN, _ChanCharD>(
    'niScope_ConfigureChanCharacteristics',
  );
  late final configureHorizontalTiming = scope.lookupFunction<_HorizN, _HorizD>('niScope_ConfigureHorizontalTiming');
  late final configureTriggerImmediate = scope.lookupFunction<_ViN, _ViD>('niScope_ConfigureTriggerImmediate');
  late final configureTriggerEdge = scope.lookupFunction<_TrigEdgeN, _TrigEdgeD>('niScope_ConfigureTriggerEdge');
  late final configureTriggerHysteresis = scope.lookupFunction<_TrigHystN, _TrigHystD>(
    'niScope_ConfigureTriggerHysteresis',
  );
  late final configureTriggerDigital = scope.lookupFunction<_TrigDigN, _TrigDigD>('niScope_ConfigureTriggerDigital');
  late final configureTriggerWindow = scope.lookupFunction<_TrigWinN, _TrigWinD>('niScope_ConfigureTriggerWindow');
  late final configureTriggerSoftware = scope.lookupFunction<_TrigSwN, _TrigSwD>('niScope_ConfigureTriggerSoftware');
  late final configureAcquisition = scope.lookupFunction<_AcqN, _AcqD>('niScope_ConfigureAcquisition');
  late final fetchBinary32 = scope.lookupFunction<_FetchN, _FetchD>('niScope_FetchBinary32');
  late final fetchBinary16 = scope.lookupFunction<_Fetch16N, _Fetch16D>('niScope_FetchBinary16');
  late final setReal = scope.lookupFunction<_SetRealN, _SetRealD>('niScope_SetAttributeViReal64');
  late final setInt = scope.lookupFunction<_SetIntN, _SetIntD>('niScope_SetAttributeViInt32');
  late final setString = scope.lookupFunction<_SetStrN, _SetStrD>('niScope_SetAttributeViString');
  late final getReal = scope.lookupFunction<_GetRealN, _GetRealD>('niScope_GetAttributeViReal64');
  late final getError = scope.lookupFunction<_GetErrN, _GetErrD>('niScope_GetError');
  late final calSelf = scope.lookupFunction<_CalN, _CalD>('niScope_CalSelfCalibrate');
  late final exportSignal = scope.lookupFunction<_ExportN, _ExportD>('niScope_ExportSignal');
  late final acquisitionStatus = scope.lookupFunction<_AcqStatN, _AcqStatD>('niScope_AcquisitionStatus');
  late final sampleRate = scope.lookupFunction<_SrN, _SrD>('niScope_SampleRate');

  _TclkD _tc(String n) {
    final t = tclk;
    if (t == null) throw DigitizerException('NI-TClk library not found (needed for multiple cards).');
    return t.lookupFunction<_TclkN, _TclkD>(n);
  }

  late final tclkConfigureForHomogeneousTriggers = _tc('niTClk_ConfigureForHomogeneousTriggers');
  late final tclkInitiate = _tc('niTClk_Initiate');
  late final tclkSynchronize = tclk == null
      ? (int a, Pointer<Uint32> b, double c) => throw DigitizerException('NI-TClk library not found.')
      : tclk!.lookupFunction<_TclkSyncN, _TclkSyncD>('niTClk_Synchronize');
  late final _tclkError = tclk?.lookupFunction<_TclkErrN, _TclkErrD>('niTClk_GetExtendedErrorInfo');

  static NiScopeLib? _i;

  /// Uses the libraries at [scope] and [tclk] instead of the installed ones
  /// (other install location, tests).
  static NiScopeLib load(String scope, [String? tclk]) =>
      _i = NiScopeLib(DynamicLibrary.open(scope), tclk == null ? null : DynamicLibrary.open(tclk));

  static NiScopeLib get instance {
    if (_i != null) return _i!;
    final s = _open(
      Platform.isWindows
          ? ['niScope_64.dll', 'niScope_32.dll']
          : ['libniscope.so', 'libniScope.so', '/usr/local/natinst/niscope/lib64/libniscope.so'],
    );
    if (s == null) {
      throw DigitizerException('niScope driver library not found - install NI-SCOPE driver.');
    }
    final t = _open(Platform.isWindows ? ['niTClk_64.dll', 'niTClk.dll'] : ['libnitclk.so', 'libniTClk.so']);
    return _i = NiScopeLib(s, t);
  }

  static DynamicLibrary? _open(List<String> names) {
    for (final n in names) {
      try {
        return DynamicLibrary.open(n);
      } catch (_) {}
    }
    return null;
  }

  /// Throws on negative status of a NI-TClk call with its error description.
  void checkTclk(int status, String what) {
    if (status >= 0) return;
    final buf = calloc<Uint8>(1024).cast<Utf8>();
    try {
      final f = _tclkError;
      throw DigitizerException('$what: ${f != null && f(buf, 1024) >= 0 ? buf.toDartString() : ''} ($status)');
    } finally {
      calloc.free(buf);
    }
  }

  /// Throws on negative status with driver error description.
  void check(int vi, int status, String what) {
    if (status >= 0) return;
    final code = calloc<Int32>();
    final buf = calloc<Uint8>(1024).cast<Utf8>();
    try {
      getError(vi, code, 1024, buf);
      throw DigitizerException('niScope $what: ${buf.toDartString()} ($status)');
    } finally {
      calloc.free(code);
      calloc.free(buf);
    }
  }
}
