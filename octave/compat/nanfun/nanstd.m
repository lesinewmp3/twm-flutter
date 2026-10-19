function s = nanstd(x, opt, dim)
% Compatibility replacement of nanstd (removed from Octave statistics pkg).
  if nargin < 2 || isempty(opt), opt = 0; end
  if nargin < 3
    dim = find(size(x) ~= 1, 1);
    if isempty(dim), dim = 1; end
  end
  s = sqrt(nanvar(x, opt, dim));
end
