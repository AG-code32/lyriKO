import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/synced_lyrics_service.dart';
import '../services/lyriko_server_client.dart';

/// Library presentation only. Song operations remain owned by HomeScreen,
/// preserving existing editor, preview, deletion and recognition behavior.
class MusicLibraryScreen extends StatefulWidget {
  const MusicLibraryScreen({
    super.key,
    required this.songs,
    required this.songsListenable,
    required this.loadingListenable,
    required this.remoteLibraryMode,
    required this.onAddSong,
    required this.onPreview,
    required this.onEdit,
    required this.onDelete,
    required this.onReload,
    required this.currentSongs,
  });

  final List<SyncedLyricsSong> songs;
  final ValueListenable<List<SyncedLyricsSong>> songsListenable;
  final ValueListenable<bool> loadingListenable;
  final bool remoteLibraryMode;
  final Future<void> Function() onAddSong;
  final Future<void> Function(SyncedLyricsSong) onPreview;
  final Future<void> Function(SyncedLyricsSong) onEdit;
  final Future<void> Function(SyncedLyricsSong) onDelete;
  final Future<void> Function() onReload;
  final List<SyncedLyricsSong> Function() currentSongs;

  @override
  State<MusicLibraryScreen> createState() => _MusicLibraryScreenState();
}

class _MusicLibraryScreenState extends State<MusicLibraryScreen> {
  String _query = '';
  bool _busy = false;
  late List<SyncedLyricsSong> _songs;
  final LyrikoServerClient _server = LyrikoServerClient();
  List<Map<String, dynamic>> _imports = [];
  bool _loadingImports = false;
  String? _importError;
  List<Map<String, dynamic>> _newArrivals = [];
  final Set<String> _selectedImports = {};
  bool _processingBatch = false;
  int _batchCompleted = 0;
  int _batchTotal = 0;
  final List<String> _batchFailures = [];


  @override
  void initState() {
    super.initState();
    _songs = widget.songs;
    widget.songsListenable.addListener(_syncSongs);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _reloadImports();
      _loadInbox();
    }
  }

  void _syncSongs() {
    if (mounted) setState(() => _songs = widget.songsListenable.value);
  }

  @override
  void dispose() {
    widget.songsListenable.removeListener(_syncSongs);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
      if (mounted) setState(() => _songs = widget.currentSongs());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reloadImports() async {
    if (_loadingImports) return;
    setState(() => _loadingImports = true);
    try {
      final result = await _server.importedAudio();
      final songs = result['songs'];
      if (mounted) setState(() {
        _imports = songs is List
            ? songs.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : [];
        _importError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _importError = error.toString());
    } finally {
      if (mounted) setState(() => _loadingImports = false);
    }
  }

  Future<void> _loadInbox() async {
    try {
      final rows = await _server.newImportedAudio();
      if (!mounted) return;
      setState(() {
        _newArrivals = rows;
        _selectedImports.retainAll(rows.map((e) => e['id'].toString()).toSet());
      });
    } catch (error) {
      debugPrint('New imports inbox unavailable: $error');
    }
  }

  Future<void> _dismissSelected() async {
    if (_selectedImports.isEmpty) return;
    final ids = _selectedImports.toList();
    try {
      await _server.acknowledgeImportedAudio(ids, dismiss: true);
      _selectedImports.clear();
      await _loadInbox();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _lookupBatch() async {
    if (_selectedImports.isEmpty || _processingBatch) return;
    final ids = _selectedImports.toList();
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Find lyrics for ${ids.length} songs?'),
      content: const Text('Only matching synchronized lyrics will be saved. Failed or ambiguous tracks remain pending. Please verify each recording later in Preview.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('START')),
      ],
    ));
    if (confirm != true || !mounted) return;
    setState(() { _processingBatch = true; _batchCompleted = 0; _batchTotal = ids.length; _batchFailures.clear(); });
    final processed = <String>[];
    for (final id in ids) {
      if (!mounted) break;
      try {
        final song = _imports.firstWhere((e) => e['id'].toString() == id,
          orElse: () => _newArrivals.firstWhere((e) => e['id'].toString() == id));
        if ((song['lyricsReady'] == true)) {
          processed.add(id);
        } else {
          String title = (song['title'] ?? '').toString().replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._ ]+\s*'), '').trim();
          String artist = (song['artist'] ?? '').toString().trim();
          if (artist.isEmpty) {
            final suggestion = await _server.importedMetadataSuggestion(id);
            artist = (suggestion['artist'] ?? '').toString().trim();
          }
          if (artist.isEmpty || title.isEmpty) throw StateError('Artist or title unresolved');
          await _server.updateImportedMetadata(id, title, artist);
          final preview = await _server.previewImportedLyrics(id);
          final providerId = (preview['providerId'] as num?)?.toInt();
          if (providerId == null || (preview['lineCount'] as num? ?? 0) < 2) {
            throw StateError('No reliable timed lyrics');
          }
          await _server.approveImportedLyrics(id, providerId);
          processed.add(id);
        }
      } catch (error) {
        _batchFailures.add('$id: $error');
      }
      if (mounted) setState(() => _batchCompleted++);
    }
    try {
      if (processed.isNotEmpty) {
        await widget.onReload();
        // Do not acknowledge imported audio until recognition is registered.
        // This keeps a failed song in Pending so it can be retried.
        final published = await _refreshAcousticCatalog();
        if (published != null) {
          await _server.acknowledgeImportedAudio(processed);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
              'Acoustic catalog published: $published references.')));
          }
        } else {
          throw StateError('Acoustic catalog was not confirmed. Imported audio remains pending for retry.');
        }
      }
      await _reloadImports();
      await _loadInbox();
    } catch (error) {
      _batchFailures.add('Refresh: $error');
    } finally {
      if (mounted) {
        setState(() { _processingBatch = false; if (!_batchFailures.any((e) => e.startsWith('Refresh:'))) _selectedImports.removeAll(processed); });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          '${processed.length} completed · ${_batchFailures.length} need review')));
      }
    }
  }

  Future<void> _importFolder() async {
    final controller = TextEditingController(text: '.');
    final folder = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import audio from Windows'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter a subfolder relative to LYRIKO_IMPORT_ROOT on the Windows server. Use . for the whole folder.'),
          const SizedBox(height: 14),
          TextField(controller: controller, autofocus: true,
            decoration: const InputDecoration(labelText: 'Subfolder', hintText: '.')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Scan')),
        ],
      ),
    );
    controller.dispose();
    if (folder == null || folder.isEmpty || !mounted) return;
    setState(() => _loadingImports = true);
    try {
      final result = await _server.importAudioFolder(folder);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          'Found ${result['found']} · Added ${result['added']} · Updated ${result['updated']} · Errors ${result['errors']}')));
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $error')));
    } finally {
      if (mounted) setState(() => _loadingImports = false);
    }
    await _reloadImports();
  }

  // The catalog publication is part of importing a recognizable song.
  // Do not silently report success when the native catalog refresh failed.
  Future<int?> _refreshAcousticCatalog() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) return null;
    final url = await _server.getBaseUrl();
    final token = await _server.getAuthToken();
    if (url.isEmpty || token.isEmpty) {
      throw StateError('Server URL or token is missing; acoustic catalog not published.');
    }
    const channel = MethodChannel('lyriko/macos_audio_recognition');
    final response = await channel.invokeMapMethod<String, dynamic>('refreshCatalog', {
      'serverUrl': url,
      'token': token,
    });
    final count = (response?['referenceCount'] as num?)?.toInt();
    final countExpected = widget.currentSongs().length;
    if (response?['updated'] != true || count == null || count < countExpected) {
      throw StateError(
        'Catalog incomplete: published ${count ?? 0} references, '
        '$countExpected synchronized songs in the library.');
    }
    debugPrint('ShazamKit catalog confirmed: $count references');
    return count;
  }

  // Repairs existing imports even when there are no pending songs.
  Future<void> _repairAcousticCatalog() async {
    if (_busy || _processingBatch) return;
    setState(() => _busy = true);
    try {
      await widget.onReload();
      final count = await _refreshAcousticCatalog();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Acoustic catalog verified'),
          content: Text('Windows stored and returned the new ShazamKit catalog.\n'
              '$count references published.\n'
              'DISCOVER now uses the updated catalog automatically.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Catalog repair failed'),
          content: SelectableText(error.toString()),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _findLyrics(Map<String, dynamic> entry) async {
    if (_busy) return;
    final originalTitle = entry['title']?.toString() ?? '';
    final suggestedTitle = originalTitle.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._ ]+\s*'), '').trim();
    final titleController = TextEditingController(text: suggestedTitle);
    var suggestedArtist = entry['artist']?.toString() ?? '';
    var suggestionSource = '';
    if (suggestedArtist.trim().isEmpty) {
      setState(() => _busy = true);
      try {
        final suggestion = await _server.importedMetadataSuggestion(entry['id'].toString());
        suggestedArtist = suggestion['artist']?.toString() ?? '';
        suggestionSource = suggestion['source']?.toString() ?? '';
      } catch (error) {
        debugPrint('Artist metadata suggestion unavailable: $error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted) return;
    final artistController = TextEditingController(text: suggestedArtist);
    final metadata = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm song details'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(suggestionSource.isNotEmpty && suggestedArtist.isNotEmpty
            ? 'Suggested artist ($suggestionSource). Confirm before searching.'
            : 'Artist not identified automatically. Confirm artist before searching.'),
          TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Song title')),
          TextField(controller: artistController, decoration: const InputDecoration(labelText: 'Artist')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, {
            'title': titleController.text.trim(), 'artist': artistController.text.trim(),
          }), child: const Text('SEARCH')),
        ],
      ),
    );
    titleController.dispose();
    artistController.dispose();
    if (!mounted || metadata == null) return;
    if ((metadata['title'] ?? '').isEmpty || (metadata['artist'] ?? '').isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Title and artist are required')));
      return;
    }
    setState(() => _busy = true);
    try {
      final id = entry['id']?.toString() ?? '';
      await _server.updateImportedMetadata(id, metadata['title']!, metadata['artist']!);
      final result = await _server.previewImportedLyrics(id);
      if (!mounted) return;
      final lines = (result['preview'] as List?)?.map((e) => e.toString()).toList() ?? [];
      final providerId = (result['providerId'] as num?)?.toInt();
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Synchronized lyrics: ${entry['title']}'),
          content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${result['lineCount']} timed lines from LRCLIB. Check that this is the right recording.'),
              const SizedBox(height: 12),
              ...lines.map((line) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(line))),
              const SizedBox(height: 8),
              const Text('Line timing is imported; word-level karaoke timing is not generated.'),
            ],
          ))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ADD SYNCED LYRICS')),
          ],
        ),
      );
      if (approved == true && providerId != null) {
        await _server.approveImportedLyrics(id, providerId);
        await widget.onReload();
        if (mounted) setState(() => _songs = widget.currentSongs());
        // Surface registration failure instead of silently claiming readiness.
        final count = await _refreshAcousticCatalog();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lyrics saved and acoustic catalog updated ($count references).')));
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lyrics lookup: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reloadImports();
      await _loadInbox();
    }
  }

  @override
  Widget build(BuildContext context) {
    final needle = _query.trim().toLowerCase();
    final filtered = _songs.where((s) =>
        s.title.toLowerCase().contains(needle) ||
        s.artist.toLowerCase().contains(needle)).toList();
    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      appBar: AppBar(
        title: const Text('Music Library'),
        backgroundColor: const Color(0xFF080808),
        actions: [
          IconButton(
            tooltip: 'Refresh library',
            onPressed: _busy ? null : () => _run(widget.onReload),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            children: [
              Text('${_songs.length} synchronized songs',
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 20),
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search title or artist',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: const Color(0xFF191919),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _busy || widget.remoteLibraryMode
                      ? null : () => _run(widget.onAddSong),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('ADD SONG'),
                ),
              ),
              const SizedBox(height: 18),
              if (defaultTargetPlatform == TargetPlatform.macOS) ...[
                Row(children: [
                  FilledButton.tonalIcon(
                    onPressed: _loadingImports ? null : _importFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('IMPORT FOLDER (WINDOWS)'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(onPressed: _loadingImports ? null : _reloadImports,
                    tooltip: 'Refresh imported audio', icon: const Icon(Icons.sync)),
                ]),
                if (_loadingImports) const LinearProgressIndicator(minHeight: 2),
                if (_importError != null) Text('Imported audio unavailable: $_importError',
                    style: const TextStyle(color: Colors.orangeAccent)),
                const SizedBox(height: 10),
                if (_newArrivals.isNotEmpty) Card(
                  color: const Color(0xFF211B2C),
                  child: Padding(padding: const EdgeInsets.all(12), child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('NEW MUSIC · ${_newArrivals.length} tracks', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      const Text('Choose tracks or albums to find synchronized lyrics.'),
                      TextButton(onPressed: _processingBatch ? null : () => setState(() {
                        if (_selectedImports.length == _newArrivals.length) {
                          _selectedImports.clear();
                        } else {
                          _selectedImports.addAll(_newArrivals.map((e) => e['id'].toString()));
                        }
                      }), child: const Text('SELECT / CLEAR ALL')),
                      for (final album in (_newArrivals.map((e) => (e['album'] ?? '').toString()).toSet().toList()..sort())) ...[
                        Text(album.isEmpty ? 'Singles / Unknown album' : album,
                          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                        TextButton(onPressed: _processingBatch ? null : () => setState(() {
                          for (final e in _newArrivals.where((e) => (e['album'] ?? '').toString() == album)) {
                            _selectedImports.add(e['id'].toString());
                          }
                        }), child: const Text('Select album')),
                        for (final e in _newArrivals.where((e) => (e['album'] ?? '').toString() == album))
                          CheckboxListTile(
                            dense: true,
                            value: _selectedImports.contains(e['id'].toString()),
                            onChanged: _processingBatch ? null : (v) => setState(() {
                              if (v == true) { _selectedImports.add(e['id'].toString()); }
                              else { _selectedImports.remove(e['id'].toString()); }
                            }),
                            title: Text(e['title']?.toString() ?? ''),
                            subtitle: Text(e['artist']?.toString() ?? ''),
                          ),
                      ],
                      Row(children: [
                        FilledButton(onPressed: _processingBatch || _selectedImports.isEmpty ? null : _lookupBatch,
                          child: Text('FIND LYRICS (${_selectedImports.length})')),
                        const SizedBox(width: 8),
                        TextButton(onPressed: _processingBatch || _selectedImports.isEmpty ? null : _dismissSelected,
                          child: const Text('LATER / DISMISS')),
                      ]),
                    ],
                  )),
                ),
                if (_processingBatch) ...[
                  Text('Processing $_batchCompleted / $_batchTotal'),
                  LinearProgressIndicator(value: _batchTotal == 0 ? null : _batchCompleted / _batchTotal),
                ],
                if (_batchFailures.isNotEmpty && !_processingBatch)
                  Text('${_batchFailures.length} tracks need manual review',
                      style: const TextStyle(color: Colors.orangeAccent)),
                Wrap(spacing: 10, children: [
                  OutlinedButton(onPressed: _processingBatch ? null : () => setState(() {
                    final eligible = _imports.where((e) => e['lyricsReady'] != true)
                        .map((e) => e['id'].toString()).toSet();
                    if (_selectedImports.containsAll(eligible)) {
                      _selectedImports.removeAll(eligible);
                    } else {
                      _selectedImports.addAll(eligible);
                    }
                  }), child: const Text('SELECT / CLEAR ALL PENDING')),
                  FilledButton(onPressed: _processingBatch || _selectedImports.isEmpty ? null : _lookupBatch,
                    child: Text('PROCESS SELECTED (${_selectedImports.length})')),
                ]),
                Text('Imported MP3s awaiting lyrics: ${_imports.length}', 
                    style: const TextStyle(color: Colors.white70)),
                for (final entry in _imports.where((s) =>
                  (s['title']?.toString().toLowerCase() ?? '').contains(needle) ||
                  (s['artist']?.toString().toLowerCase() ?? '').contains(needle)))
                  ListTile(
                    dense: true,
                    leading: Checkbox(
                      value: _selectedImports.contains(entry['id'].toString()),
                      onChanged: entry['lyricsReady'] == true || _processingBatch ? null : (v) => setState(() {
                        if (v == true) { _selectedImports.add(entry['id'].toString()); }
                        else { _selectedImports.remove(entry['id'].toString()); }
                      }),
                    ),
                    title: Text(entry['title']?.toString() ?? ''),
                    subtitle: Text("${entry['artist'] ?? ''} · ${entry['album'] ?? ''} · ${entry['lyricsReady'] == true ? 'Lyrics ready' : 'Lyrics pending'}"),
                    trailing: TextButton.icon(
                      onPressed: _busy || entry['lyricsReady'] == true ? null : () => _findLyrics(entry),
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('FIND LYRICS'),
                    ),
                  ),
                const Divider(),
              ],
              if (defaultTargetPlatform == TargetPlatform.macOS) ...[
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: (_busy || _processingBatch) ? null : _repairAcousticCatalog,
                  icon: const Icon(Icons.build_circle_outlined),
                  label: const Text('REPAIR ACOUSTIC CATALOG (ALL SONGS)'),
                ),
              ],
              if (_busy) const LinearProgressIndicator(),
              ValueListenableBuilder<bool>(
                valueListenable: widget.loadingListenable,
                builder: (context, loading, _) => loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: LinearProgressIndicator(minHeight: 2),
                      )
                    : const SizedBox.shrink(),
              ),
              if (filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(30),
                  child: Text(
                    _songs.isEmpty && widget.loadingListenable.value ? 'Loading songs from server...' : _songs.isEmpty ? 'No synchronized songs yet.'
                        : 'No songs match your search.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
              for (final song in filtered)
                Card(
                  color: const Color(0xFF151515),
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.music_note_rounded),
                          title: Text(song.title,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('${song.artist} · ${song.lines.length} lyric lines'
                              '${song.hasManualCalibration ? ' · ${song.manualCalibrationCount} manually adjusted' : ''}'),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _run(() => widget.onPreview(song)),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('PREVIEW'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: _busy ? null : () => _run(() => widget.onEdit(song)),
                              icon: const Icon(Icons.timeline_rounded),
                              label: const Text('EDIT'),
                            ),
                            IconButton(
                              tooltip: 'Delete song',
                              onPressed: _busy || widget.remoteLibraryMode
                                  ? null : () => _run(() => widget.onDelete(song)),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
