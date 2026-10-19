function y = nanmedian(x, dim)
% Compatibility replacement of nanmedian (removed from Octave statistics pkg).
  if nargin < 2
    dim = find(size(x) ~= 1, 1);
    if isempty(dim), dim = 1; end
  end
  perm = [dim, setdiff(1:max(ndims(x), dim), dim)];
  xp = permute(x, perm);
  sz = size(xp);
  xp = reshape(xp, sz(1), []);
  y = zeros(1, size(xp, 2));
  for k = 1:size(xp, 2)
    c = xp(~isnan(xp(:, k)), k);
    if isempty(c), y(k) = NaN; else y(k) = median(c); end
  end
  sz(1) = 1;
  y = ipermute(reshape(y, sz), perm);
end
