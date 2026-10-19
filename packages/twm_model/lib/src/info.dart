/// INFO-STRINGS format used by TWM/TPQA (modified CMI variant, see
/// `octprog/info/*.m` in the TWM repository).
///
/// Syntax:
/// ```
/// key:: value
/// #startmatrix:: name
///   a; b; c
///   d; e; f
/// #endmatrix:: name
/// #startsection:: name
///   ... nested content ...
/// #endsection:: name
/// ```
/// Any line without `::` is a comment/free text and is ignored by the
/// readers. Matrix cells are separated by `;`, rows by new lines and cells
/// may be quoted by `"` (RFC4180 style with `""` escape).
library;

/// One item of an INFO document, kept in order so the document can be
/// round-tripped (comments are preserved).
sealed class InfoItem {
  const InfoItem();
}

class InfoComment extends InfoItem {
  final String text;
  const InfoComment(this.text);
}

class InfoScalar extends InfoItem {
  final String key;
  String value;
  InfoScalar(this.key, this.value);
}

class InfoMatrix extends InfoItem {
  final String name;
  List<List<String>> cells;
  InfoMatrix(this.name, this.cells);
}

class InfoSection extends InfoItem {
  final String name;
  final Info content;
  InfoSection(this.name, this.content);
}

class InfoException implements Exception {
  final String message;
  InfoException(this.message);
  @override
  String toString() => 'InfoException: $message';
}

/// Parsed (and editable) INFO document or section.
class Info {
  final List<InfoItem> items;

  Info([List<InfoItem>? items]) : items = items ?? [];

  // ---------------------------------------------------------------- parse --

  factory Info.parse(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var pos = 0;
    Info parseBlock(String? sectionName) {
      final info = Info();
      while (pos < lines.length) {
        final raw = lines[pos++];
        final line = raw.trim();
        if (line.startsWith('#startsection')) {
          final name = _tagName(line);
          if (name == null) {
            info.items.add(InfoComment(raw));
            continue;
          }
          info.items.add(InfoSection(name, parseBlock(name)));
        } else if (line.startsWith('#endsection')) {
          final name = _tagName(line);
          if (name != null) {
            if (name != sectionName) {
              throw InfoException("'#endsection:: $name' does not match '#startsection:: $sectionName'");
            }
            return info;
          }
          info.items.add(InfoComment(raw));
        } else if (line.startsWith('#startmatrix')) {
          final name = _tagName(line);
          if (name == null) {
            info.items.add(InfoComment(raw));
            continue;
          }
          final body = StringBuffer();
          var closed = false;
          while (pos < lines.length) {
            final l = lines[pos++];
            final t = l.trim();
            if (t.startsWith('#endmatrix') && _tagName(t) == name) {
              closed = true;
              break;
            }
            body.writeln(l);
          }
          if (!closed) {
            throw InfoException("missing '#endmatrix:: $name'");
          }
          info.items.add(InfoMatrix(name, parseCsvCells(body.toString())));
        } else {
          final qi = line.indexOf('::');
          if (qi > 0 && !line.startsWith('//')) {
            info.items.add(InfoScalar(line.substring(0, qi).trim(), line.substring(qi + 2).trim()));
          } else {
            info.items.add(InfoComment(raw));
          }
        }
      }
      if (sectionName != null) {
        throw InfoException("missing '#endsection:: $sectionName'");
      }
      return info;
    }

    return parseBlock(null);
  }

  static String? _tagName(String line) {
    final qi = line.indexOf('::');
    if (qi < 0) return null;
    final name = line.substring(qi + 2).trim();
    return name.isEmpty ? null : name;
  }

  /// Parses `;` separated cells with optional quoting. Trailing empty
  /// columns (caused by rows terminated by `;`) are removed.
  static List<List<String>> parseCsvCells(String s, {String sep = ';'}) {
    final rows = <List<String>>[];
    if (s.trim().isEmpty) return rows;
    var row = <String>[];
    final field = StringBuffer();
    var inQuote = false;
    var wasQuoted = false;
    void endField() {
      row.add(wasQuoted ? field.toString() : field.toString().trim());
      field.clear();
      wasQuoted = false;
    }

    void endRow() {
      endField();
      if (!(row.length == 1 && row[0].isEmpty)) rows.add(row);
      row = <String>[];
    }

    final str = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (var i = 0; i < str.length; i++) {
      final c = str[i];
      if (inQuote) {
        if (c == '"') {
          if (i + 1 < str.length && str[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuote = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"' && field.toString().trim().isEmpty) {
        field.clear();
        inQuote = true;
        wasQuoted = true;
      } else if (c == sep) {
        endField();
      } else if (c == '\n') {
        endRow();
      } else {
        field.write(c);
      }
    }
    endRow();
    // remove trailing columns that are empty in all rows
    var cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    while (cols > 0 && rows.every((r) => r.length < cols || r[cols - 1].isEmpty)) {
      cols--;
    }
    return [
      for (final r in rows) [for (var c = 0; c < cols; c++) c < r.length ? r[c] : ''],
    ];
  }

  // -------------------------------------------------------------- getters --

  Iterable<InfoScalar> get scalars => items.whereType<InfoScalar>();
  Iterable<InfoMatrix> get matrices => items.whereType<InfoMatrix>();
  Iterable<InfoSection> get sections => items.whereType<InfoSection>();

  bool hasKey(String key) => scalars.any((s) => s.key == key);
  bool hasMatrix(String name) => matrices.any((m) => m.name == name);
  bool hasSection(String name) => sections.any((s) => s.name == name);

  String text(String key) {
    final found = scalars.where((s) => s.key == key).toList();
    if (found.isEmpty) throw InfoException("key '$key' not found");
    if (found.length > 1) throw InfoException("key '$key' found multiple times");
    return found.first.value;
  }

  String? textOrNull(String key) => hasKey(key) ? text(key) : null;

  double number(String key) {
    final v = parseNumber(text(key));
    if (v == null) throw InfoException("key '$key' does not contain numeric data");
    return v;
  }

  double? numberOrNull(String key) => hasKey(key) ? parseNumber(text(key)) : null;

  List<List<String>> textMatrix(String name) {
    for (final m in matrices) {
      if (m.name == name) return m.cells;
    }
    throw InfoException("matrix '$name' not found");
  }

  List<List<String>>? textMatrixOrNull(String name) => hasMatrix(name) ? textMatrix(name) : null;

  /// Text matrix flattened column-wise (Matlab `(:)` order). Most of the
  /// TWM text matrices are column vectors.
  List<String> textList(String name) => _flatten(textMatrix(name));

  List<List<double>> matrix(String name) =>
      textMatrix(name).map((r) => r.map((c) => parseNumber(c) ?? double.nan).toList()).toList();

  List<List<double>>? matrixOrNull(String name) => hasMatrix(name) ? matrix(name) : null;

  List<double> vector(String name) => _flatten(matrix(name));

  static List<T> _flatten<T>(List<List<T>> m) {
    if (m.isEmpty) return [];
    final cols = m.first.length;
    return [
      for (var c = 0; c < cols; c++)
        for (final r in m)
          if (c < r.length) r[c],
    ];
  }

  Info section(String name) {
    for (final s in sections) {
      if (s.name == name) return s.content;
    }
    throw InfoException("section '$name' not found");
  }

  Info? sectionOrNull(String name) => hasSection(name) ? section(name) : null;

  /// Access nested section by path.
  Info sectionPath(List<String> path) {
    var info = this;
    for (final p in path) {
      info = info.section(p);
    }
    return info;
  }

  // -------------------------------------------------------------- setters --

  int _indexWhere(bool Function(InfoItem) test) => items.indexWhere(test);

  void setText(String key, String value) {
    final i = _indexWhere((e) => e is InfoScalar && e.key == key);
    if (i >= 0) {
      (items[i] as InfoScalar).value = value;
    } else {
      items.add(InfoScalar(key, value));
    }
  }

  void setNumber(String key, num value) => setText(key, formatNumber(value));

  void setBool(String key, bool value) => setNumber(key, value ? 1 : 0);

  void setTextMatrix(String name, List<List<String>> cells) {
    final i = _indexWhere((e) => e is InfoMatrix && e.name == name);
    if (i >= 0) {
      (items[i] as InfoMatrix).cells = cells;
    } else {
      items.add(InfoMatrix(name, cells));
    }
  }

  /// Column vector of strings.
  void setTextList(String name, List<String> values) => setTextMatrix(name, [
    for (final v in values) [v],
  ]);

  void setMatrix(String name, List<List<num>> values) => setTextMatrix(name, [
    for (final r in values) [for (final v in r) formatNumber(v)],
  ]);

  /// Column vector of numbers.
  void setVector(String name, List<num> values) => setMatrix(name, [
    for (final v in values) [v],
  ]);

  /// Row vector of numbers.
  void setRowVector(String name, List<num> values) => setMatrix(name, [values]);

  void setSection(String name, Info content) {
    final i = _indexWhere((e) => e is InfoSection && e.name == name);
    if (i >= 0) {
      items[i] = InfoSection(name, content);
    } else {
      items.add(InfoSection(name, content));
    }
  }

  void comment(String text) => items.add(InfoComment('// $text'));

  void blank() => items.add(const InfoComment(''));

  void remove(String name) => items.removeWhere(
    (e) =>
        (e is InfoScalar && e.key == name) ||
        (e is InfoMatrix && e.name == name) ||
        (e is InfoSection && e.name == name),
  );

  // ------------------------------------------------------------ serialize --

  @override
  String toString() {
    final sb = StringBuffer();
    _write(sb, '');
    return sb.toString();
  }

  static const _indent = '        ';

  void _write(StringBuffer sb, String ind) {
    for (final it in items) {
      switch (it) {
        case InfoComment(:final text):
          final t = text.trim();
          sb.writeln(t.isEmpty ? '' : '$ind$t');
        case InfoScalar(:final key, :final value):
          sb.writeln('$ind$key:: $value');
        case InfoMatrix(:final name, :final cells):
          sb.writeln('$ind#startmatrix:: $name');
          for (final r in cells) {
            sb.writeln('$ind$_indent${r.map(_quoteCell).join('; ')}');
          }
          sb.writeln('$ind#endmatrix:: $name');
        case InfoSection(:final name, :final content):
          sb.writeln('$ind#startsection:: $name');
          content._write(sb, '$ind$_indent');
          sb.writeln('$ind#endsection:: $name');
      }
    }
  }

  static String _quoteCell(String c) {
    if (c.contains(';') || c.contains('\n') || c.contains('"')) {
      return '"${c.replaceAll('"', '""')}"';
    }
    return c;
  }

  /// Number parser compatible with Octave's str2double (accepts inf/nan).
  static double? parseNumber(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final l = t.toLowerCase();
    if (l == 'inf' || l == '+inf') return double.infinity;
    if (l == '-inf') return double.negativeInfinity;
    if (l == 'nan') return double.nan;
    return double.tryParse(t);
  }

  /// Number formatter: integers without decimal part, otherwise shortest
  /// round-trip representation (always with decimal dot).
  static String formatNumber(num v) {
    if (v is int) return v.toString();
    final d = v.toDouble();
    if (d.isNaN) return 'NaN';
    if (d.isInfinite) return d > 0 ? 'Inf' : '-Inf';
    if (d == d.truncateToDouble() && d.abs() < 1e15) {
      return d.toInt().toString();
    }
    return d.toString();
  }
}
