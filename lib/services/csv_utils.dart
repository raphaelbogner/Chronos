//
// lib/services/csv_utils.dart
//

/// Detects the most likely delimiter in the CSV sample.
String detectDelimiter(String sample) {
  int count(String ch) => RegExp(RegExp.escape(ch)).allMatches(sample).length;
  final semi = count(';');
  final comma = count(',');
  final tab = count('\t');
  if (semi == 0 && comma == 0 && tab == 0) return ';';
  if (tab >= semi && tab >= comma) return '\t';
  return semi >= comma ? ';' : ',';
}

/// Parses CSV content into rows while handling quotes and multiline fields.
List<List<String>> parseCsv(String content) {
  final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final firstNonEmpty = normalized.split('\n').firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => '',
      );
  final delimiter = detectDelimiter(firstNonEmpty);

  final rows = <List<String>>[];
  final current = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  void flushField() {
    current.add(field.toString());
    field.clear();
  }

  void flushRow() {
    rows.add(List<String>.from(current));
    current.clear();
  }

  for (var i = 0; i < normalized.length; i++) {
    final ch = normalized[i];
    if (inQuotes) {
      if (ch == '"') {
        final next = i + 1 < normalized.length ? normalized[i + 1] : null;
        if (next == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }

    if (ch == '"') {
      inQuotes = true;
      continue;
    }

    if (ch == delimiter) {
      flushField();
      continue;
    }

    if (ch == '\n') {
      flushField();
      flushRow();
      continue;
    }

    field.write(ch);
  }

  flushField();
  if (current.isNotEmpty) {
    flushRow();
  }

  return rows.where((row) => row.any((cell) => cell.trim().isNotEmpty)).toList();
}
