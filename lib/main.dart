// lib/main.dart
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

  static bool _isCsvAbsence(String desc) {
    final d = desc.toLowerCase();
    return d.contains('urlaub') || d.contains('feiertag') || d.contains('krank') || d.contains('abwesen');
  }

  static bool _isCsvNonProductive(String desc) {
    final d = desc.toLowerCase();
    return d.contains('pause') || d.contains('arzt') || d.contains('nichtleistung') || d.contains('nicht-leistung');
  }

  List<WorkWindow> workWindowsForDay(DateTime d) {
    final rows = timetac.where((r) => r.date.year == d.year && r.date.month == d.month && r.date.day == d.day);

    // 1) Rohfenster aufbauen (ohne Abwesenheiten, ohne Default-Homeoffice, ohne Nichtleistung)
    final raw = <WorkWindow>[];
    for (final r in rows) {
      if (_isCsvAbsence(r.description)) continue;
      if (_isCsvNonProductive(r.description)) continue; // explizite "Pause"/"Arzt"-Zeilen
      if (_isDefaultHomeofficeBlock(r)) continue;
      if (r.start != null && r.end != null) raw.add(WorkWindow(r.start!, r.end!));
    }

    if (raw.isEmpty) return raw;

    // 2) Alle Pausenintervalle sammeln (aus Spalte "Pausen")
    final pauses = <WorkWindow>[];
    for (final r in rows) {
      for (final pr in r.pauses) {
        pauses.add(WorkWindow(pr.start, pr.end));
      }
    }

    // 3) Pausen von Arbeitsfenstern abziehen
    if (pauses.isEmpty) return raw;
    final cut = <WorkWindow>[];
    for (final w in raw) {
      cut.addAll(subtractIntervals(w, pauses));
    }
    return cut;
  }

  static bool _isDefaultHomeofficeBlock(TimetacRow r) {
    if (!r.description.toLowerCase().contains('homeoffice')) return false;
    if (r.start == null || r.end == null) return false;
    final mins = r.end!.difference(r.start!).inMinutes;
    return mins >= 420 && mins <= 540; // ~7–9h window for whole-day homeoffice placeholders
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

class _HomePageState extends State<HomePage> {
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String _log = '';
  List<DraftLog> _drafts = [];

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
                  onChanged: (v) {
                    s.meetingIssueKey = v.trim();
                  },
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: fallbackController,
                  decoration: const InputDecoration(labelText: 'Jira Ticket (Rest/Fallback, z. B. ABC-999)'),
                  onChanged: (v) {
                    s.fallbackIssueKey = v.trim();
                  },
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Pflichtfeld' : null,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () async {
                if (_form.currentState!.validate()) {
                  await context.read<AppState>().savePrefs();
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gespeichert.')));
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
                  if (!mounted) return;
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
                    state.icsEvents = parsed.events;
                    _drafts = [];
                    _log += 'ICS geladen: ${parsed.events.length} Events\n';
                  });
                  if (!mounted) return;
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

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Einstellungen'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Allgemein
                TextFormField(
                    decoration: const InputDecoration(labelText: 'Timezone (z. B. Europe/Vienna)'), controller: tzCtl),
                const SizedBox(height: 16),

                // Jira
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
                          decoration: const InputDecoration(labelText: 'Delimiter (z. B. ;)'), controller: delimCtl)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(children: [
                      Checkbox(
                        value: hasHeader,
                        onChanged: (v) {
                          hasHeader = v ?? false;
                          (ctx as Element).markNeedsBuild();
                        },
                      ),
                      const Expanded(child: Text('Erste Zeile enthält Spaltennamen')),
                    ]),
                  ),
                ]),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Beschreibung/Aktion (optional)'),
                          controller: descCtl)),
                ]),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Datum'), controller: dateCtl)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Beginn'), controller: startCtl)),
                ]),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Ende'), controller: endCtl)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Dauer (optional)'),
                          controller: durCtl)),
                ]),
                Row(children: [
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Gesamtpause (optional, z. B. "P")'),
                          controller: pauseTotalCtl)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextFormField(
                          decoration: const InputDecoration(labelText: 'Spalte: Pausen-Ranges (z. B. "Pausen")'),
                          controller: pauseRangesCtl)),
                ]),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Beispiel für Ranges: 8:40-9:01; 11:06-13:40',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
          FilledButton(
            onPressed: () async {
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

              // ➕ speichern
              s.csvColPauseTotal = pauseTotalCtl.text.trim();
              s.csvColPauseRanges = pauseRangesCtl.text.trim();

              await context.read<AppState>().savePrefs();
              if (context.mounted) Navigator.pop(ctx);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  Future<void> _calculate(BuildContext context) async {
    final state = context.read<AppState>();
    setState(() {
      _busy = true;
      _log += 'Berechne…\n';
      _drafts = [];
    });

    try {
      if (state.range == null) {
        _log += 'Hinweis: Kein Zeitraum gewählt.\n';
      }
      final csvDaysSet = state.timetac.map((t) => DateTime(t.date.year, t.date.month, t.date.day)).toSet();
      var csvDays = csvDaysSet.toList()..sort();
      if (state.range != null) {
        final rs = DateTime(state.range!.start.year, state.range!.start.month, state.range!.start.day);
        final re = DateTime(state.range!.end.year, state.range!.end.month, state.range!.end.day);
        csvDays = csvDays.where((d) => !d.isBefore(rs) && !d.isAfter(re)).toList();
        _log += 'Zeitraum aktiv: ${DateFormat('yyyy-MM-dd').format(rs)} – ${DateFormat('yyyy-MM-dd').format(re)}\n';
      }
      _log += 'CSV-Tage erkannt: ${csvDaysSet.length} (im Zeitraum: ${csvDays.length})\n';

      final drafts = <DraftLog>[];

      for (final day in csvDays) {
        final rows = state.timetac
            .where((r) => r.date.year == day.year && r.date.month == day.month && r.date.day == day.day)
            .toList();

        for (final r in rows) {
          if (r.pauses.isNotEmpty) {
            for (final p in r.pauses) {
              _log +=
                  '  Pause ${DateFormat('HH:mm').format(p.start)}–${DateFormat('HH:mm').format(p.end)} (${p.duration.inMinutes}m)\n';
            }
          }
        }

        final workWindows = context.read<AppState>().workWindowsForDay(day);
        final productiveDur = workWindows.fold<Duration>(Duration.zero, (p, w) => p + w.duration);

        final ignoreOutlook = productiveDur == Duration.zero ||
            rows.any((r) =>
                r.description.toLowerCase().contains('urlaub') ||
                r.description.toLowerCase().contains('feiertag') ||
                r.description.toLowerCase().contains('krank') ||
                r.description.toLowerCase().contains('abwesen'));

        final dayCal = ignoreOutlook ? null : buildDayCalendarCached(allEvents: state.icsEvents, day: day);
        if (dayCal != null) {
          for (final m in dayCal.meetings) {
            _log +=
                '  • Mtg ${DateFormat('HH:mm').format(m.start)}–${DateFormat('HH:mm').format(m.end)} (${m.duration.inMinutes}m) "${(m.summary).trim()}"\n';
          }
        }

        final meetings =
            ignoreOutlook ? <WorkWindow>[] : dayCal!.meetings.map((e) => WorkWindow(e.start, e.end)).toList();

        final dayDrafts = buildDraftsForDay(
          day: day,
          workWindows: workWindows,
          meetings: meetings,
          meetingIssueKey: state.settings.meetingIssueKey,
          fallbackIssueKey: state.settings.fallbackIssueKey,
          meetingNotePrefix: 'Meeting',
          fallbackNote: 'Rest',
        );
        drafts.addAll(dayDrafts);

        final meetingDur = dayDrafts
            .where((d) => d.issueKey == state.settings.meetingIssueKey)
            .fold<Duration>(Duration.zero, (p, d) => p + d.duration);

        _log +=
            'Tag ${DateFormat('yyyy-MM-dd').format(day)}: Timetac=${formatDuration(productiveDur)}, Meetings=${formatDuration(meetingDur)}, ${ignoreOutlook ? 'Outlook ignoriert' : 'Outlook berücksichtigt'}\n';
      }

      setState(() {
        _drafts = drafts;
      });
      if (drafts.isEmpty) _log += 'Hinweis: Keine Worklogs erzeugt. Prüfe CSV/ICS und Zeitraum.\n';
      _log += 'Drafts: ${drafts.length}\n';
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
