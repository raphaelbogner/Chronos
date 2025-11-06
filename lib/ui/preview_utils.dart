// lib/ui/preview_utils.dart
String formatDuration(Duration d) {
  final sign = d.isNegative ? '-' : '';
  final totalMinutes = d.inMinutes.abs();
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  return '$sign${h.toString()}h ${m.toString().padLeft(2, '0')}m';
}
