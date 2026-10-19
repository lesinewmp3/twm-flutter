function infostr = infoload(filename, autoextension)
% Portable replacement of TWM 'info/infoload.m': TWM stores relative paths
% with DOS separators ('RESULTS\x'), which fails on Linux/macOS. This
% version converts the separators and is otherwise identical.
  if nargin < 2
    autoextension = 1;
  end
  if ~ischar(filename)
    error('infoload: filename must be string')
  end
  if filesep() == '/'
    filename = strrep(filename, '\', '/');
  end
  if autoextension && (length(filename) < 5 || ~strcmpi(filename(end-4:end), '.info'))
    filename = [filename '.info'];
  end
  if ~exist(filename, 'file')
    error(['infoload: file `' filename '` not found'])
  end
  fid = fopen(filename, 'r');
  if fid == -1
    error(['infoload: error opening file `' filename '`'])
  end
  infostr = fread(fid, [1, inf], 'uint8=>char');
  fclose(fid);
end
