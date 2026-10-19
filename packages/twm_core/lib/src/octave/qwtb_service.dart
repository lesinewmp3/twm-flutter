import 'package:path/path.dart' as p;
import 'package:twm_model/twm_model.dart';

import 'octave_bridge.dart';

/// Typed access to the TWM processing module (m-functions in `octprog`).
class QwtbService {
  final OctaveBridge octave;
  QwtbService(this.octave);

  String get _listFile => p.join(octave.octprogPath, 'qwtb_list.info');

  Future<List<AlgorithmSummary>> algorithms() async {
    await octave.start();
    final r = await octave.call('algorithms', [_listFile]);
    final ids = _strings(r['ids']);
    final names = _strings(r['names']);
    return [for (var i = 0; i < ids.length; i++) AlgorithmSummary(ids[i], i < names.length ? names[i] : '')];
  }

  Future<AlgorithmInfo> algorithm(String id) async {
    await octave.start();
    return AlgorithmInfo.fromJson(await octave.call('algorithm', [id]));
  }

  /// Executes the processing setup stored in `qwtb.info` of the session.
  Future<void> exec(String sessionFile,
      {String uncertainty = '',
      bool isLast = true,
      int record = -1,
      int group = -1,
      ProcessingSetup? setup,
      Duration? timeout}) async {
    await octave.start();
    final cfg = <String, Object?>{
      'mc_method': setup?.parallel.name ?? 'singlecore',
      'mc_procno': setup?.cores ?? 1,
      if (setup != null && setup.jobsFolder.isNotEmpty) 'mc_tmpdir': setup.jobsFolder,
    };
    await octave.call('exec', [sessionFile, uncertainty, isLast, record, group, cfg],
        timeout: timeout);
  }

  Future<ResultsInfo> resultsInfo(String measRoot, {String algorithm = ''}) async {
    await octave.start();
    final Map<String, dynamic> r;
    try {
      r = await octave.call('results_info', [_root(measRoot), algorithm]);
    } on OctaveException catch (e) {
      if (e.message.contains('not found') || e.message.contains('No results')) {
        return ResultsInfo.empty;
      }
      rethrow;
    }
    final algs = _split(r['alg_list'], '\t');
    return ResultsInfo(
      files: _split(r['res_files'], '\t'),
      exists: r['res_exist'] == true || r['res_exist'] == 1,
      lastAlgorithm: algs.isNotEmpty ? algs.first : '',
      // 1: last alg, 2: selected, 3..: list of available
      algorithms: algs.length > 2 ? algs.sublist(2) : const [],
      channels: _split(r['chn_list'], ';'),
      variables: _split(r['var_names'], '\t'),
    );
  }

  Future<ResultsTable> results(String measRoot, String algorithm, ResultViewConfig v) async {
    await octave.start();
    final r = await octave.call('results',
        [_root(measRoot), v.resultId, algorithm, v.toCfg(), v.variables]);
    final txt = r['txt'] is String ? r['txt'] as String : '';
    final table = [
      for (final l in txt.split('\n'))
        if (l.trim().isNotEmpty) l.split('\t')
    ];
    return ResultsTable(
      header: table.isNotEmpty ? table.first : const [],
      rows: table.length > 1 ? table.sublist(1) : const [],
      descriptions: _split(r['desc'], '\t', keepEmpty: true),
      variableNames: _split(r['var_names'], '\t', keepEmpty: true),
      channelIndex: [
        for (final v in (r['chn_index'] is List ? r['chn_index'] as List : [r['chn_index']]))
          if (v is num) v.round()
      ],
    );
  }

  Future<ResultData> resultData(String measRoot, String algorithm, ResultViewConfig v) async {
    await octave.start();
    final cfg = {...v.toCfg(), 'max_dim': 2, 'max_array': 1 << 30};
    final r = await octave.call('result_data', [_root(measRoot), v.resultId, algorithm, cfg, v.variables]);
    List<Object?> asList(Object? x) => x is List ? x : (x == null ? const [] : [x]);
    return ResultData(
      resultId: (r['res_id'] as num?)?.round() ?? 0,
      count: (r['count'] as num?)?.round() ?? 0,
      channels: [
        for (final c in asList(r['channels']))
          [
            for (final q in asList(c))
              if (q is Map)
                ResultQuantity(
                  name: '${q['name']}',
                  desc: '${q['desc'] ?? ''}',
                  tag: '${q['tag'] ?? ''}',
                  value: q['is_string'] == true ? const [] : _flatNum(q['val']),
                  unc: _flatNum(q['unc']),
                  isPhase: q['is_phase'] == true,
                  isGraph: q['is_graph'] == true,
                  graphX: q['graph_x'] is String ? q['graph_x'] as String : '',
                  text: q['val'] is String ? q['val'] as String : '',
                )
          ]
      ],
    );
  }

  /// Coherent sampling search (Sampling Setup Assistant).
  Future<({double fs, int n, double err})> findCoherent(
      double f0, double tMin, double tMax, double rate, double maxErr, double timeout) async {
    await octave.start();
    final r = await octave.call('find_coherent', [f0, tMin, tMax, rate, maxErr, timeout]);
    return (
      fs: (r['fs'] as num).toDouble(),
      n: (r['N'] as num).round(),
      err: (r['err'] as num?)?.toDouble() ?? double.nan,
    );
  }

  /// RAW processing mode: executes user code with loaded `data`.
  Future<String> raw(String sessionFile, String code, {int group = -1, int record = -1}) async {
    await octave.start();
    final r = await octave.call('raw', [sessionFile, group, record, code]);
    return '${r['output'] ?? ''}';
  }

  static String _root(String measRoot) {
    final r = measRoot.endsWith('session.info') ? p.dirname(measRoot) : measRoot;
    return r.endsWith(p.separator) ? r : '$r${p.separator}';
  }

  static List<String> _strings(Object? v) =>
      v is List ? [for (final e in v) '$e'] : (v == null ? const [] : ['$v']);

  static List<String> _split(Object? v, String sep, {bool keepEmpty = false}) {
    if (v == null) return const [];
    final s = v is String ? v : '$v';
    if (s.isEmpty) return const [];
    final parts = s.split(sep).map((e) => e.trim()).toList();
    return keepEmpty ? parts : parts.where((e) => e.isNotEmpty).toList();
  }

  static List<double> _flatNum(Object? v) {
    if (v == null) return const [];
    if (v is num) return [v.toDouble()];
    if (v is List) {
      return [
        for (final e in v)
          if (e is List) ..._flatNum(e) else if (e is num) e.toDouble() else double.nan
      ];
    }
    return const [];
  }
}
