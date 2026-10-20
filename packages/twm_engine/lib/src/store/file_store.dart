import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class StoreEntry {
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;
  const StoreEntry(this.path, this.isDir, {this.size = 0, this.modified});
}

class StoreException implements Exception {
  final String message;
  final String path;
  StoreException(this.message, this.path);
  @override
  String toString() => '$message: $path';
}

/// Streaming writer of a stored file (raw records are written while
/// digitizing, the MAT header is patched when the record is finished).
abstract class StoreSink {
  Future<void> add(Uint8List data);
  Future<void> writeAt(int offset, Uint8List data);
  Future<void> close();
}

/// File system abstraction of the measurement engine: real disk on desktop
/// and server (`IoFileStore` in twm_core), memory/IndexedDB in the browser.
abstract class FileStore {
  /// Path manipulation rules of this store.
  p.Context get path;

  Future<bool> exists(String path);
  Future<bool> isDirectory(String path);
  Future<Uint8List> readBytes(String path);
  Future<void> writeBytes(String path, Uint8List data);
  Future<StoreSink> openSink(String path);
  Future<void> mkdirs(String path);
  Future<List<StoreEntry>> list(String dir, {bool recursive = false});
  Future<void> delete(String path, {bool recursive = false});

  /// Text files of TWM are ASCII/Latin-1 (some corrections contain Latin-1
  /// characters), UTF-8 is tried first.
  Future<String> readText(String path) async {
    final b = await readBytes(path);
    try {
      return utf8.decode(b);
    } on FormatException {
      return latin1.decode(b);
    }
  }

  Future<void> writeText(String path, String text) => writeBytes(path, Uint8List.fromList(utf8.encode(text)));

  Future<void> appendText(String path, String text) async {
    final old = await exists(path) ? await readBytes(path) : Uint8List(0);
    await writeBytes(path, Uint8List.fromList([...old, ...utf8.encode(text)]));
  }

  /// Recursive copy of folder [src] to [dst].
  Future<void> copyTree(String src, String dst) async {
    await mkdirs(dst);
    for (final e in await list(src)) {
      final target = path.join(dst, path.basename(e.path));
      if (e.isDir) {
        await copyTree(e.path, target);
      } else {
        await writeBytes(target, await readBytes(e.path));
      }
    }
  }
}

/// In-memory file store (browser, tests). Paths are POSIX style.
class MemoryFileStore extends FileStore {
  final Map<String, Uint8List> files = {};
  final Map<String, DateTime> times = {};
  final Set<String> dirs = {'/'};

  @override
  final p.Context path = p.posix;

  /// Called after every modification (persistence hook).
  void Function(String path)? onChanged;

  String _n(String s) => path.normalize(path.isAbsolute(s) ? s : path.join('/', s));

  void _addDirs(String dir) {
    var d = dir;
    while (dirs.add(d) && d != '/') {
      d = path.dirname(d);
    }
  }

  @override
  Future<bool> exists(String s) async => files.containsKey(_n(s)) || dirs.contains(_n(s));

  @override
  Future<bool> isDirectory(String s) async => dirs.contains(_n(s));

  @override
  Future<Uint8List> readBytes(String s) async {
    final f = files[_n(s)];
    if (f == null) throw StoreException('File not found', s);
    return f;
  }

  @override
  Future<void> writeBytes(String s, Uint8List data) async {
    final n = _n(s);
    _addDirs(path.dirname(n));
    files[n] = Uint8List.fromList(data);
    times[n] = DateTime.now();
    onChanged?.call(n);
  }

  @override
  Future<StoreSink> openSink(String s) async {
    final n = _n(s);
    _addDirs(path.dirname(n));
    files[n] = Uint8List(0);
    return _MemSink(this, n);
  }

  @override
  Future<void> mkdirs(String s) async => _addDirs(_n(s));

  @override
  Future<List<StoreEntry>> list(String dir, {bool recursive = false}) async {
    final d = _n(dir);
    if (!dirs.contains(d)) throw StoreException('Folder not found', dir);
    final out = <StoreEntry>[];
    bool inside(String x) => recursive ? path.isWithin(d, x) : path.dirname(x) == d && x != d;
    for (final x in dirs) {
      if (inside(x)) out.add(StoreEntry(x, true));
    }
    for (final e in files.entries) {
      if (inside(e.key)) out.add(StoreEntry(e.key, false, size: e.value.length, modified: times[e.key]));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<void> delete(String s, {bool recursive = false}) async {
    final n = _n(s);
    if (files.remove(n) != null) {
      times.remove(n);
      onChanged?.call(n);
      return;
    }
    if (!dirs.contains(n)) return;
    final children = [...files.keys.where((k) => path.isWithin(n, k)), ...dirs.where((k) => path.isWithin(n, k))];
    if (children.isNotEmpty && !recursive) throw StoreException('Folder not empty', s);
    for (final c in children) {
      files.remove(c);
      times.remove(c);
      dirs.remove(c);
    }
    if (n != '/') dirs.remove(n);
    onChanged?.call(n);
  }
}

class _MemSink implements StoreSink {
  final MemoryFileStore store;
  final String path;
  final BytesBuilder _b = BytesBuilder(copy: false);
  final Map<int, Uint8List> _patches = {};
  _MemSink(this.store, this.path);

  @override
  Future<void> add(Uint8List data) async => _b.add(Uint8List.fromList(data));

  @override
  Future<void> writeAt(int offset, Uint8List data) async => _patches[offset] = Uint8List.fromList(data);

  @override
  Future<void> close() async {
    final out = _b.takeBytes();
    for (final e in _patches.entries) {
      out.setRange(e.key, e.key + e.value.length, e.value);
    }
    store.files[path] = out;
    store.times[path] = DateTime.now();
    store.onChanged?.call(path);
  }
}
