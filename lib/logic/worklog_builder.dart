// lib/logic/worklog_builder.dart
import 'package:collection/collection.dart';

class WorkWindow {
  WorkWindow(this.start, this.end);
  DateTime start;
  DateTime end;
  Duration get duration => end.difference(start);
}

class DraftLog {
  DraftLog({required this.start, required this.end, required this.issueKey, required this.note});
  DateTime start;
  DateTime end;
  String issueKey;
  String note;
  Duration get duration => end.difference(start);
}

List<WorkWindow> subtractIntervals(WorkWindow base, List<WorkWindow> cutters) {
  var pieces = <WorkWindow>[base];
  for (final c in cutters) {
    final next = <WorkWindow>[];
    for (final p in pieces) {
      final latestStart = p.start.isAfter(c.start) ? p.start : c.start;
      final earliestEnd = p.end.isBefore(c.end) ? p.end : c.end;
      final overlap = earliestEnd.isAfter(latestStart);
      if (!overlap) {
        next.add(p);
      } else {
        if (c.start.isAfter(p.start)) {
          next.add(WorkWindow(p.start, c.start));
        }
        if (c.end.isBefore(p.end)) {
          next.add(WorkWindow(c.end, p.end));
        }
      }
    }
    pieces = next;
  }
  return pieces.where((w) => w.duration.inSeconds >= 60).toList();
}

List<DraftLog> buildDraftsForDay({
  required DateTime day,
  required List<WorkWindow> workWindows,
  required List<WorkWindow> meetings,
  required String meetingIssueKey,
  required String fallbackIssueKey,
  required String? meetingNotePrefix,
  required String? fallbackNote,
}) {
  final drafts = <DraftLog>[];

  for (final m in meetings) {
    final meetingPieces = workWindows
        .map((w) {
          final s = m.start.isAfter(w.start) ? m.start : w.start;
          final e = m.end.isBefore(w.end) ? m.end : w.end;
          return e.isAfter(s) ? WorkWindow(s, e) : null;
        })
        .whereNotNull()
        .toList();

    for (final piece in meetingPieces) {
      drafts.add(DraftLog(
        start: piece.start,
        end: piece.end,
        issueKey: meetingIssueKey,
        note: '${meetingNotePrefix ?? 'Meeting'} ${_hhmm(piece.start)}–${_hhmm(piece.end)}',
      ));
    }
  }

  final fallbackPieces = <WorkWindow>[];
  for (final w in workWindows) {
    final cut = subtractIntervals(w, meetings);
    fallbackPieces.addAll(cut);
  }

  for (final piece in fallbackPieces) {
    drafts.add(DraftLog(
      start: piece.start,
      end: piece.end,
      issueKey: fallbackIssueKey,
      note: fallbackNote ?? 'Rest',
    ));
  }

  drafts.sort((a, b) => a.start.compareTo(b.start));
  return drafts;
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
