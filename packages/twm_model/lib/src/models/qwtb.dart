/// QWTB algorithm descriptions and results (data returned by the
/// processing module).
library;

import '../json.dart';

class AlgorithmSummary {
  final String id;
  final String name;
  const AlgorithmSummary(this.id, this.name);
  Json toJson() => {'id': id, 'name': name};
  factory AlgorithmSummary.fromJson(Json j) =>
      AlgorithmSummary(jString(j['id']), jString(j['name']));
}

class AlgorithmInput {
  final String name;
  final String desc;
  final bool optional;
  final int alternative;
  final bool parameter;
  final List<String> enumValues;
  const AlgorithmInput({
    required this.name,
    this.desc = '',
    this.optional = false,
    this.alternative = 0,
    this.parameter = false,
    this.enumValues = const [],
  });

  /// Label like in TWM parameters table: "name  (opt., alt. 1)".
  String get label {
    final c = [if (optional) 'opt.', if (alternative != 0) 'alt. $alternative'];
    return c.isEmpty ? name : '$name  (${c.join(', ')})';
  }

  Json toJson() => {
        'name': name,
        'desc': desc,
        'optional': optional,
        'alternative': alternative,
        'parameter': parameter,
        'enum': enumValues,
      };
  factory AlgorithmInput.fromJson(Json j) => AlgorithmInput(
        name: jString(j['name']),
        desc: jString(j['desc']),
        optional: jBool(j['optional']),
        alternative: jInt(j['alternative']),
        parameter: jBool(j['parameter']),
        enumValues: jStringList(j['enum']),
      );
}

class AlgorithmInfo {
  final String id;
  final String name;
  final String desc;
  final String citation;
  final String remarks;
  final String license;
  final List<AlgorithmInput> inputs;
  final List<({String name, String desc})> outputs;
  final bool supportMultiRecords;
  final bool supportDiff;
  final bool hasUi;
  final bool uncGuf;
  final bool uncMcm;

  const AlgorithmInfo({
    required this.id,
    required this.name,
    this.desc = '',
    this.citation = '',
    this.remarks = '',
    this.license = '',
    this.inputs = const [],
    this.outputs = const [],
    this.supportMultiRecords = false,
    this.supportDiff = false,
    this.hasUi = false,
    this.uncGuf = false,
    this.uncMcm = false,
  });

  /// User parameters (shown in the parameters table).
  List<AlgorithmInput> get parameters => inputs.where((i) => i.parameter).toList();

  Json toJson() => {
        'id': id,
        'name': name,
        'desc': desc,
        'citation': citation,
        'remarks': remarks,
        'license': license,
        'inputs': [for (final i in inputs) i.toJson()],
        'outputs': [for (final o in outputs) {'name': o.name, 'desc': o.desc}],
        'support_multi_records': supportMultiRecords,
        'support_diff': supportDiff,
        'has_ui': hasUi,
        'unc_guf': uncGuf,
        'unc_mcm': uncMcm,
      };

  factory AlgorithmInfo.fromJson(Json j) => AlgorithmInfo(
        id: jString(j['id']),
        name: jString(j['name']),
        desc: jString(j['desc']),
        citation: jString(j['citation']),
        remarks: jString(j['remarks']),
        license: jString(j['license']),
        inputs: [for (final i in _list(j['inputs'])) AlgorithmInput.fromJson(i)],
        outputs: [
          for (final o in _list(j['outputs'])) (name: jString(o['name']), desc: jString(o['desc']))
        ],
        supportMultiRecords: jBool(j['support_multi_records']),
        supportDiff: jBool(j['support_diff']),
        hasUi: jBool(j['has_ui']),
        uncGuf: jBool(j['unc_guf']),
        uncMcm: jBool(j['unc_mcm']),
      );

  /// jsonencode of a 1-element struct array gives an object, not a list.
  static List<Json> _list(Object? v) => v is Map ? [jMap(v)] : jMapList(v);
}

/// Results view configuration ('cfg' of qwtb_get_results.m and the
/// selectors of the TWM results viewer).
enum ResultDim { scalar, vector, matrix }

enum UncDisplay { none, plusMinus, alternateRows }

enum GroupMode { byChannels, byQuantities }

enum PhaseMode {
  pmPi('±π [rad]'),
  zeroTwoPi('0-2π [rad]'),
  pm180('±180 [°]'),
  zero360('0-360 [°]');

  final String label;
  const PhaseMode(this.label);
}

enum AmplitudeMode {
  amplitude('Amplitude', 1.0),
  rms('RMS', 0.7071067811865476),
  peakToPeak('Peak-peak', 2.0);

  final String label;
  final double factor;
  const AmplitudeMode(this.label, this.factor);
}

class ResultViewConfig {
  ResultDim maxDim;
  int maxArray;
  UncDisplay unc;
  GroupMode group;
  PhaseMode phase;
  int phaseRefChannel; // 0 = disabled
  AmplitudeMode amplitude;

  /// -1 last result, 0 average, >0 selected result.
  int resultId;
  List<String> variables;

  ResultViewConfig({
    this.maxDim = ResultDim.scalar,
    this.maxArray = 10,
    this.unc = UncDisplay.none,
    this.group = GroupMode.byChannels,
    this.phase = PhaseMode.pmPi,
    this.phaseRefChannel = 0,
    this.amplitude = AmplitudeMode.amplitude,
    this.resultId = -1,
    List<String>? variables,
  }) : variables = variables ?? [];

  /// The 'cfg' structure for the m-functions.
  Json toCfg() => {
        'max_dim': maxDim.index,
        'max_array': maxArray,
        'unc_mode': unc.index,
        'group_mode': group.index,
        'phi_mode': phase.index,
        'phi_ref_chn': phaseRefChannel,
        'amp_mode': amplitude.factor,
      };

  Json toJson() => {
        'maxDim': maxDim.name,
        'maxArray': maxArray,
        'unc': unc.name,
        'group': group.name,
        'phase': phase.name,
        'phaseRefChannel': phaseRefChannel,
        'amplitude': amplitude.name,
        'resultId': resultId,
        'variables': variables,
      };

  factory ResultViewConfig.fromJson(Json j) => ResultViewConfig(
        maxDim: enumByName(ResultDim.values, j['maxDim'], ResultDim.scalar),
        maxArray: jInt(j['maxArray'], 10),
        unc: enumByName(UncDisplay.values, j['unc'], UncDisplay.none),
        group: enumByName(GroupMode.values, j['group'], GroupMode.byChannels),
        phase: enumByName(PhaseMode.values, j['phase'], PhaseMode.pmPi),
        phaseRefChannel: jInt(j['phaseRefChannel']),
        amplitude: enumByName(AmplitudeMode.values, j['amplitude'], AmplitudeMode.amplitude),
        resultId: jInt(j['resultId'], -1),
        variables: jStringList(j['variables']),
      );
}

/// Output of qwtb_get_results_info.m.
class ResultsInfo {
  final List<String> files;
  final bool exists;
  final String lastAlgorithm;
  final List<String> algorithms;
  final List<String> channels; // e.g. "u1, i1" or "L1"
  final List<String> variables;

  const ResultsInfo({
    this.files = const [],
    this.exists = false,
    this.lastAlgorithm = '',
    this.algorithms = const [],
    this.channels = const [],
    this.variables = const [],
  });

  static const empty = ResultsInfo();

  Json toJson() => {
        'files': files,
        'exists': exists,
        'lastAlgorithm': lastAlgorithm,
        'algorithms': algorithms,
        'channels': channels,
        'variables': variables,
      };
  factory ResultsInfo.fromJson(Json j) => ResultsInfo(
        files: jStringList(j['files']),
        exists: jBool(j['exists']),
        lastAlgorithm: jString(j['lastAlgorithm']),
        algorithms: jStringList(j['algorithms']),
        channels: jStringList(j['channels']),
        variables: jStringList(j['variables']),
      );
}

/// Formatted results table (qwtb_get_results.m output).
class ResultsTable {
  final List<String> header;
  final List<List<String>> rows; // first column = quantity[channel]
  final List<String> descriptions;
  final List<String> variableNames;
  final List<int> channelIndex;

  const ResultsTable({
    this.header = const [],
    this.rows = const [],
    this.descriptions = const [],
    this.variableNames = const [],
    this.channelIndex = const [],
  });

  static const empty = ResultsTable();

  Json toJson() => {
        'header': header,
        'rows': rows,
        'descriptions': descriptions,
        'variableNames': variableNames,
        'channelIndex': channelIndex,
      };
  factory ResultsTable.fromJson(Json j) => ResultsTable(
        header: jStringList(j['header']),
        rows: [for (final r in (j['rows'] as List? ?? [])) jStringList(r)],
        descriptions: jStringList(j['descriptions']),
        variableNames: jStringList(j['variableNames']),
        channelIndex: jIntList(j['channelIndex']),
      );

  /// Tab separated text for clipboard (Excel compatible).
  String toTsv() =>
      [header.join('\t'), for (final r in rows) r.join('\t')].join('\n');
}

/// Numeric result quantity (for graphs and spectrum view).
class ResultQuantity {
  final String name;
  final String desc;
  final String tag;
  final List<double> value;
  final List<double> unc;
  final bool isPhase;
  final bool isGraph;
  final String graphX;
  final String text;

  const ResultQuantity({
    required this.name,
    this.desc = '',
    this.tag = '',
    this.value = const [],
    this.unc = const [],
    this.isPhase = false,
    this.isGraph = false,
    this.graphX = '',
    this.text = '',
  });

  Json toJson() => {
        'name': name,
        'desc': desc,
        'tag': tag,
        'value': [for (final v in value) jNum(v)],
        'unc': [for (final v in unc) jNum(v)],
        'isPhase': isPhase,
        'isGraph': isGraph,
        'graphX': graphX,
        'text': text,
      };

  factory ResultQuantity.fromJson(Json j) => ResultQuantity(
        name: jString(j['name']),
        desc: jString(j['desc']),
        tag: jString(j['tag']),
        value: jDoubleList(j['value']),
        unc: jDoubleList(j['unc']),
        isPhase: jBool(j['isPhase']),
        isGraph: jBool(j['isGraph']),
        graphX: jString(j['graphX']),
        text: jString(j['text']),
      );
}

class ResultData {
  final int resultId;
  final int count;

  /// One list of quantities per channel/phase.
  final List<List<ResultQuantity>> channels;
  const ResultData({this.resultId = 0, this.count = 0, this.channels = const []});

  Json toJson() => {
        'resultId': resultId,
        'count': count,
        'channels': [
          for (final c in channels) [for (final q in c) q.toJson()]
        ],
      };
  factory ResultData.fromJson(Json j) => ResultData(
        resultId: jInt(j['resultId']),
        count: jInt(j['count']),
        channels: [
          for (final c in (j['channels'] as List? ?? []))
            [for (final q in jMapList(c)) ResultQuantity.fromJson(q)]
        ],
      );
}
