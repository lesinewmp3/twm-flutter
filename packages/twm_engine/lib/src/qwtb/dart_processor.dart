import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:twm_model/twm_model.dart';

import '../session/session_reader.dart';
import '../store/file_store.dart';
import 'dart_algorithms.dart';

/// Processing of TWM sessions by the Dart algorithms (browser version of
/// `qwtb_exec_algorithm.m`, `qwtb_get_results_info.m`, `qwtb_get_results.m`).
/// Results are stored as JSON in `<session>/RESULTS_WEB/<alg>.json`.
class DartProcessor {
  final FileStore store;
  DartProcessor(this.store);

  static const phaseQuantities = {'phi', 'ph', 'phi_ef', 'ph_rel0'};
  static const amplitudeQuantities = {'A', 'spec_A', 'spec_U', 'spec_I'};

  String _root(String session) => session.endsWith('session.info') ? store.path.dirname(session) : session;
  String _resFile(String root, String alg) => store.path.join(root, 'RESULTS_WEB', '$alg.json');
  String _index(String root) => store.path.join(root, 'results_web.json');

  // ------------------------------------------------------------ inputs ----

  Future<List<_Chan>> _channels(SessionReader r) async {
    final h = r.header;
    final cs = h.sectionOrNull('measurement setup configuration');
    final paths = cs?.textMatrixOrNull('transducer paths') == null ? <String>[] : cs!.textList('transducer paths');
    if (paths.isEmpty) {
      return [for (var c = 1; c <= r.channelsCount; c++) _Chan('u$c', c, 0, 1, false, c, false)];
    }
    final phases = cs!.vector('channel phase indexes');
    final map = cs.matrix('transducer to digitizer channels mapping');
    final inv = cs.matrixOrNull('transducer inverted') == null ? <double>[] : cs.vector('transducer inverted');
    final out = <_Chan>[];
    for (var k = 0; k < paths.length; k++) {
      final f = store.path.join(r.root, paths[k].replaceAll('\\', '/'));
      var type = 'divider';
      var ratio = 1.0;
      try {
        final ti = Info.parse(await store.readText(f));
        type = ti.textOrNull('type') ?? 'divider';
        ratio = ti.numberOrNull('nominal ratio') ?? 1.0;
      } catch (_) {}
      final shunt = type == 'shunt';
      final ph = k < phases.length ? phases[k].round() : k + 1;
      out.add(
        _Chan(
          '${shunt ? 'i' : 'u'}$ph',
          map[k][0].round(),
          map[k].length > 1 && map[k][1].isFinite ? map[k][1].round() : 0,
          shunt ? 1 / ratio : ratio,
          shunt,
          ph,
          k < inv.length && inv[k] != 0,
        ),
      );
    }
    return out;
  }

  // ---------------------------------------------------------- execution ---

  Future<void> process(String session, ProcessingSetup ps, {int group = 1, required int record}) async {
    final alg = DartAlgorithm.byId(ps.algorithmId);
    if (alg == null) {
      throw StateError(
        'Algorithm ${ps.algorithmId} is not available in the browser version '
        '(available: ${DartAlgorithm.all.map((a) => a.info.id).join(', ')}).',
      );
    }
    final r = await SessionReader.open(store, session);
    final rec = await r.readRecord(group, record);
    final gi = r.group(group);
    final apertures = gi.matrixOrNull('aperture [s]') == null ? <double>[] : gi.vector('aperture [s]');
    final aperture = record - 1 < apertures.length ? apertures[record - 1] : 0.0;
    final stamps = gi.matrix('record relative timestamps [s]');
    final fs = 1 / rec.ts;
    final chans = await _channels(r);
    final params = {for (final p in ps.parameters) p.name: p.values.join(';')};

    double ts(int ch) {
      if (ps.timeStampMode == TimeStampMode.disable) return 0;
      var t = stamps[record - 1][ch - 1];
      if (ps.timeStampMode == TimeStampMode.relative) t -= stamps[0][0];
      return t + ps.sampleOffset * rec.ts;
    }

    Float64List signal(_Chan c) {
      final hi = rec.channels[c.hi - 1];
      final lo = c.lo > 0 ? rec.channels[c.lo - 1] : null;
      final start = ps.sampleOffset.clamp(0, hi.length - 1);
      var end = hi.length;
      if (ps.sampleLimit > 0) end = math.min(end, start + ps.sampleLimit);
      final k = c.gain * (c.inverted ? -1 : 1);
      return Float64List.fromList([for (var i = start; i < end; i++) (hi[i] - (lo?[i] ?? 0)) * k]);
    }

    final results = <Map<String, Object?>>[];
    if (alg.isUi) {
      final phases = {for (final c in chans) c.phase}.toList()..sort();
      for (final ph in phases) {
        final u = chans.where((c) => c.phase == ph && !c.isCurrent);
        final i = chans.where((c) => c.phase == ph && c.isCurrent);
        if (u.isEmpty || i.isEmpty) continue;
        final out = alg.run(
          AlgInput(
            fs: fs,
            u: signal(u.first),
            i: signal(i.first),
            timestamp: ts(u.first.hi),
            aperture: aperture,
            params: params,
          ),
        );
        results.add(_chanJson('L$ph', out));
      }
      if (results.isEmpty) {
        throw StateError(
          '${alg.info.id} needs a voltage and a current transducer with the same phase index '
          '(HW corrections).',
        );
      }
    } else {
      for (final c in chans) {
        final out = alg.run(AlgInput(fs: fs, y: signal(c), timestamp: ts(c.hi), aperture: aperture, params: params));
        results.add(_chanJson(c.tag, out));
      }
    }
    final root = _root(session);
    final file = _resFile(root, alg.info.id);
    final data = await store.exists(file) ? jMap(jsonDecode(await store.readText(file))) : <String, dynamic>{};
    final recs = jMap(data['records']);
    recs['$group-$record'] = {'group': group, 'record': record, 'channels': results};
    data['records'] = recs;
    await store.writeText(file, jsonEncode(data));
    final idx = await store.exists(_index(root))
        ? jMap(jsonDecode(await store.readText(_index(root))))
        : <String, dynamic>{};
    final algs = jStringList(idx['algorithms']);
    if (!algs.contains(alg.info.id)) algs.add(alg.info.id);
    await store.writeText(_index(root), jsonEncode({'algorithms': algs, 'last': alg.info.id}));
  }

  Map<String, Object?> _chanJson(String tag, Map<String, DartQuantity> q) => {
    'tag': tag,
    'quantities': [
      for (final e in q.values) {'name': e.name, 'v': e.value, if (e.text.isNotEmpty) 'text': e.text},
    ],
  };

  // ------------------------------------------------------------ results ---

  Future<_Results?> _load(String session, String algorithm) async {
    final root = _root(session);
    if (!await store.exists(_index(root))) return null;
    final idx = jMap(jsonDecode(await store.readText(_index(root))));
    final alg = algorithm.isNotEmpty ? algorithm : jString(idx['last']);
    if (alg.isEmpty || !await store.exists(_resFile(root, alg))) return null;
    final data = jMap(jsonDecode(await store.readText(_resFile(root, alg))));
    final recs = jMap(data['records']).values.map(jMap).toList()
      ..sort(
        (a, b) =>
            (jInt(a['group']) * 100000 + jInt(a['record'])).compareTo(jInt(b['group']) * 100000 + jInt(b['record'])),
      );
    return _Results(alg, jStringList(idx['algorithms']), jString(idx['last']), recs);
  }

  Future<ResultsInfo> resultsInfo(String session, {String algorithm = ''}) async {
    final r = await _load(session, algorithm);
    if (r == null || r.records.isEmpty) return ResultsInfo.empty;
    final first = jMapList(r.records.first['channels']);
    return ResultsInfo(
      files: [for (final x in r.records) 'G${x['group']}-A${x['record']}'],
      exists: true,
      lastAlgorithm: r.last,
      algorithms: r.algorithms,
      channels: [for (final c in first) jString(c['tag'])],
      variables: [for (final q in jMapList(first.first['quantities'])) jString(q['name'])],
    );
  }

  /// Quantity values of result [rid] (-1 last, 0 average, >0 index).
  List<List<ResultQuantity>> _resolve(_Results r, int rid, ResultViewConfig cfg) {
    final alg = DartAlgorithm.byId(r.alg);
    String desc(String n) =>
        alg?.info.outputs.firstWhere((o) => o.name == n, orElse: () => (name: n, desc: '')).desc ?? '';
    List<List<ResultQuantity>> one(Map<String, dynamic> rec) => [
      for (final c in jMapList(rec['channels']))
        [
          for (final q in jMapList(c['quantities']))
            ResultQuantity(
              name: jString(q['name']),
              desc: desc(jString(q['name'])),
              tag: jString(c['tag']),
              value: jDoubleList(q['v']),
              text: jString(q['text']),
              isPhase: phaseQuantities.contains(q['name']),
              isGraph:
                  jString(q['name']).startsWith('spec_') && q['name'] != 'spec_f' ||
                  (r.alg == 'TWM-WFFT' && const ['A', 'ph', 'A_rel0', 'ph_rel0'].contains(q['name'])),
              graphX: jString(q['name']).startsWith('spec_') ? 'spec_f' : (r.alg == 'TWM-WFFT' ? 'f' : ''),
            ),
        ],
    ];
    if (rid > 0) return one(r.records[(rid - 1).clamp(0, r.records.length - 1)]);
    if (rid < 0) return one(r.records.last);
    // average of all records (element-wise); phases wrapped to the display
    // range first, as qwtb_average_results.m does
    final all = [for (final x in r.records) one(x)];
    final base = all.first;
    final half = cfg.phase == PhaseMode.pmPi || cfg.phase == PhaseMode.pm180;
    double wrap(double v) => half ? (v + math.pi) % (2 * math.pi) - math.pi : v % (2 * math.pi);
    double val(List<List<ResultQuantity>> x, int c, int q, int k) {
      if (k >= x[c][q].value.length) return double.nan;
      final v = x[c][q].value[k];
      return base[c][q].isPhase ? wrap(v) : v;
    }

    return [
      for (var c = 0; c < base.length; c++)
        [
          for (var q = 0; q < base[c].length; q++)
            ResultQuantity(
              name: base[c][q].name,
              desc: base[c][q].desc,
              tag: base[c][q].tag,
              text: base[c][q].text,
              isPhase: base[c][q].isPhase,
              isGraph: base[c][q].isGraph,
              graphX: base[c][q].graphX,
              value: [
                for (var k = 0; k < base[c][q].value.length; k++)
                  all.fold<double>(0, (s, x) => s + val(x, c, q, k)) / all.length,
              ],
              unc: [
                for (var k = 0; k < base[c][q].value.length; k++) _ua([for (final x in all) val(x, c, q, k)]),
              ],
            ),
        ],
    ];
  }

  static double _ua(List<double> v) {
    if (v.length < 2) return double.nan;
    final m = v.reduce((a, b) => a + b) / v.length;
    final s = v.fold<double>(0, (a, x) => a + (x - m) * (x - m));
    return math.sqrt(s / (v.length - 1)) / math.sqrt(v.length);
  }

  double _phase(double v, PhaseMode m) => switch (m) {
    PhaseMode.pmPi => v,
    PhaseMode.zeroTwoPi => v < 0 ? v + 2 * math.pi : v,
    PhaseMode.pm180 => v * 180 / math.pi,
    PhaseMode.zero360 => (v < 0 ? v + 2 * math.pi : v) * 180 / math.pi,
  };

  double _conv(ResultQuantity q, double v, ResultViewConfig cfg) {
    if (q.isPhase) return _phase(v, cfg.phase);
    if (amplitudeQuantities.contains(q.name)) return v * cfg.amplitude.factor;
    return v;
  }

  static String fmt(double v) {
    if (v.isNaN) return 'NaN';
    if (v == 0) return '0';
    final a = v.abs();
    if (a >= 1e6 || a < 1e-4) return v.toStringAsExponential(7);
    // trim trailing zeros of the fraction (Dart replaceFirst has no $1 backreferences)
    var t = v.toStringAsPrecision(9);
    if (t.contains('.')) t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return t;
  }

  Future<ResultsTable> results(String session, String algorithm, ResultViewConfig cfg) async {
    final r = await _load(session, algorithm);
    if (r == null || r.records.isEmpty) return ResultsTable.empty;
    final vars = cfg.variables;
    bool shown(ResultQuantity q) => vars.isEmpty || vars.contains(q.name);
    final rows = <List<String>>[];
    final descs = <String>[];
    final names = <String>[];
    final chIdx = <int>[];
    if (cfg.maxDim == ResultDim.scalar) {
      final per = [for (var k = 1; k <= r.records.length; k++) _resolve(r, k, cfg)];
      final avg = _resolve(r, 0, cfg);
      final header = ['', 'avg', 'ua', for (final x in r.records) '#${x['record']}'];
      final items = <(int c, int q)>[];
      final nc = avg.length;
      final nq = avg.first.length;
      if (cfg.group == GroupMode.byChannels) {
        for (var c = 0; c < nc; c++) {
          for (var q = 0; q < nq; q++) {
            items.add((c, q));
          }
        }
      } else {
        for (var q = 0; q < nq; q++) {
          for (var c = 0; c < nc; c++) {
            items.add((c, q));
          }
        }
      }
      for (final (c, q) in items) {
        final a = avg[c][q];
        if (!shown(a) || (a.value.length != 1 && a.text.isEmpty)) continue;
        if (a.text.isNotEmpty) {
          rows.add(['${a.name}[${a.tag}]', '', '', for (final p in per) p[c][q].text]);
        } else {
          rows.add([
            '${a.name}[${a.tag}]',
            fmt(_conv(a, a.value.first, cfg)),
            a.unc.isEmpty || a.unc.first.isNaN
                ? ''
                : fmt(
                    a.isPhase
                        ? _phase(a.unc.first, PhaseMode.pmPi) * (cfg.phase.index >= 2 ? 180 / math.pi : 1)
                        : a.unc.first,
                  ),
            for (final p in per) fmt(_conv(p[c][q], p[c][q].value.first, cfg)),
          ]);
        }
        descs.add(a.desc);
        names.add(a.name);
        chIdx.add(c + 1);
      }
      return ResultsTable(header: header, rows: rows, descriptions: descs, variableNames: names, channelIndex: chIdx);
    }
    // vector / matrix view of one result
    final res = _resolve(r, cfg.resultId, cfg);
    var width = 1;
    for (var c = 0; c < res.length; c++) {
      for (final q in res[c]) {
        if (!shown(q)) continue;
        final big = q.value.length > cfg.maxArray;
        final cells = q.text.isNotEmpty
            ? [q.text]
            : big
            ? ['graph (${q.value.length} values)']
            : [for (final v in q.value) fmt(_conv(q, v, cfg))];
        width = math.max(width, cells.length);
        rows.add(['${q.name}[${q.tag}]', ...cells]);
        descs.add(q.desc);
        names.add(q.name);
        chIdx.add(c + 1);
      }
    }
    final header = ['', for (var k = 1; k <= width; k++) '($k)'];
    return ResultsTable(header: header, rows: rows, descriptions: descs, variableNames: names, channelIndex: chIdx);
  }

  Future<ResultData> resultData(String session, String algorithm, ResultViewConfig cfg) async {
    final r = await _load(session, algorithm);
    if (r == null || r.records.isEmpty) return const ResultData();
    final res = _resolve(r, cfg.resultId, cfg);
    final vars = cfg.variables;
    return ResultData(
      resultId: cfg.resultId,
      count: r.records.length,
      channels: [
        for (final c in res)
          [
            for (final q in c)
              if (vars.isEmpty || vars.contains(q.name))
                ResultQuantity(
                  name: q.name,
                  desc: q.desc,
                  tag: q.tag,
                  text: q.text,
                  isPhase: q.isPhase,
                  isGraph: q.isGraph,
                  graphX: q.graphX,
                  unc: q.unc,
                  value: [for (final v in q.value) _conv(q, v, cfg)],
                ),
          ],
      ],
    );
  }
}

class _Chan {
  final String tag;
  final int hi;
  final int lo;
  final double gain;
  final bool isCurrent;
  final int phase;
  final bool inverted;
  _Chan(this.tag, this.hi, this.lo, this.gain, this.isCurrent, this.phase, this.inverted);
}

class _Results {
  final String alg;
  final List<String> algorithms;
  final String last;
  final List<Map<String, dynamic>> records;
  _Results(this.alg, this.algorithms, this.last, this.records);
}
