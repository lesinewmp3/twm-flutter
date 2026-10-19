function y = nanmean(x, dim)
% Compatibility replacement of nanmean (removed from Octave statistics pkg).
  if nargin < 2
    dim = find(size(x) ~= 1, 1);
    if isempty(dim), dim = 1; end
  end
  m = ~isnan(x);
  x(~m) = 0;
  y = sum(x, dim) ./ sum(m, dim);
end
