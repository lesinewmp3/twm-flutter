function v = nanvar(x, opt, dim)
% Compatibility replacement of nanvar (removed from Octave statistics pkg).
  if nargin < 2 || isempty(opt), opt = 0; end
  if nargin < 3
    dim = find(size(x) ~= 1, 1);
    if isempty(dim), dim = 1; end
  end
  m = ~isnan(x);
  n = sum(m, dim);
  mu = nanmean(x, dim);
  d = bsxfun(@minus, x, mu);
  d(~m) = 0;
  v = sum(d.^2, dim) ./ max(n - (opt == 0), 1);
end
