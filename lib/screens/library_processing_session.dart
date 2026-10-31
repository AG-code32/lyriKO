import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/lyriko_server_client.dart';
import '../services/synced_lyrics_service.dart';

/// Session-scoped execution, durable local review notes and nonblocking
/// acoustic publication. Windows-side persisted jobs require server support.
class LibraryProcessingSession extends ChangeNotifier {
  LibraryProcessingSession._();
  static final LibraryProcessingSession instance = LibraryProcessingSession._();

  bool running = false;
  bool acousticRunning = false;
  String acousticPhase = '';
  String? acousticError;
  int completed = 0;
  int total = 0;
  int succeeded = 0;
  String currentTitle = '';
  String phase = '';
  final Map<String, String> failures = <String, String>{};
  final Set<String> inFlight = <String>{};
  final Set<String> completedIds = <String>{};
  String? lastError;
  Future<void>? _acousticTask;
  Future<void>? _restoreTask;
  Future<void> _pendingWrite = Future<void>.value();

  void _notify() => notifyListeners();

  Future<File> _reviewFile() async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory('${dir.path}/LyriKO');
    await folder.create(recursive: true);
    return File('${folder.path}/library_review_v1.json');
  }

  Future<void> restore() => _restoreTask ??= _readReview();

  Future<void> _readReview() async {
    try {
      final file = await _reviewFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final id = entry.key.toString();
        if (id.isNotEmpty) failures.putIfAbsent(id, () => entry.value.toString());
      }
      _notify();
    } catch (e) {
      lastError = 'Unable to load saved review notes: $e';
      _notify();
    }
  }

  void _saveReview() {
    final snapshot = Map<String, String>.from(failures);
    _pendingWrite = _pendingWrite.catchError((Object _) {}).then((_) async {
      try {
        final file = await _reviewFile();
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(jsonEncode(snapshot), flush: true);
        if (await file.exists()) await file.delete();
        await temp.rename(file.path);
      } catch (e) {
        lastError = 'Could not save review notes: $e';
        _notify();
      }
    });
  }

  /// Remove mistaken Review classifications without modifying server data.
  void returnFailuresToPending(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      if (failures.remove(id) != null) changed = true;
    }
    if (changed) {
      _saveReview();
      _notify();
    }
  }

  void resolveFailure(String id) {
    if (failures.remove(id) != null) {
      _saveReview();
      _notify();
    }
  }

  Future<void> start({
    required List<String> ids,
    required List<Map<String, dynamic>> imports,
    required Future<void> Function() reloadLibrary,
    required List<SyncedLyricsSong> Function() currentSongs,
  }) async {
    await restore();
    if (running || ids.isEmpty) return;
    running = true;
    completed = 0;
    total = ids.length;
    succeeded = 0;
    currentTitle = '';
    phase = 'Preparing';
    lastError = null;
    completedIds.clear();
    inFlight..clear()..addAll(ids);
    _notify();

    final server = LyrikoServerClient();
    final rows = <String, Map<String, dynamic>>{
      for (final row in imports) (row['id'] ?? '').toString(): row,
    };
    final processed = <String>[];
    try {
      for (final id in ids) {
        final row = rows[id];
        currentTitle = (row?['title'] ?? id).toString();
        phase = 'Finding synchronized lyrics';
        _notify();
        try {
          if (row == null) throw StateError('Track not found in the imported index');
          if (row['lyricsReady'] != true) {
            final title = (row['title'] ?? '').toString()
                .replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._ ]+\s*'), '').trim();
            var artist = (row['artist'] ?? '').toString().trim();
            if (artist.isEmpty || RegExp(r'^\d{1,3}$').hasMatch(artist)) {
              phase = 'Resolving artist';
              _notify();
              final suggestion = await server.importedMetadataSuggestion(id);
              artist = (suggestion['artist'] ?? '').toString().trim();
            }
            if (title.isEmpty || artist.isEmpty || RegExp(r'^\d{1,3}$').hasMatch(artist)) {
              throw StateError('Artist or title unresolved. Use SET ARTIST before retrying.');
            }
            await server.updateImportedMetadata(id, title, artist);
            phase = 'Finding synchronized lyrics';
            _notify();
            final preview = await server.previewImportedLyrics(id);
            final providerId = (preview['providerId'] as num?)?.toInt();
            if (providerId == null || (preview['lineCount'] as num? ?? 0) < 2) {
              throw StateError('No reliable synchronized lyrics found');
            }
            phase = 'Saving lyrics';
            _notify();
            await server.approveImportedLyrics(id, providerId);
          }
          processed.add(id);
          completedIds.add(id);
          failures.remove(id);
          succeeded++;
          _saveReview();
        } catch (error) {
          failures[id] = error.toString();
          _saveReview();
        } finally {
          completed++;
          inFlight.remove(id);
          _notify();
        }
      }
      if (processed.isNotEmpty) {
        phase = 'Updating song library';
        currentTitle = '';
        _notify();
        await reloadLibrary();
        if (defaultTargetPlatform == TargetPlatform.macOS) {
          // Do not make Music Library wait for a full catalog rebuild.
          // The existing native code may rebuild all references; this change
          // separates that latency, rather than claiming incremental signatures.
          unawaited(_publishAcoustic(server, processed, currentSongs));
        }
      }
      phase = 'Lyrics finished';
    } catch (error) {
      lastError = error.toString();
      phase = 'Attention required';
    } finally {
      currentTitle = '';
      running = false;
      _notify();
    }
  }

  Future<void> _publishAcoustic(
    LyrikoServerClient server,
    List<String> processed,
    List<SyncedLyricsSong> Function() currentSongs,
  ) async {
    if (_acousticTask != null) {
      // Do not overlap native publications. A later batch should re-check
      // the catalog after this task completes.
      await _acousticTask;
    }
    Future<void> task() async {
      acousticRunning = true;
      acousticPhase = 'Publishing acoustic catalog';
      acousticError = null;
      _notify();
      try {
        final url = await server.getBaseUrl();
        final token = await server.getAuthToken();
        if (url.isEmpty || token.isEmpty) {
          throw StateError('Server URL or token missing for catalog publication');
        }
        const channel = MethodChannel('lyriko/macos_audio_recognition');
        final response = await channel.invokeMapMethod<String, dynamic>(
          'refreshCatalog', {'serverUrl': url, 'token': token});
        final count = (response?['referenceCount'] as num?)?.toInt();
        if (response?['updated'] != true || count == null || count < currentSongs().length) {
          throw StateError('Acoustic catalog publication not confirmed');
        }
        await server.acknowledgeImportedAudio(processed);
        acousticPhase = 'Acoustic catalog updated ($count references)';
      } catch (e) {
        acousticError = e.toString();
        acousticPhase = 'Acoustic publication failed';
      } finally {
        acousticRunning = false;
        _notify();
      }
    }
    final future = task();
    _acousticTask = future;
    try {
      await future;
    } finally {
      if (identical(_acousticTask, future)) _acousticTask = null;
    }
  }
}
