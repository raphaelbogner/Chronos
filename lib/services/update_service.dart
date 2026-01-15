import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Information about an available update.
class UpdateInfo {
  final String latestVersion;
  final String currentVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool updateAvailable;

  UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.updateAvailable,
  });
}

/// Service to check for updates and download/install them.
class UpdateService extends ChangeNotifier {
  static const _repoOwner = 'raphaelbogner';
  static const _repoName = 'chronos';

  UpdateInfo? _updateInfo;
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _error;

  UpdateInfo? get updateInfo => _updateInfo;
  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get error => _error;

  String get currentVersion => _updateInfo?.currentVersion ?? '';

  /// Get the platform identifier for asset matching
  String get _platformIdentifier {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Check for updates by querying GitHub Releases API.
  Future<UpdateInfo?> checkForUpdates() async {
    if (_isChecking) return _updateInfo;

    _isChecking = true;
    _error = null;
    notifyListeners();

    try {
      // Get current app version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Query GitHub API for latest release
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode == 404) {
        // No releases yet
        _updateInfo = UpdateInfo(
          latestVersion: currentVersion,
          currentVersion: currentVersion,
          downloadUrl: '',
          releaseNotes: '',
          updateAvailable: false,
        );
        return _updateInfo;
      }

      if (response.statusCode != 200) {
        throw Exception('GitHub API error: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      final latestVersion = tagName.replaceFirst(RegExp(r'^v'), ''); // Remove 'v' prefix
      final releaseNotes = (data['body'] as String?) ?? '';

      // Find platform-specific asset
      String downloadUrl = '';
      final assets = data['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final name = (asset['name'] as String?)?.toLowerCase() ?? '';
        if (name.contains(_platformIdentifier)) {
          // Check for appropriate archive format
          if (Platform.isWindows && name.endsWith('.zip')) {
            downloadUrl = (asset['browser_download_url'] as String?) ?? '';
            break;
          } else if (Platform.isMacOS && name.endsWith('.zip')) {
            downloadUrl = (asset['browser_download_url'] as String?) ?? '';
            break;
          } else if (Platform.isLinux && (name.endsWith('.tar.gz') || name.endsWith('.zip'))) {
            downloadUrl = (asset['browser_download_url'] as String?) ?? '';
            break;
          }
        }
      }

      final updateAvailable = _isNewerVersion(latestVersion, currentVersion);

      _updateInfo = UpdateInfo(
        latestVersion: latestVersion,
        currentVersion: currentVersion,
        downloadUrl: downloadUrl,
        releaseNotes: releaseNotes,
        updateAvailable: updateAvailable,
      );

      return _updateInfo;
    } catch (e) {
      _error = e.toString();
      // Return a fallback with current version
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        _updateInfo = UpdateInfo(
          latestVersion: packageInfo.version,
          currentVersion: packageInfo.version,
          downloadUrl: '',
          releaseNotes: '',
          updateAvailable: false,
        );
      } catch (_) {
        // Ignore
      }
      return null;
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  /// Compare versions (semver-style). Returns true if latest > current.
  bool _isNewerVersion(String latest, String current) {
    final latestParts = latest.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final currentParts = current.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    // Pad to same length
    while (latestParts.length < 3) latestParts.add(0);
    while (currentParts.length < 3) currentParts.add(0);

    for (int i = 0; i < 3; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }
    return false;
  }

  /// Download and extract the update.
  /// Returns the path to the update script, or null on failure.
  Future<String?> downloadAndExtract() async {
    if (_updateInfo == null || !_updateInfo!.updateAvailable) return null;
    if (_updateInfo!.downloadUrl.isEmpty) {
      _error = 'Kein Download für ${_platformIdentifier.toUpperCase()} verfügbar';
      notifyListeners();
      return null;
    }

    _isDownloading = true;
    _downloadProgress = 0.0;
    _error = null;
    notifyListeners();

    try {
      // Download the archive file
      final request = http.Request('GET', Uri.parse(_updateInfo!.downloadUrl));
      final streamedResponse = await request.send();

      if (streamedResponse.statusCode != 200) {
        throw Exception('Download fehlgeschlagen: ${streamedResponse.statusCode}');
      }

      final contentLength = streamedResponse.contentLength ?? 0;
      final bytes = <int>[];
      int received = 0;

      await for (final chunk in streamedResponse.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          _downloadProgress = received / contentLength;
          notifyListeners();
        }
      }

      // Get the app's installation directory
      final exePath = Platform.resolvedExecutable;
      final appDir = Directory(exePath).parent;
      final pathSep = Platform.pathSeparator;
      
      // Create a temp directory for extraction
      final tempDir = Directory('${appDir.path}${pathSep}update_temp');
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create();

      // Extract the archive
      await _extractArchive(bytes, tempDir, _updateInfo!.downloadUrl);

      // Create platform-specific update script
      final scriptPath = await _createUpdateScript(appDir, tempDir, exePath);
      
      return scriptPath;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  /// Extract archive based on format
  Future<void> _extractArchive(List<int> bytes, Directory tempDir, String url) async {
    final pathSep = Platform.pathSeparator;
    
    if (url.endsWith('.tar.gz')) {
      // Extract tar.gz (Linux)
      final gzData = GZipDecoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(gzData);
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outFile = File('${tempDir.path}$pathSep$filename');
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }
    } else {
      // Extract ZIP (Windows, macOS)
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outFile = File('${tempDir.path}$pathSep$filename');
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }
    }
  }

  /// Create platform-specific update script
  Future<String> _createUpdateScript(Directory appDir, Directory tempDir, String exePath) async {
    final pathSep = Platform.pathSeparator;
    
    if (Platform.isWindows) {
      final updateScript = File('${appDir.path}${pathSep}update.bat');
      final scriptContent = '''
@echo off
echo Warte auf Beendigung der alten Version...
timeout /t 2 /nobreak > nul
echo Installiere Update...
xcopy /s /y "${tempDir.path}${pathSep}*" "${appDir.path}${pathSep}" > nul
echo Starte neue Version...
start "" "$exePath"
echo Raeume auf...
rmdir /s /q "${tempDir.path}"
del "%~f0"
''';
      await updateScript.writeAsString(scriptContent);
      return updateScript.path;
    } else if (Platform.isMacOS) {
      final updateScript = File('${appDir.path}${pathSep}update.sh');
      final scriptContent = '''
#!/bin/bash
echo "Warte auf Beendigung der alten Version..."
sleep 2
echo "Installiere Update..."
cp -R "${tempDir.path}/"* "${appDir.path}/"
chmod +x "$exePath"
echo "Starte neue Version..."
open "$exePath"
echo "Räume auf..."
rm -rf "${tempDir.path}"
rm -- "\$0"
''';
      await updateScript.writeAsString(scriptContent);
      // Make script executable
      await Process.run('chmod', ['+x', updateScript.path]);
      return updateScript.path;
    } else if (Platform.isLinux) {
      final updateScript = File('${appDir.path}${pathSep}update.sh');
      final scriptContent = '''
#!/bin/bash
echo "Warte auf Beendigung der alten Version..."
sleep 2
echo "Installiere Update..."
cp -R "${tempDir.path}/"* "${appDir.path}/"
chmod +x "$exePath"
echo "Starte neue Version..."
"$exePath" &
echo "Räume auf..."
rm -rf "${tempDir.path}"
rm -- "\$0"
''';
      await updateScript.writeAsString(scriptContent);
      // Make script executable
      await Process.run('chmod', ['+x', updateScript.path]);
      return updateScript.path;
    }
    
    throw Exception('Nicht unterstützte Plattform');
  }

  /// Execute the update script (this will close the app).
  Future<void> executeUpdate(String scriptPath) async {
    if (Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', scriptPath],
        mode: ProcessStartMode.detached,
      );
    } else {
      // macOS and Linux use bash
      await Process.start(
        '/bin/bash',
        [scriptPath],
        mode: ProcessStartMode.detached,
      );
    }
  }
}
