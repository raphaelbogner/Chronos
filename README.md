# CHRONOS

Ein kompaktes Flutter-Tool, das **Arbeitszeiten aus Timetac (CSV)** mit **Outlook-Terminen (.ics)** und **GitLab-Commits** zusammenführt und daraus **Jira-Worklogs** erzeugt – exakt gesplittet nach Meetings, Pausen, Arztterminen und optional per Commit erkannten Tickets.

---

## Features

### Datenimport

- **CSV-Import (Timetac)**
  - Spalten frei konfigurierbar (Beginn, Ende, Dauer, Pausen gesamt & Einzelintervalle)
  - Ganztägige Homeoffice-Standardblöcke werden ignoriert – es zählen die echten „Kommen/Gehen"-Buchungen
  - Wochenenden ohne Arbeit/Abwesenheit werden in der Vorschau ausgeblendet

- **Outlook-Import (.ics)**
  - Berücksichtigt nur **aktive Meetings**: nicht „CANCELLED", nicht „FREE/TENTATIVE/OOF", mit Teilnehmern
  - Eigener Teilnahme-Status muss **ACCEPTED** oder **NEEDS-ACTION** sein
  - All-day „Urlaub/Feiertag/Krank/Abwesend" → Outlook wird für diesen Tag ignoriert
  - Meetings > 10 h oder über Mitternacht → ignoriert
  - Überlappungen werden nur bei **echter Überlappung** gemerged
  - Meeting-Titel erscheint in geplanten Worklogs: `Meeting – <Summary>`

- **GitLab-Commit-Routing (optional)**
  - Liest Commits aus mehreren Projekten per **Personal Access Token**
  - Filtert auf Author/Committer-E-Mail(s)
  - Erkanntes Ticketpräfix am **Beginn** der Commit-Message: `KEY-123` oder `[KEY-123]`
  - **Restzeit** (Arbeitszeit minus Meetings) wird über Commit-Wechsel chronologisch gesplittet

### Worklog-Generierung

- **Zwei-Button-Flow**: **Berechnen** → Vorschau → **Buchen (Jira)**
- **Meeting-Ticket** und **Fallback-Ticket** definierbar
- **Ticket-Picker** in der Worklog-Vorschau: Ticket pro Zeile wechseln via Suche nach Key oder Titel
- **Bezahlte Nichtarbeitszeit** (Arzttermine) wird erkannt und als Info angezeigt, aber nicht gebucht
- Ganztägige bezahlte Nichtarbeitszeit wird automatisch ausgeblendet

### Delta-Modus

- **Intelligente Duplikaterkennung**: Vergleicht geplante Worklogs mit bereits vorhandenen Jira-Einträgen
- **Überlappungserkennung**: Markiert Worklogs, die zeitlich mit existierenden Einträgen kollidieren
- **Visuelle Kennzeichnung**:
  - 🟢 Grün = Neuer Worklog (wird gebucht)
  - 🟡 Gelb = Überlappung mit bestehendem Eintrag
  - 🔴 Rot = Duplikat (bereits vorhanden)
- **Schutz vor Doppelbuchungen**: Duplikate und Überlappungen werden beim Buchen automatisch übersprungen

### Meeting-Regeln

- **Automatische Ticket-Zuweisung** basierend auf Meeting-Titel
- Regeln in den Settings konfigurierbar: `Pattern → Ticket-Key`
- Beispiel: `Daily` → `SCRUM-1`, `1:1` → `MGMT-5`
- Pattern-Matching ist case-insensitive

### Titel-Ersetzungsregeln

- **Dynamische Meeting-Titel-Ersetzung** für wiederkehrende Meetings
- Trigger-Wort und mögliche Ersetzungen konfigurierbar
- Originaltitel bleibt für Referenz erhalten

### Worklog-Verwaltung

- **Worklogs löschen**: Kalenderansicht zum gezielten Löschen von Jira-Worklogs
  - Monatsnavigation mit Picker
  - Farbige Markierung: Tage mit Worklogs und ausgewählte Tage
  - Bulk-Delete für ausgewählte Zeiträume
  - Bestätigungsdialog mit Zusammenfassung

### Zeitvergleich

- **Timetac ↔ Jira Abgleich**: Vergleicht gebuchte Jira-Zeiten mit Timetac-Daten
- Erkennt Differenzen bei:
  - Arbeitsbeginn / Arbeitsende
  - Pausenzeiten
  - Netto-Arbeitszeit
- **Automatische Anpassungsvorschläge** für Jira-Worklogs

### Settings

- **Import/Export**: Einstellungen als JSON sichern und wiederherstellen
- **Tabs**: Jira, Timetac, GitLab, Meeting-Regeln, Titel-Ersetzung
- **Live-Status-Icons** pro Tab zeigen Verbindungsstatus

---

## Installation

### Voraussetzungen
- Flutter ≥ 3.19 (stable)
- Dart ≥ 3.x
- macOS/Windows/Linux mit Git
- (Windows) Visual Studio Build Tools für Desktop-Build

```bash
flutter --version
git clone <dein-repo>
cd TimetacOutlookToJira
flutter pub get
flutter run -d windows   # oder macos / linux
```

> **Hinweis (Windows):** `PathExistsException … .plugin_symlinks/file_picker` ⇒ `flutter clean` oder Ordner `windows/flutter/ephemeral/.plugin_symlinks` löschen, dann `flutter pub get`.

---

## Quick Start

1. **CSV laden** → „Timetac CSV laden"  
2. **ICS laden** → „Outlook .ics laden"  
3. **Zeitraum wählen**  
4. In **Einstellungen** Meeting- & Fallback-Ticket setzen und speichern  
5. **Berechnen** → Vorschau prüfen  
6. Optional: **Ticket-Picker** benutzen, um Tickets pro Zeile zu ändern  
7. **Buchen (Jira)**

---

## Anleitungen

### Timetac CSV-Datei bekommen

1. Öffne Timetac  
2. Wechsle zum Tab **„Stundenabrechnung"**  
3. Gib **Start- und Enddatum** ein für den gewünschten Zeitraum  
4. Klicke auf **„Aktualisieren"**  
5. Klicke rechts auf **„Exportieren als CSV-Datei"**  
6. Im Dialog auf **„Herunterladen"** klicken  
7. CSV-Datei in der App importieren

### Outlook ICS-Datei bekommen (Outlook Classic)

**Wichtig: Outlook Classic verwenden.**

1. Outlook (**Classic**) öffnen  
2. Links auf den **Kalender**-Tab wechseln  
3. Oben auf **„Datei"** klicken  
4. Links **„Kalender speichern"** auswählen  
5. Unten auf **„Weitere Optionen"** klicken  
6. Bei **Datumsbereich** „Datum angeben…" auswählen  
7. Bei **Detail** „Alle Details" auswählen  
8. Bei **Erweitert** „>> Einblenden" klicken  
9. **„Details von als privat markierten Elementen einschließen"** aktivieren  
10. Mit **„OK"** bestätigen und Datei speichern  
11. ICS-Datei in der App importieren

---

## Einstellungen

### Jira
- **Base URL**: `https://<tenant>.atlassian.net` (ohne Slash am Ende)
- **E-Mail**, **API Token** (Link zum Token-Portal in Settings)
- **Meeting-Ticket** und **Fallback-Ticket**

### Timetac (CSV)
- **Delimiter** (`;`), **Header vorhanden** ✓/✗
- Spalten: Beschreibung, Datum, Beginn, Ende, Dauer, Gesamtpause, Pausen-Ranges
- **Nicht-Meeting-Hinweise**: Editierbare Liste (homeoffice, focus, reise, etc.)

### GitLab (optional)
- **Base URL**, **PRIVATE-TOKEN**
- **Projekt-IDs** (Komma/Whitespace getrennt)
- **Author E-Mail**(s) zum Filtern

### Meeting-Regeln
- Pattern-basierte Ticket-Zuweisung für Meetings
- Mehrere Regeln möglich, erste Treffer gewinnt

### Titel-Ersetzung
- Trigger-Wörter mit alternativen Ersetzungen
- Auswahl bei der Berechnung

---

## Bedienlogik im Detail

1. **Arbeitsfenster** je Tag aus CSV, Nichtleistung und Pausen werden abgezogen
2. **Meetings** aus ICS werden gefiltert und in die Arbeitsfenster geschnitten → Meeting-Drafts
3. **Arzttermine** aus BNA (sofern kein KT/FT/UT/ZA) werden wie Pausen behandelt
4. **Reststücke** werden mit GitLab-Commits pro Ticket segmentiert
5. **Delta-Modus** vergleicht mit bestehenden Jira-Worklogs und markiert Duplikate/Überlappungen
6. **Ticket-Picker** kann das Ticket eines Drafts überschreiben

---

## Datenschutz

- CSV/ICS/Commits/Summaries bleiben **lokal**
- Für Jira-Buchung werden nur notwendige Felder übertragen
- GitLab/Jira-Tokens liegen lokal (SharedPreferences)

---

## Entwicklung

### Tests ausführen

```bash
flutter test
```

Die Test-Suite umfasst:
- **Models**: TimeRange, TimetacRow, SettingsModel, MeetingRule
- **CSV-Parser**: Delimiter, Datumsformate, Quoted Fields
- **ICS-Parser**: RRULE-Expansion, EXDATE, Filterung
- **TimeComparisonService**: Zeitvergleich, Toleranzen
- **JiraAdjustmentService**: Worklog-Anpassungen, Pausen-Splitting

### Build & Release

```bash
# Windows
flutter build windows

# macOS
flutter build macos

# Linux
flutter build linux
```

Artefakt liegt unter `build/<platform>/…`.

---

## Lizenz

Privat, zur internen Verwendung
