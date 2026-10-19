import 'info.dart';

/// Semicolon separated CSV matrix used by TWM correction tables
/// (see "TWM Corrections Reference Manual", section CSV matrices).
///
/// Layout of a correction table:
/// ```
/// row 1: description;;
/// row 2: ;quantity 1;quantity 2 ...   (quantity names, repeated per x-axis column)
/// row 3: y-axis \ x-axis;x1;x2...      (only for 2D tables)
/// rows : y value;data...
/// ```
class CsvSheet {
  List<List<String>> cells;

  CsvSheet([List<List<String>>? cells]) : cells = cells ?? [];

  factory CsvSheet.parse(String text) {
    final rows = Info.parseCsvCells(text);
    return CsvSheet(rows)..normalize();
  }

  int get rows => cells.length;
  int get cols => cells.fold(0, (m, r) => r.length > m ? r.length : m);

  String cell(int r, int c) =>
      r < cells.length && c < cells[r].length ? cells[r][c] : '';

  void setCell(int r, int c, String v) {
    while (cells.length <= r) {
      cells.add([]);
    }
    final row = cells[r];
    while (row.length <= c) {
      row.add('');
    }
    row[c] = v;
  }

  /// Pads all rows to the same length.
  void normalize() {
    final n = cols;
    for (final r in cells) {
      while (r.length < n) {
        r.add('');
      }
    }
  }

  void insertRow(int at) {
    normalize();
    cells.insert(at.clamp(0, cells.length), List.filled(cols, '', growable: true));
  }

  void removeRow(int at) {
    if (at >= 0 && at < cells.length) cells.removeAt(at);
  }

  void insertCol(int at) {
    normalize();
    for (final r in cells) {
      r.insert(at.clamp(0, r.length), '');
    }
  }

  void removeCol(int at) {
    for (final r in cells) {
      if (at >= 0 && at < r.length) r.removeAt(at);
    }
  }

  /// Replaces decimal commas by dots in numeric looking cells (TWM accepts
  /// decimal dot only).
  void fixDecimalSeparators() {
    final re = RegExp(r'^[+-]?\d+,\d*([eE][+-]?\d+)?$');
    for (final r in cells) {
      for (var i = 0; i < r.length; i++) {
        if (re.hasMatch(r[i].trim())) r[i] = r[i].replaceAll(',', '.');
      }
    }
  }

  @override
  String toString() {
    normalize();
    return cells
        .map((r) => r.map((c) {
              if (c.contains(';') || c.contains('"') || c.contains('\n')) {
                return '"${c.replaceAll('"', '""')}"';
              }
              return c;
            }).join(';'))
        .join('\n');
  }

  /// Template for a new correction table.
  ///
  /// [quantities] are the dependent quantity names (e.g. `gain`, `u(gain)`),
  /// [yAxis] the primary axis (e.g. `f`), [xAxis] the optional secondary axis
  /// (e.g. `rms`), [xCount] number of secondary axis columns.
  factory CsvSheet.template({
    required String description,
    required String yAxis,
    String? xAxis,
    required List<String> quantities,
    int xCount = 1,
    int yCount = 2,
  }) {
    final has2d = xAxis != null && xAxis.isNotEmpty;
    final a = has2d ? xCount : 1;
    final n = 1 + quantities.length * a;
    List<String> row() => List.filled(n, '', growable: true);
    final s = CsvSheet();
    s.cells.add(row()..[0] = description);
    final q = row();
    for (var i = 0; i < quantities.length; i++) {
      for (var j = 0; j < a; j++) {
        q[1 + i * a + j] = quantities[i];
      }
    }
    s.cells.add(q);
    if (has2d) {
      s.cells.add(row()..[0] = '$yAxis \\ $xAxis');
    }
    for (var k = 0; k < yCount; k++) {
      s.cells.add(row());
    }
    return s;
  }
}
