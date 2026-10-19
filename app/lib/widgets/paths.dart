/// Path helpers independent of dart:io (paths belong to the backend file
/// system which may be Windows or POSIX). INFO files store relative paths
/// with DOS separators.
library;

String _sepOf(String p) => p.contains('\\') && !p.contains('/') ? '\\' : '/';

String dirName(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i <= 0 ? path : path.substring(0, i);
}

String baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? path : path.substring(i + 1);
}

bool isAbsolutePath(String p) => p.startsWith('/') || p.startsWith('\\\\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);

/// Resolves [rel] (may use DOS separators) against folder [dir].
String joinPath(String dir, String rel) {
  if (rel.isEmpty) return dir;
  if (isAbsolutePath(rel)) return rel;
  final sep = _sepOf(dir);
  final parts = <String>[...dir.split(RegExp(r'[\\/]'))];
  for (final r in rel.split(RegExp(r'[\\/]'))) {
    if (r == '..') {
      if (parts.length > 1) parts.removeLast();
    } else if (r.isNotEmpty && r != '.') {
      parts.add(r);
    }
  }
  final j = parts.join(sep);
  return dir.startsWith('/') && !j.startsWith('/') ? '/$j' : j;
}

/// Relative path of [path] to folder [from] with DOS separators (as TWM
/// writes them); returns [path] unchanged when not inside [from].
String relativeTo(String path, String from) {
  final a = path.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).toList();
  final b = from.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).toList();
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  if (i == 0) return path;
  return [for (var k = i; k < b.length; k++) '..', ...a.sublist(i)].join('\\');
}
