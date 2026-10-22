import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:twm_engine/twm_engine.dart';

/// [FileStore] on the real file system (desktop, server).
class IoFileStore extends FileStore {
  @override
  final p.Context path = p.context;

  @override
  Future<bool> exists(String s) async => FileSystemEntity.typeSync(s) != FileSystemEntityType.notFound;

  @override
  Future<bool> isDirectory(String s) => FileSystemEntity.isDirectory(s);

  @override
  Future<Uint8List> readBytes(String s) async {
    try {
      return await File(s).readAsBytes();
    } on FileSystemException catch (e) {
      throw StoreException(e.osError?.message ?? e.message, s);
    }
  }

  @override
  Future<void> writeBytes(String s, Uint8List data) async {
    await File(s).parent.create(recursive: true);
    // whole file or the old one: GNU Octave and the viewers read the session
    // header while the measurement rewrites it
    final tmp = File('$s.$pid.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(s);
  }

  @override
  Future<String> readText(String s) async {
    final b = await readBytes(s);
    try {
      return const SystemEncoding().decoder.convert(b);
    } catch (_) {
      return super.readText(s);
    }
  }

  @override
  Future<void> appendText(String s, String text) async {
    await File(s).parent.create(recursive: true);
    await File(s).writeAsString(text, mode: FileMode.append);
  }

  @override
  Future<StoreSink> openSink(String s) async {
    await File(s).parent.create(recursive: true);
    return _IoSink(await File(s).open(mode: FileMode.write));
  }

  @override
  Future<void> mkdirs(String s) => Directory(s).create(recursive: true);

  @override
  Future<List<StoreEntry>> list(String dir, {bool recursive = false}) async {
    final out = <StoreEntry>[];
    await for (final e in Directory(dir).list(recursive: recursive, followLinks: false)) {
      final st = await e.stat();
      out.add(StoreEntry(e.path, e is Directory, size: st.size, modified: st.modified));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<void> delete(String s, {bool recursive = false}) async {
    final t = FileSystemEntity.typeSync(s);
    if (t == FileSystemEntityType.directory) {
      await Directory(s).delete(recursive: recursive);
    } else if (t != FileSystemEntityType.notFound) {
      await File(s).delete();
    }
  }
}

class _IoSink implements StoreSink {
  final RandomAccessFile f;
  _IoSink(this.f);

  @override
  Future<void> add(Uint8List data) async => f.writeFrom(data);

  @override
  Future<void> writeAt(int offset, Uint8List data) async {
    final pos = await f.position();
    await f.setPosition(offset);
    await f.writeFrom(data);
    await f.setPosition(pos);
  }

  @override
  Future<void> close() => f.close();
}
