import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/models.dart';
import 'services/csv_parser.dart';
import 'services/ics_parser.dart';
import 'services/jira_api.dart';
import 'services/jira_worklog_api.dart';
import 'services/gitlab_api.dart';
import 'widgets/preview_table.dart';
import 'logic/worklog_builder.dart';
import 'ui/preview_utils.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadPrefs(),
      child: MaterialApp(
        title: 'Timetac + Outlook → Jira Worklogs',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class AppState extends ChangeNotifier {
  SettingsModel settings = SettingsModel();
  List<TimetacRow> timetac = [];
  List<IcsEvent> icsEvents = [];

  // ✨ GitLab Commits Cache
  List<GitlabCommit> gitlabCommits = [];

  DateTimeRange? range;

  Future<void> loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final jsonStr = p.getString('settings');
    if (jsonStr != null) {
      try {
        settings = SettingsModel.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('settings', jsonEncode(settings.toJson()));
  }

  // --- CSV-Klassifizierer wie gehabt (gekürzt hier) ---
  static bool _isCsvAbsence(String desc) {
    final d = desc.toLowerCase();
    return d.contains('urlaub') || d.contains('feiertag') || d.contains('krank') || d.contains('abwesen');
  }

  static bool _isCsvNonProductive(String desc) {
    final d = desc.toLowerCase();
    return d.contains('pause') || d.contains('arzt') || d.contains('nichtleistung') || d.contains('nicht-leistung');
  }

  static bool _isDefaultHomeofficeBlock(TimetacRow r) {
    if (!r.description.toLowerCase().contains('homeoffice')) return false;
    if (r.start == null || r.end == null) return false;
    final mins = r.end!.difference(r.start!).inMinutes;
    return mins >= 420 && mins <= 540;
  }

  // Produktive Arbeitsfenster inkl. Abzug Pausen
  List<WorkWindow> workWindowsForDay(DateTime d) {
    final rows = timetac.where((r) => r.date.year == d.year && r.date.month == d.month && r.date.day == d.day);
    final raw = <WorkWindow>[];
    for (final r in rows) {
      if (_isCsvAbsence(r.description)) continue;
      if (_isCsvNonProductive(r.description)) continue;
      if (_isDefaultHomeofficeBlock(r)) continue;
      if (r.start != null && r.end != null) raw.add(WorkWindow(r.start!, r.end!));
    }
    if (raw.isEmpty) return raw;
    final pauses = <WorkWindow>[];
    for (final r in rows) {
      for (final pr in r.pauses) {
        pauses.add(WorkWindow(pr.start, pr.end));
      }
    }
    if (pauses.isEmpty) return raw;
    final cut = <WorkWindow>[];
    for (final w in raw) {
      cut.addAll(subtractIntervals(w, pauses));
    }
    return cut;
  }

  Duration _timetacProductiveOn(DateTime d) {
    final ws = workWindowsForDay(d);
    return ws.fold<Duration>(Duration.zero, (p, w) => p + w.duration);
  }

  Duration _meetingsIntersectedWithTimetac(DateTime d) {
    final workWindows = workWindowsForDay(d);
    if (workWindows.isEmpty) return Duration.zero;
    final meetings = buildDayCalendarCached(allEvents: icsEvents, day: d).meetings;
    Duration sum = Duration.zero;
    for (final m in meetings) {
      for (final w in workWindows) {
        final s = m.start.isAfter(w.start) ? m.start : w.start;
        final e = m.end.isBefore(w.end) ? m.end : w.end;
        if (e.isAfter(s)) sum += e.difference(s);
      }
    }
    return sum;
  }

  List<DayTotals> get totals {
    final dates = <DateTime>{};
    for (final t in timetac) {
      dates.add(DateTime(t.date.year, t.date.month, t.date.day));
    }
    for (final e in icsEvents) {
      dates.add(DateTime(e.start.year, e.start.month, e.start.day));
    }
    var list = dates.toList();
    if (range != null) {
      final s = DateTime(range!.start.year, range!.start.month, range!.start.day);
      final e = DateTime(range!.end.year, range!.end.month, range!.end.day);
      list = list.where((d) => !d.isBefore(s) && !d.isAfter(e)).toList();
    }
    list.sort();
    return [
      for (final d in list)
        DayTotals(
          date: d,
          timetacTotal: _timetacProductiveOn(d),
          meetingsTotal: _meetingsIntersectedWithTimetac(d),
          leftover: _timetacProductiveOn(d) - _meetingsIntersectedWithTimetac(d),
        )
    ];
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

// ✅ Commit-Datenstruktur mit extrahiertem Ticket
class _CT {
  _CT(this.at, this.ticket, this.projectId, this.msgFirstLine);
  DateTime at;
  String ticket;
  String projectId;
  String msgFirstLine;
}

class _HomePageState extends State<HomePage> {
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String _log = '';
  List<DraftLog> _drafts = [];

  // Ticket am Anfang erkennen – robust gegen Emojis/Prefix/Brackets.
// 1) führende Nicht-Alphanumerics wegschnippeln (z. B. „✨ “, „[“, „-“, etc.)
// 2) dann [PROJ-123] oder PROJ-123 matchen
  String? _leadingTicket(String msg) {
    if (msg.isEmpty) return null;
    if (msg.toLowerCase().startsWith('merge')) return null;

    final line = msg.split('\n').first.trimLeft();
    final cleaned = line.replaceFirst(RegExp(r'^[^\w\[]+'), '');

    // Case-insensitive, erlaubt [KEY-123], KEY-123, KEY-123: ...
    final reStart = RegExp(r'^\[?([A-Za-z][A-Za-z0-9]+-\d+)\]?:?', caseSensitive: false);
    final m = reStart.firstMatch(cleaned);
    if (m != null) return m.group(1)!.toUpperCase();

    // Fallback: irgendwo in der ersten Zeile
    final m2 = RegExp(r'([A-Za-z][A-Za-z0-9]+-\d+)', caseSensitive: false).firstMatch(line);
    return m2?.group(1)?.toUpperCase();
  }

  String _firstLine(String s) => s.split('\n').first.trim();

  // ⬇️ E-Mail-Liste aus Settings (komma/leerzeichen-getrennt); fallback auf Jira-E-Mail
  Set<String> _emailsFromSettings(SettingsModel s) {
    final raw = (s.gitlabAuthorEmail.trim().isEmpty ? s.jiraEmail : s.gitlabAuthorEmail).trim();
    final parts = raw.split(RegExp(r'[,\s]+')).map((e) => e.trim().toLowerCase()).where((e) => e.contains('@')).toSet();
    return parts;
  }

  // ⬇️ Striktes Post-Filtering: nur Commits, deren author_email ODER committer_email in [emails] ist
  List<GitlabCommit> _filterCommitsByEmails(List<GitlabCommit> commits, Set<String> emails) {
    if (emails.isEmpty) return commits;
    return commits.where((c) {
      final a = c.authorEmail?.toLowerCase();
      final ce = c.committerEmail?.toLowerCase();
      return (a != null && emails.contains(a)) || (ce != null && emails.contains(ce));
    }).toList();
  }

  // ✅ Aus allen geladenen Commits (state.gitlabCommits) eine sortierte Liste mit Ticket bauen
  List<_CT> _sortedCommitsWithTickets(List<GitlabCommit> commits) {
    final out = <_CT>[];
    for (final c in commits) {
      final t = _leadingTicket(c.message);
      if (t == null) continue;
      out.add(_CT(c.createdAt, t, c.projectId, _firstLine(c.message)));
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  // ✅ Logge alle „beachteten“ Commits pro Tag
  void _logCommitsForDay(DateTime day, List<_CT> ordered, void Function(String) log) {
    final ds = DateTime(day.year, day.month, day.day);
    final de = ds.add(const Duration(days: 1));
    final list = ordered.where((c) => !c.at.isBefore(ds) && c.at.isBefore(de)).toList();
    if (list.isEmpty) {
      log('  Commits: —\n');
      return;
    }
    log('  Commits:\n');
    for (final c in list) {
      log('    ${DateFormat('HH:mm').format(c.at)}  [${c.ticket}]  (Proj ${c.projectId})  ${c.msgFirstLine}\n');
    }
  }

  // ✅ Suche „letztes Ticket“ vor einem Zeitpunkt
  String? _lastTicketBefore(List<_CT> ordered, DateTime t) {
    int lo = 0, hi = ordered.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (ordered[mid].at.isAfter(t)) {
        hi = mid - 1;
      } else {
        idx = mid;
        lo = mid + 1;
      }
    }
    return idx >= 0 ? ordered[idx].ticket : null;
  }

  // ⬇️ Rest-Intervalle anhand Commit-Wechsel aufsplitten und mit Ticket versehen
  List<DraftLog> _assignRestPiecesByCommits({
    required List<WorkWindow> pieces,
    required List<_CT> ordered,
    required String note,
    required void Function(String) log,
  }) {
    final drafts = <DraftLog>[];

    for (final piece in pieces) {
      DateTime segStart = piece.start;
      final segEndTotal = piece.end;

      String? currentTicket = _lastTicketBefore(ordered, piece.start);
      if (currentTicket == null) {
        final next = ordered.firstWhere(
          (c) => !c.at.isBefore(piece.start),
          orElse: () => _CT(DateTime.fromMillisecondsSinceEpoch(0), '', '', ''),
        );
        if (next.ticket.isNotEmpty) {
          currentTicket = next.ticket;
          if (next.at.isAfter(segStart) && next.at.isBefore(segEndTotal)) {
            log('    ↳ Forward-Fill bis ${DateFormat('HH:mm').format(next.at)} mit [$currentTicket]\n');
          }
        }
      }

      if (currentTicket == null) {
        log('    ⚠ Keine passenden Commits – Rest ${DateFormat('HH:mm').format(piece.start)}–${DateFormat('HH:mm').format(piece.end)} wird ausgelassen\n');
        continue; // KEIN Fallback (dein Wunsch)
      }

      final inside = ordered.where((c) => c.at.isAfter(piece.start) && c.at.isBefore(piece.end)).toList();

      for (final c in inside) {
        if (c.ticket != currentTicket) {
          if (c.at.isAfter(segStart)) {
            drafts.add(DraftLog(start: segStart, end: c.at, issueKey: currentTicket!, note: note));
            log('    Rest ${DateFormat('HH:mm').format(segStart)}–${DateFormat('HH:mm').format(c.at)} → [$currentTicket] (Commit ${DateFormat('HH:mm').format(c.at)})\n');
          }
          currentTicket = c.ticket;
          segStart = c.at;
        }
      }

      if (segEndTotal.isAfter(segStart)) {
        drafts.add(DraftLog(start: segStart, end: segEndTotal, issueKey: currentTicket!, note: note));
        log('    Rest ${DateFormat('HH:mm').format(segStart)}–${DateFormat('HH:mm').format(segEndTotal)} → [$currentTicket]\n');
      }
    }

    return drafts;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Timetac + Outlook → Jira Worklogs'),
        actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () => _openSettings(context))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildInputs(context),
          const SizedBox(height: 12),
          _buildImportButtons(context),
          const SizedBox(height: 12),
          _buildRangePicker(context),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _calculate(context),
              icon: const Icon(Icons.calculate),
              label: const Text('Berechnen'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _busy || _drafts.isEmpty ? null : () => _bookToJira(context),
              icon: const Icon(Icons.send),
              label: const Text('Buchen (Jira)'),
            ),
          ]),
          const SizedBox(height: 12),
          if (state.totals.isNotEmpty) ...[
            Text('Vorschau Summen', style: Theme.of(context).textTheme.titleLarge),
            PreviewTable(days: state.totals),
          ],
          const SizedBox(height: 12),
          if (_drafts.isNotEmpty) _plannedList(context, _drafts),
          const SizedBox(height: 12),
          if (_log.isNotEmpty) _buildLogBox(),
        ]),
      ),
    );
  }

  Widget _plannedList(BuildContext context, List<DraftLog> drafts) {
    final byDay = <String, List<DraftLog>>{};
    for (final d in drafts) {
      final key = DateFormat('yyyy-MM-dd').format(d.start);
      (byDay[key] ??= []).add(d);
    }
    final dayKeys = byDay.keys.toList()..sort();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Geplante Worklogs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final day in dayKeys) ...[
            Text(day, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final w in byDay[day]!)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  '${w.issueKey}  ${_hhmm(w.start)}–${_hhmm(w.end)}  (${formatDuration(w.duration)})  ${w.note}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            const Divider(),
          ],
        ]),
      ),
    );
  }

  Widget _buildInputs(BuildContext context) {
    final s = context.read<AppState>().settings;
    final meetingController = TextEditingController(text: s.meetingIssueKey);
    final fallbackController = TextEditingController(text: s.fallbackIssueKey);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ticket-Zuordnung', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: meetingController,
                  decoration: const InputDecoration(labelText: 'Jira Ticket (Meetings, z. B. ABC-123)'),
                  onChanged: (v) => s.meetingIssueKey = v.trim(),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: fallbackController,
                  decoration: const InputDecoration(labelText: 'Jira Ticket (Fallback, z. B. ABC-999)'),
                  onChanged: (v) => s.fallbackIssueKey = v.trim(),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () async {
                if (_form.currentState!.validate()) {
                  await context.read<AppState>().savePrefs();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gespeichert.')));
                  }
                }
              },
              child: const Text('Speichern'),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildImportButtons(BuildContext context) {
    final state = context.watch<AppState>();
    String fmt(Duration d) => formatDuration(d);
    final ttSum = state.timetac.fold<Duration>(Duration.zero, (p, e) => p + e.duration);
    final evSum = state.totals.fold<Duration>(Duration.zero, (sum, day) => sum + day.meetingsTotal);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Datenquellen', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              onPressed: () async {
                final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
                if (res != null && res.files.single.path != null) {
                  final bytes = await File(res.files.single.path!).readAsBytes();
                  if (!context.mounted) return;
                  final s = context.read<AppState>().settings;
                  final parsed = TimetacCsvParser.parseWithConfig(bytes, s);
                  setState(() {
                    context.read<AppState>().timetac = parsed;
                    _drafts = [];
                    _log = 'CSV geladen: ${parsed.length} Zeilen\n';
                    final days = parsed.map((r) => r.date).toSet().toList()..sort();
                    if (days.isNotEmpty) {
                      _log += 'CSV-Tage: ${days.first} … ${days.last} (${days.length} Tage)\n';
                    }
                  });
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('CSV geladen: ${parsed.length} Zeilen')));
                }
              },
              icon: const Icon(Icons.table_chart),
              label: const Text('Timetac CSV laden'),
            ),
            const SizedBox(width: 12),
            Text(ttSum == Duration.zero ? '—' : 'Summe Timetac: ${fmt(ttSum)}'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(
              onPressed: () async {
                final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['ics']);
                if (res != null && res.files.single.path != null) {
                  final content = await File(res.files.single.path!).readAsString();
                  final parsed = parseIcs(content);
                  clearIcsDayCache();
                  setState(() {
                    context.read<AppState>().icsEvents = parsed.events;
                    _drafts = [];
                    _log += 'ICS geladen: ${parsed.events.length} Events\n';
                  });
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('ICS geladen: ${parsed.events.length} Events')));
                }
              },
              icon: const Icon(Icons.event),
              label: const Text('Outlook .ics laden'),
            ),
            const SizedBox(width: 12),
            Text(evSum == Duration.zero ? '—' : 'Meetings (gemergt) gesamt: ${fmt(evSum)}'),
          ]),
        ]),
      ),
    );
  }

  Widget _buildRangePicker(BuildContext context) {
    final state = context.watch<AppState>();
    final dates = {
      ...state.timetac.map((e) => e.date),
      ...state.icsEvents.map((e) => DateTime(e.start.year, e.start.month, e.start.day)),
    }.toList()
      ..sort();
    final minDate = dates.isNotEmpty ? dates.first : DateTime.now();
    final maxDate = dates.isNotEmpty ? dates.last : DateTime.now();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Datumsbereich', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.tonalIcon(
              onPressed: dates.isEmpty
                  ? null
                  : () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: minDate.subtract(const Duration(days: 365)),
                        lastDate: maxDate.add(const Duration(days: 365)),
                        initialDateRange: context.read<AppState>().range ?? DateTimeRange(start: minDate, end: maxDate),
                        helpText: 'Bitte Zeitraum wählen',
                      );
                      if (picked != null) {
                        setState(() {
                          context.read<AppState>().range = picked;
                          _drafts = [];
                          _log += 'Zeitraum: ${picked.start} – ${picked.end}\n';
                        });
                      }
                    },
              icon: const Icon(Icons.calendar_today),
              label: Text(context.watch<AppState>().range == null
                  ? 'Zeitraum wählen'
                  : '${DateFormat('dd.MM.yyyy').format(context.watch<AppState>().range!.start)} – ${DateFormat('dd.MM.yyyy').format(context.watch<AppState>().range!.end)}'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildLogBox() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: SelectableText(_log, style: const TextStyle(fontFamily: 'monospace')),
        ),
      );

  String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _openSettings(BuildContext context) async {
    final s = context.read<AppState>().settings;

    final tzCtl = TextEditingController(text: s.timezone);
    final baseCtl = TextEditingController(text: s.jiraBaseUrl);
    final mailCtl = TextEditingController(text: s.jiraEmail);
    final jiraTokCtl = TextEditingController(text: s.jiraApiToken);

    final delimCtl = TextEditingController(text: s.csvDelimiter);
    bool hasHeader = s.csvHasHeader;
    final descCtl = TextEditingController(text: s.csvColDescription);
    final dateCtl = TextEditingController(text: s.csvColDate);
    final startCtl = TextEditingController(text: s.csvColStart);
    final endCtl = TextEditingController(text: s.csvColEnd);
    final durCtl = TextEditingController(text: s.csvColDuration);
    final pauseTotalCtl = TextEditingController(text: s.csvColPauseTotal);
    final pauseRangesCtl = TextEditingController(text: s.csvColPauseRanges);

    // ✨ GitLab
    final glBaseCtl = TextEditingController(text: s.gitlabBaseUrl);
    final glTokCtl = TextEditingController(text: s.gitlabToken);
    final glProjCtl = TextEditingController(text: s.gitlabProjectIds);
    final glMailCtl = TextEditingController(text: s.gitlabAuthorEmail);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Einstellungen'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                  decoration: const InputDecoration(labelText: 'Timezone (z. B. Europe/Vienna)'), controller: tzCtl),
              const SizedBox(height: 16),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Jira REST', style: Theme.of(context).textTheme.titleSmall)),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'Jira Base URL (https://…atlassian.net)'),
                  controller: baseCtl),
              TextFormField(decoration: const InputDecoration(labelText: 'Jira E-Mail'), controller: mailCtl),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'Jira API Token'),
                  controller: jiraTokCtl,
                  obscureText: true),
              const SizedBox(height: 16),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('CSV (Timetac) – Importkonfiguration', style: Theme.of(context).textTheme.titleSmall)),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Delimiter (Standard: ;)'), controller: delimCtl)),
                const SizedBox(width: 12),
                Expanded(
                    child: Row(children: [
                  Checkbox(
                      value: hasHeader,
                      onChanged: (v) {
                        hasHeader = v ?? false;
                        (ctx as Element).markNeedsBuild();
                      }),
                  const Expanded(child: Text('Erste Zeile enthält Spaltennamen')),
                ])),
              ]),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        decoration:
                            const InputDecoration(labelText: 'Spalte: Beschreibung/Aktion  (Standard: Kommentar)'),
                        controller: descCtl)),
              ]),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Spalte: Datum (Standard: Datum)'),
                        controller: dateCtl)),
                const SizedBox(width: 12),
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Spalte: Beginn (Standard: K)'),
                        controller: startCtl)),
              ]),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Spalte: Ende (Standard: G)'),
                        controller: endCtl)),
                const SizedBox(width: 12),
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Spalte: Dauer  (Standard: GIBA)'),
                        controller: durCtl)),
              ]),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Spalte: Gesamtpause (Standard: P)'),
                        controller: pauseTotalCtl)),
                const SizedBox(width: 12),
                Expanded(
                    child: TextFormField(
                        decoration: const InputDecoration(labelText: 'Spalte: Pausen-Ranges (Standard: Pausen)'),
                        controller: pauseRangesCtl)),
              ]),
              const SizedBox(height: 16),
              Align(
                  alignment: Alignment.centerLeft,
                  child:
                      Text('GitLab (für Rest-Zeit Ticket-Automatik)', style: Theme.of(context).textTheme.titleSmall)),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'GitLab Base URL (https://gitlab.example.com)'),
                  controller: glBaseCtl),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'GitLab PRIVATE-TOKEN'),
                  controller: glTokCtl,
                  obscureText: true),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'GitLab Projekt-IDs (Komma/Leerzeichen getrennt)'),
                  controller: glProjCtl),
              TextFormField(
                  decoration: const InputDecoration(labelText: 'GitLab Author E-Mail (optional, Filter)'),
                  controller: glMailCtl),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
          FilledButton(
            onPressed: () async {
              final s = context.read<AppState>().settings;
              s.timezone = tzCtl.text.trim().isEmpty ? 'Europe/Vienna' : tzCtl.text.trim();
              s.jiraBaseUrl = baseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
              s.jiraEmail = mailCtl.text.trim();
              s.jiraApiToken = jiraTokCtl.text.trim();

              s.csvDelimiter = delimCtl.text.trim().isEmpty ? ';' : delimCtl.text.trim();
              s.csvHasHeader = hasHeader;
              s.csvColDescription = descCtl.text.trim();
              s.csvColDate = dateCtl.text.trim();
              s.csvColStart = startCtl.text.trim();
              s.csvColEnd = endCtl.text.trim();
              s.csvColDuration = durCtl.text.trim();
              s.csvColPauseTotal = pauseTotalCtl.text.trim();
              s.csvColPauseRanges = pauseRangesCtl.text.trim();

              s.gitlabBaseUrl = glBaseCtl.text.trim().replaceAll(RegExp(r'/+$'), '');
              s.gitlabToken = glTokCtl.text.trim();
              s.gitlabProjectIds = glProjCtl.text.trim();
              s.gitlabAuthorEmail = glMailCtl.text.trim();

              await context.read<AppState>().savePrefs();
              if (context.mounted) Navigator.pop(ctx);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

// Füge diese komplette Funktion in deine _HomePageState-Klasse ein
  Future<void> _calculate(BuildContext context) async {
    final state = context.read<AppState>();
    setState(() {
      _busy = true;
      _log += 'Berechne…\n';
      _drafts = [];
    });

    try {
      // --------- CSV-Tage & Zeitraum bestimmen ----------
      final csvDaysSet = state.timetac.map((t) => DateTime(t.date.year, t.date.month, t.date.day)).toSet();

      if (csvDaysSet.isEmpty) {
        _log += 'Hinweis: Keine CSV-Daten geladen.\n';
        setState(() {
          _busy = false;
        });
        return;
      }

      var csvDays = csvDaysSet.toList()..sort();
      DateTime rangeStart, rangeEnd;

      if (state.range != null) {
        rangeStart = DateTime(state.range!.start.year, state.range!.start.month, state.range!.start.day);
        rangeEnd = DateTime(state.range!.end.year, state.range!.end.month, state.range!.end.day);
        csvDays = csvDays.where((d) => !d.isBefore(rangeStart) && !d.isAfter(rangeEnd)).toList();
        _log +=
            'Zeitraum aktiv: ${DateFormat('yyyy-MM-dd').format(rangeStart)} – ${DateFormat('yyyy-MM-dd').format(rangeEnd)}\n';
      } else {
        rangeStart = csvDays.first;
        rangeEnd = csvDays.last;
      }

      _log += 'CSV-Tage erkannt: ${csvDaysSet.length} (im Zeitraum: ${csvDays.length})\n';

      // Wenn im Zeitraum keine CSV-Tage – abbrechen.
      if (csvDays.isEmpty) {
        _log += 'Hinweis: Im gewählten Zeitraum wurden keine CSV-Tage gefunden.\n';
        setState(() {
          _busy = false;
        });
        return;
      }

      // ------- GitLab laden (mit Lookback) & korrekt über alle Projekte mergen -------
      final s = state.settings;
      final lookbackStart = rangeStart.subtract(Duration(days: s.gitlabLookbackDays));
      final until = rangeEnd.add(const Duration(days: 1));
      final authorEmails = _emailsFromSettings(s);

      List<_CT> ordered = [];
      state.gitlabCommits = []; // clear cache

      if (s.gitlabBaseUrl.isNotEmpty && s.gitlabToken.isNotEmpty && s.gitlabProjectIds.isNotEmpty) {
        final api = GitlabApi(baseUrl: s.gitlabBaseUrl, token: s.gitlabToken);
        final ids =
            s.gitlabProjectIds.split(RegExp(r'[,\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

        // ⬇️ FIX: erst lokal sammeln, NICHT innerhalb der Schleife überschreiben
        final allFetched = <GitlabCommit>[];
        final perProject = <String, int>{};
        int totalFetched = 0;

        for (final id in ids) {
          final commits = await api.fetchCommits(
            projectId: id,
            since: lookbackStart,
            until: until,
            authorEmail: authorEmails.isNotEmpty ? authorEmails.first : null,
          );
          allFetched.addAll(commits); // <-- sammle für ALLE Projekte
          totalFetched += commits.length;
          perProject[id] = (perProject[id] ?? 0) + commits.length;
        }

        // jetzt EINMAL ins State schreiben und danach filtern
        state.gitlabCommits = allFetched;

        _log += 'GitLab-Commits geladen: $totalFetched\n';
        for (final id in ids) {
          _log += '  • Projekt $id: ${perProject[id] ?? 0}\n';
        }

        // striktes Post-Filter nach deinen E-Mails
        final before = state.gitlabCommits.length;
        final filtered = _filterCommitsByEmails(state.gitlabCommits, authorEmails);
        final after = filtered.length;
        _log += 'Commits nach Autor-Filter: $after (von $before) — Filter: '
            '${authorEmails.isEmpty ? '(leer → Jira-Mail verwendet)' : authorEmails.join(', ')}\n';

        ordered = _sortedCommitsWithTickets(filtered);
        _log += 'Commits mit Ticket-Präfix (nach Filter): ${ordered.length}\n';
      } else {
        _log += 'GitLab deaktiviert – kein Commit-basiertes Routing.\n';
      }

      // --------- Drafts je Tag bauen ----------
      final allDrafts = <DraftLog>[];

      for (final day in csvDays) {
        // Commit-Log pro Tag (nur die beachteten, also nach Filter & mit Ticket)
        if (ordered.isNotEmpty) {
          _logCommitsForDay(day, ordered, (s) => _log += s);
        } else {
          _log += '  Commits: —\n';
        }

        // Arbeitsfenster inkl. Pausenabzug
        final workWindows = state.workWindowsForDay(day);
        final productiveDur = workWindows.fold<Duration>(Duration.zero, (p, w) => p + w.duration);

        // Outlook ggf. ignorieren (Urlaub/0h)
        final rowsForDay = state.timetac
            .where((r) => r.date.year == day.year && r.date.month == day.month && r.date.day == day.day)
            .toList();
        final ignoreOutlook = productiveDur == Duration.zero ||
            rowsForDay.any((r) {
              final d = r.description.toLowerCase();
              return d.contains('urlaub') || d.contains('feiertag') || d.contains('krank') || d.contains('abwesen');
            });

        // Meetings aus ICS schneiden (nur wenn nicht ignoriert)
        final meetings = ignoreOutlook
            ? <WorkWindow>[]
            : buildDayCalendarCached(allEvents: state.icsEvents, day: day)
                .meetings
                .map((e) => WorkWindow(e.start, e.end))
                .toList();

        // Meeting-Drafts (auf Arbeitsfenster begrenzen)
        final meetingDrafts = <DraftLog>[];
        for (final m in meetings) {
          for (final w in workWindows) {
            final s1 = m.start.isAfter(w.start) ? m.start : w.start;
            final e1 = m.end.isBefore(w.end) ? m.end : w.end;
            if (e1.isAfter(s1)) {
              meetingDrafts.add(DraftLog(
                start: s1,
                end: e1,
                issueKey: state.settings.meetingIssueKey,
                note: 'Meeting ${DateFormat('HH:mm').format(s1)}–${DateFormat('HH:mm').format(e1)}',
              ));
            }
          }
        }

        // Rest = Arbeitsfenster minus Meetings
        final restPieces = <WorkWindow>[];
        for (final w in workWindows) {
          restPieces.addAll(subtractIntervals(w, meetings));
        }

        // Rest-Zuordnung: immer „letztes Ticket“ (über Tage), Splits an Commit-Wechseln
        final restDrafts = ordered.isEmpty
            // kein Fallback gewünscht → wenn keine Commits, dann keine Rest-Logs
            ? <DraftLog>[]
            : _assignRestPiecesByCommits(
                pieces: restPieces,
                ordered: ordered,
                note: 'Rest',
                log: (s) => _log += s,
              );

        final dayDrafts = <DraftLog>[
          ...meetingDrafts,
          ...restDrafts,
        ]..sort((a, b) => a.start.compareTo(b.start));

        allDrafts.addAll(dayDrafts);

        final meetingDur = meetingDrafts.fold<Duration>(Duration.zero, (p, d) => p + d.duration);
        final dayTicketCount =
            ordered.where((c) => c.at.year == day.year && c.at.month == day.month && c.at.day == day.day).length;

        _log += 'Tag ${DateFormat('yyyy-MM-dd').format(day)}: '
            'Timetac=${formatDuration(productiveDur)}, '
            'Meetings=${formatDuration(meetingDur)}, '
            '${ignoreOutlook ? 'Outlook ignoriert' : 'Outlook berücksichtigt'}, '
            '${ordered.isNotEmpty ? 'GitLab aktiv ($dayTicketCount/${ordered.length})' : 'GitLab aus'}\n';
      }

      setState(() {
        _drafts = allDrafts;
      });

      if (allDrafts.isEmpty) {
        _log += 'Hinweis: Keine Worklogs erzeugt. Prüfe CSV/ICS, Zeitraum und Commit-Filter.\n';
      }

      _log += 'Drafts: ${allDrafts.length}\n';
    } catch (e, st) {
      _log += 'EXCEPTION in Berechnung: $e\n$st\n';
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _bookToJira(BuildContext context) async {
    final state = context.read<AppState>();
    if (_drafts.isEmpty) {
      setState(() {
        _log += 'Keine Worklogs zu senden.\n';
      });
      return;
    }
    if (state.settings.jiraBaseUrl.isEmpty || state.settings.jiraEmail.isEmpty || state.settings.jiraApiToken.isEmpty) {
      setState(() {
        _log += 'FEHLER: Jira-Zugangsdaten fehlen.\n';
      });
      return;
    }

    setState(() {
      _busy = true;
      _log += 'Sende an Jira…\n';
    });

    try {
      final jira = JiraApi(
          baseUrl: state.settings.jiraBaseUrl, email: state.settings.jiraEmail, apiToken: state.settings.jiraApiToken);
      final worklogApi = JiraWorklogApi(
          baseUrl: state.settings.jiraBaseUrl, email: state.settings.jiraEmail, apiToken: state.settings.jiraApiToken);

      final keys = _drafts.map((d) => d.issueKey).toSet().toList();
      final keyToId = <String, String>{};
      for (final k in keys) {
        final id = await jira.resolveIssueId(k);
        if (id != null) {
          _log += 'Resolved $k → $id\n';
          keyToId[k] = id;
        } else {
          _log += 'WARN: Konnte IssueId für $k nicht auflösen – buche mit Key.\n';
        }
      }

      int ok = 0, fail = 0;
      for (final d in _drafts) {
        final keyOrId = keyToId[d.issueKey] ?? d.issueKey;
        final res = await worklogApi.createWorklog(
          issueKeyOrId: keyOrId,
          started: d.start,
          timeSpentSeconds: d.duration.inSeconds,
          comment: d.note,
        );
        if (res.ok) {
          ok++;
          _log += 'OK (Jira) ${d.issueKey} ${DateFormat('yyyy-MM-dd').format(d.start)} ${d.duration.inMinutes}m\n';
        } else {
          fail++;
          _log += 'FEHLER (Jira) ${d.issueKey} ${DateFormat('yyyy-MM-dd').format(d.start)}: ${res.body ?? ''}\n';
        }
      }

      _log += '\nFertig. Erfolgreich: $ok, Fehler: $fail\n';
      setState(() {});
    } catch (e, st) {
      setState(() {
        _log += 'EXCEPTION beim Senden: $e\n$st\n';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }
}
