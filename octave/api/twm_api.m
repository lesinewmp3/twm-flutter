function twm_api(cmd, varargin)
% Flutter TWM <-> GNU Octave/Matlab interface (replacement of GOLPI).
%
% Calls the original TWM processing functions from 'octprog' and prints the
% result as a single JSON line prefixed by '@@TWMJSON@@' to the stdout,
% where it is picked up by the Dart side (twm_core/lib/src/octave).
%
% Commands:
%   twm_api('init', octprog_path, qwtb_path, compat_path, packages)
%   twm_api('version')
%   twm_api('algorithms', list_file)
%   twm_api('algorithm', alg_id)
%   twm_api('exec', meas_file, calc_unc, is_last_avg, avg_id, group_id, cfg)
%   twm_api('results_info', meas_root, alg_id)
%   twm_api('results', meas_root, res_id, alg_id, cfg, var_list)
%   twm_api('result_data', meas_root, res_id, alg_id, cfg, var_list)
%   twm_api('find_coherent', f0, t_min, t_max, rate, max_err, timeout)
%   twm_api('raw', meas_file, group_id, avg_id, code)

  switch cmd
    case 'init'
      out = do_init(varargin{:});
    case 'version'
      out = struct('version', version(), 'is_octave', exist('OCTAVE_VERSION', 'builtin') > 0);
    case 'algorithms'
      out = do_algorithms(varargin{:});
    case 'algorithm'
      out = do_algorithm(varargin{:});
    case 'exec'
      [meas_file, calc_unc, is_last_avg, avg_id, group_id, cfg] = deal(varargin{:});
      qwtb_exec_algorithm(meas_file, calc_unc, is_last_avg, avg_id, group_id, 0, cfg);
      out = struct('ok', 1);
    case 'results_info'
      [res_files, res_exist, alg_list, chn_list, var_names] = qwtb_get_results_info(varargin{:});
      out = struct('res_files', res_files, 'res_exist', res_exist, 'alg_list', alg_list, ...
                   'chn_list', chn_list, 'var_names', var_names);
    case 'results'
      [txt, desc, var_names, chn_index, num] = qwtb_get_results(varargin{:});
      out = struct('txt', txt, 'desc', desc, 'var_names', var_names, 'chn_index', chn_index);
    case 'result_data'
      out = do_result_data(varargin{:});
    case 'find_coherent'
      [fs, N, err] = twm_find_coherent(varargin{:});
      out = struct('fs', fs, 'N', N, 'err', err);
    case 'raw'
      out = do_raw(varargin{:});
    otherwise
      error('twm_api: unknown command ''%s''', cmd);
  end
  emit(out);
end

function emit(out)
  disp(['@@TWMJSON@@' jsonencode(out)]);
end

function out = do_init(octprog, qwtb_path, compat, packages)
  more off;
  warning('off', 'all');
  is_octave = exist('OCTAVE_VERSION', 'builtin') > 0;
  addpath(octprog);
  addpath(fullfile(octprog, 'info'));
  if ~isempty(qwtb_path)
    addpath(genpath(qwtb_path));
  end
  loaded = {};
  failed = {};
  if is_octave
    for k = 1:numel(packages)
      try
        pkg('load', packages{k});
        loaded{end+1} = packages{k};
      catch
        failed{end+1} = packages{k};
      end
    end
  end
  % compatibility shims: only those missing in this installation
  shims = {'nanmean', 'nanstd', 'nanvar', 'nanmedian'};
  missing = {};
  for k = 1:numel(shims)
    if ~exist(shims{k})
      missing{end+1} = shims{k};
    end
  end
  % compat folder must have priority (portable infoload.m)
  addpath(compat);
  if ~isempty(missing)
    addpath(fullfile(compat, 'nanfun'));
  end
  installed = {};
  if is_octave
    lst = pkg('list');
    installed = cellfun(@(p) p.name, lst, 'UniformOutput', false);
  end
  out = struct('version', version(), 'is_octave', is_octave, 'loaded', {loaded}, ...
               'failed', {failed}, 'shims', {missing}, 'installed', {installed}, ...
               'has_qwtb', exist('qwtb') > 0);
end

function out = do_algorithms(list_file)
  algs = qwtb();
  ids = {algs.id};
  names = {algs.name};
  if nargin > 0 && ~isempty(list_file)
    allowed = qwtb_parse_alg_filter(list_file);
    keep = cellfun(@(id) any(strcmpi(id, allowed)), ids);
    ids = ids(keep);
    names = names(keep);
  end
  out = struct('ids', {ids}, 'names', {names});
end

function out = do_algorithm(alg_id)
  ai = qwtb(alg_id, 'info');
  inps = ai.inputs;
  inputs = {};
  for k = 1:numel(inps)
    e = {};
    if isfield(inps(k), 'enum') && ~isempty(inps(k).enum)
      e = inps(k).enum(:)';
    end
    inputs{end+1} = struct('name', inps(k).name, 'desc', inps(k).desc, ...
        'optional', inps(k).optional, 'alternative', inps(k).alternative, ...
        'parameter', inps(k).parameter, 'enum', {e});
  end
  outputs = {};
  for k = 1:numel(ai.outputs)
    outputs{end+1} = struct('name', ai.outputs(k).name, 'desc', ai.outputs(k).desc);
  end
  has = @(n) ~~qwtb_find_parameter(ai.inputs, n);
  out = struct('id', ai.id, 'name', ai.name, 'desc', ai.desc, ...
      'citation', getf(ai, 'citation'), 'remarks', getf(ai, 'remarks'), ...
      'license', getf(ai, 'license'), ...
      'inputs', {inputs}, 'outputs', {outputs}, ...
      'support_multi_records', has('support_multi_records'), ...
      'support_diff', has('support_diff'), 'has_ui', ~has('y'), ...
      'unc_guf', ai.providesGUF, 'unc_mcm', ai.providesMCM);
end

function v = getf(s, f, def)
  if nargin < 3, def = ''; end
  if isfield(s, f), v = s.(f); else v = def; end
end

function out = do_result_data(meas_root, res_id, alg_id, cfg, var_list)
  % numeric data of the results for plotting in the GUI
  [results, avg, unca, res_id, are_scalar, is_avg] = qwtb_load_results(meas_root, res_id, alg_id, cfg, var_list);
  if is_avg
    % average of all records (res_id is then the first record's index); the
    % uncertainty combined with the type A one as in qwtb_get_results()
    res = avg;
    for c = 1:numel(res)
      for v = 1:numel(res{c})
        % qwtb_average_results() stops averaging a channel at its first big/string variable
        if any(cellfun(@(x) x{c}{v}.is_big || x{c}{v}.is_string, results))
          break;
        end
        r = res{c}{v};
        if isfield(r, 'unc') && ~isempty(r.unc) && isfield(r, 'conf_level')
          k = loc2covg(r.conf_level, 50);
          res{c}{v}.unc = (r.unc.^2 + (unca{c}{v}.val*k).^2).^0.5;
        end
      end
    end
    res_id = 0;
  else
    res = results{res_id};
  end
  chans = {};
  for c = 1:numel(res)
    q = {};
    for v = 1:numel(res{c})
      r = res{c}{v};
      q{end+1} = struct('name', r.name, 'desc', getf(r, 'desc'), 'tag', getf(r, 'tag'), ...
          'val', r.val, 'unc', getf(r, 'unc'), 'is_phase', getf(r, 'is_phase', 0), ...
          'is_graph', getf(r, 'is_graph', 0), 'graph_x', getf(r, 'graph_x'), ...
          'is_string', getf(r, 'is_string', ischar(r.val)));
    end
    chans{end+1} = q;
  end
  out = struct('res_id', res_id, 'count', numel(results), 'channels', {chans});
end

function out = do_raw(meas_file, group_id, avg_id, code)
  % RAW mode: user m-code executed on loaded data ('data' variable)
  data = tpq_load_record(meas_file, group_id, avg_id);
  result = '';
  txt = evalc(code);
  out = struct('output', txt, 'result', result);
end
