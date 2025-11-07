// lib/widgets/preview_table.dart
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../ui/preview_utils.dart';

class PreviewTable extends StatelessWidget {
  const PreviewTable({super.key, required this.days});
  final List<DayTotals> days;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Expanded(child: Text('Datum', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Timetac', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Meetings', style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text('Arbeit', style: TextStyle(fontWeight: FontWeight.bold))),
          ]),
          const Divider(),
          for (final d in days)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Row(children: [
                Expanded(
                    child: Text(
                        '${d.date.year}-${d.date.month.toString().padLeft(2, '0')}-${d.date.day.toString().padLeft(2, '0')}')),
                Expanded(child: Text(formatDuration(d.timetacTotal))),
                Expanded(child: Text(formatDuration(d.meetingsTotal))),
                Expanded(child: Text(formatDuration(d.leftover))),
              ]),
            ),
        ]),
      ),
    );
  }
}
