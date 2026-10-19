/// Small helpers for hand written (codegen free) JSON serialization.
library;

typedef Json = Map<String, dynamic>;

T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is String) {
    for (final v in values) {
      if (v.name == name) return v;
    }
  }
  return fallback;
}

/// JSON cannot carry NaN/Inf; encode them as strings.
Object? jNum(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Inf' : '-Inf';
  return v;
}

double jDouble(Object? v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) {
    switch (v) {
      case 'NaN':
        return double.nan;
      case 'Inf':
        return double.infinity;
      case '-Inf':
        return double.negativeInfinity;
    }
    return double.tryParse(v) ?? fallback;
  }
  return fallback;
}

double? jDoubleOrNull(Object? v) => v == null ? null : jDouble(v, double.nan);

int jInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool jBool(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return fallback;
}

String jString(Object? v, [String fallback = '']) => v is String ? v : fallback;

List<String> jStringList(Object? v) => v is List ? [for (final e in v) e.toString()] : <String>[];

List<double> jDoubleList(Object? v) => v is List ? [for (final e in v) jDouble(e)] : <double>[];

List<int> jIntList(Object? v) => v is List ? [for (final e in v) jInt(e)] : <int>[];

Json jMap(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

List<Json> jMapList(Object? v) => v is List ? [for (final e in v) jMap(e)] : <Json>[];
