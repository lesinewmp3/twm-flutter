import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import '../store/file_store.dart';
import 'record_file.dart';

/// Reader of a TWM measurement session folder (counterpart of
/// `tpq_load_record.m` used by the record viewer).
class SessionReader {
  final FileStore store;
  final String root;
  final Info header;

  SessionReader._(this.store, this.root, this.header);

  static Future<SessionReader> open(FileStore store, String pathOrRoot) async {
    final p = store.path;
    var file = pathOrRoot;
    if (await store.isDirectory(pathOrRoot)) {
      file = p.join(pathOrRoot, 'session.info');
    }
    final txt = await store.readText(file);
    return SessionReader._(store, p.dirname(file), Info.parse(txt));
  }

  int get groupsCount => header.number('groups count').round();
  int get channelsCount => header.number('channels count').round();
  List<String> get channelDescriptors => header.textList('channel descriptors');
  String get dataVariable => header.textOrNull('sample data variable name') ?? 'y';

  Info group(int g) => header.section('measurement group $g');

  int repetitions(int g) => group(g).number('repetitions count').round();

  /// Reads record [rep] of group [g]; returns scaled channels, optionally
  /// decimated (min/max envelope preserving) to [maxPoints] per channel.
  ///
  /// [from], [count]: a part of the record (zoomed view), 0 = to the end.
  Future<RecordData> readRecord(int g, int rep, {int maxPoints = 0, int from = 0, int count = 0}) async {
    final gi = group(g);
    final files = gi.textList('record sample data files');
    final rel = files[rep - 1].replaceAll('\\', '/');
    final gains = gi.matrix('record sample data gains [V]')[rep - 1];
    final offs = gi.matrix('record sample data offsets [V]')[rep - 1];
    final ts = gi.vector('record time increments [s]')[rep - 1];
    final tstamps = gi.matrix('record relative timestamps [s]')[rep - 1];
    final v = await RecordFileReader.read(store, store.path.join(root, rel), varName: dataVariable);
    final ch = <Float64List>[];
    final a = from.clamp(0, v.cols);
    final b = count <= 0 ? v.cols : math.min(v.cols, a + count);
    final len = b - a;
    // display decimation: min/max envelope (two points per bucket), so fast
    // content is shown as a band instead of being aliased into slow waves
    var bucket = 1;
    if (maxPoints > 0 && len > maxPoints) bucket = (len / math.max(1, maxPoints ~/ 2)).ceil();
    for (var c = 0; c < v.rows; c++) {
      final row = v.row(c, gain: gains[c], offset: offs[c]);
      final part = a == 0 && b == v.cols ? row : Float64List.sublistView(row, a, b);
      ch.add(bucket == 1 ? Float64List.fromList(part) : envelope(part, bucket));
    }
    return RecordData(
      channels: ch,
      ts: bucket == 1 ? ts : ts * bucket / 2,
      fullLength: v.cols,
      timestamps: tstamps,
      names: channelDescriptors,
      from: a,
      fullTs: ts,
    );
  }

  /// Min and max of each [bucket] samples, in their time order.
  static Float64List envelope(Float64List x, int bucket) {
    final nb = (x.length / bucket).ceil();
    final out = Float64List(2 * nb);
    for (var b = 0; b < nb; b++) {
      final a = b * bucket, e = math.min(x.length, a + bucket);
      var mn = a, mx = a;
      for (var i = a + 1; i < e; i++) {
        if (x[i] < x[mn]) mn = i;
        if (x[i] > x[mx]) mx = i;
      }
      out[2 * b] = x[mn <= mx ? mn : mx];
      out[2 * b + 1] = x[mn <= mx ? mx : mn];
    }
    return out;
  }
}

class RecordData {
  final List<Float64List> channels;
  final double ts;
  final int fullLength;
  final List<double> timestamps;
  final List<String> names;

  /// First sample of [channels] in the record, sample period of the record.
  final int from;
  final double fullTs;
  RecordData({
    required this.channels,
    required this.ts,
    required this.fullLength,
    required this.timestamps,
    required this.names,
    this.from = 0,
    this.fullTs = 0,
  });
}
