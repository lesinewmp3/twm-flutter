import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:twm_engine/twm_engine.dart';
import 'package:web/web.dart' as web;

/// In-memory file store persisted to the browser IndexedDB, so measurement
/// sessions survive page reloads. Writes are flushed in background.
class IdbFileStore extends MemoryFileStore {
  static const _dbName = 'twm_flutter';
  static const _osName = 'files';

  final web.IDBDatabase _db;
  final Set<String> _dirty = {};
  final Set<String> _persisted = {};
  Timer? _flush;

  IdbFileStore._(this._db) {
    onChanged = _changed;
  }

  static Future<IdbFileStore> open() async {
    final db = await _openDb();
    final s = IdbFileStore._(db);
    await s._loadAll();
    return s;
  }

  static Future<web.IDBDatabase> _openDb() {
    final c = Completer<web.IDBDatabase>();
    final req = web.window.indexedDB.open(_dbName, 1);
    req.onupgradeneeded = ((web.Event _) {
      final db = req.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_osName)) db.createObjectStore(_osName);
    }).toJS;
    req.onsuccess = ((web.Event _) => c.complete(req.result as web.IDBDatabase)).toJS;
    req.onerror = ((web.Event _) => c.completeError(StateError('IndexedDB is not available'))).toJS;
    return c.future;
  }

  static Future<JSAny?> _req(web.IDBRequest r) {
    final c = Completer<JSAny?>();
    r.onsuccess = ((web.Event _) => c.complete(r.result)).toJS;
    r.onerror = ((web.Event _) => c.completeError(StateError('IndexedDB request failed'))).toJS;
    return c.future;
  }

  Future<void> _loadAll() async {
    final os = _db.transaction(_osName.toJS, 'readonly').objectStore(_osName);
    final keys = (await _req(os.getAllKeys()) as JSArray<JSString>).toDart;
    final os2 = _db.transaction(_osName.toJS, 'readonly').objectStore(_osName);
    final vals = (await _req(os2.getAll()) as JSArray<JSUint8Array>).toDart;
    for (var i = 0; i < keys.length && i < vals.length; i++) {
      final path = keys[i].toDart;
      files[path] = vals[i].toDart;
      times[path] = DateTime.now();
      var d = path.substring(0, path.lastIndexOf('/'));
      while (d.isNotEmpty && dirs.add(d)) {
        d = d.substring(0, d.lastIndexOf('/'));
      }
      _persisted.add(path);
    }
  }

  void _changed(String path) {
    _dirty.add(path);
    _flush ??= Timer(const Duration(milliseconds: 400), _doFlush);
  }

  Future<void> _doFlush() async {
    _flush = null;
    final todo = _dirty.toList();
    _dirty.clear();
    final os = _db.transaction(_osName.toJS, 'readwrite').objectStore(_osName);
    for (final p in todo) {
      final f = files[p];
      if (f != null) {
        os.put(f.toJS, p.toJS);
        _persisted.add(p);
      } else {
        // deleted file or folder: remove all persisted keys below it
        for (final k in _persisted.where((k) => k == p || k.startsWith('$p/')).toList()) {
          os.delete(k.toJS);
          _persisted.remove(k);
        }
      }
    }
  }

  /// Bytes used by the stored files.
  int get usedBytes => files.values.fold(0, (s, f) => s + f.length);

  /// Removes everything (reset of the browser storage).
  Future<void> clearAll() async {
    files.clear();
    times.clear();
    dirs
      ..clear()
      ..add('/');
    _persisted.clear();
    await _req(_db.transaction(_osName.toJS, 'readwrite').objectStore(_osName).clear());
  }

  /// Copies the bundled example corrections when missing.
  Future<void> seed(Map<String, Uint8List> data) async {
    for (final e in data.entries) {
      if (!files.containsKey(e.key)) await writeBytes(e.key, e.value);
    }
  }
}
