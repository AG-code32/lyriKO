import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/synced_lyrics_service.dart';
import '../services/lyriko_server_client.dart';
import 'library_layouts/library_mac_layout.dart';
import 'library_layouts/library_ios_layout.dart';
import 'library_processing_session.dart';

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
  int _section = 0; // 0 pending, 1 review, 2 completed
  final Map<String, String> _reviewReasons = {};
  final Set<String> _inFlight = {};
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
  int? _selectionAnchor;
  bool _updatingArtists = false;
  final List<String> _batchFailures = [];
  final LibraryProcessingSession _job = LibraryProcessingSession.instance;

  bool _wasJobRunning = false;
  void _onJobChange() {
    if (mounted) {
      final justFinished = _wasJobRunning && !_job.running;
      _wasJobRunning = _job.running;
      setState(() {
        _processingBatch = _job.running;
        _batchCompleted = _job.completed;
        _batchTotal = _job.total;
        _reviewReasons..clear()..addAll(_job.failures);
        _selectedImports.removeAll(_job.completedIds);
      });
      if (justFinished) {
        _reloadImports();
      }
    }
  }



  @override
  void initState() {
    super.initState();
    _songs = widget.songs;
    _job.addListener(_onJobChange);
    _processingBatch = _job.running;
    _wasJobRunning = _job.running;
    _batchCompleted = _job.completed;
    _batchTotal = _job.total;
    _reviewReasons.addAll(_job.failures);
    _job.restore();
    widget.songsListenable.addListener(_syncSongs);
    _reloadImports();
    _loadInbox();
  }

  void _syncSongs() {
    if (mounted) setState(() => _songs = widget.songsListenable.value);
  }

  @override
  void dispose() {
    _job.removeListener(_onJobChange);
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

  // Shift-click selects a continuous range in the current visible order.
  void _toggleImportSelection(int index, List<Map<String, dynamic>> visible) {
    if (index < 0 || index >= visible.length || _processingBatch) return;
    final id = (visible[index]['id'] ?? '').toString();
    if (id.isEmpty) return;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (shift && _selectionAnchor != null && visible.isNotEmpty) {
        final start = _selectionAnchor!.clamp(0, visible.length - 1);
        final low = start < index ? start : index;
        final high = start > index ? start : index;
        for (var i = low; i <= high; i++) {
          final row = visible[i];
          if (row['lyricsReady'] != true) {
            final rowId = (row['id'] ?? '').toString();
            if (rowId.isNotEmpty) _selectedImports.add(rowId);
          }
        }
      } else {
        if (!_selectedImports.add(id)) _selectedImports.remove(id);
      }
      _selectionAnchor = index;
    });
  }

  bool _looksLikeTrackNumber(String value) =>
      RegExp(r'^\s*\d{1,3}\s*$').hasMatch(value);

  Future<void> _editSelectedArtist() async {
    if (_selectedImports.isEmpty || _processingBatch || _updatingArtists) return;
    final artistController = TextEditingController();
    final count = _selectedImports.length;
    final proposed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set artist for $count tracks'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('This changes only the artist field. Titles, audio and lyrics remain unchanged.'),
          const SizedBox(height: 12),
          TextField(controller: artistController, autofocus: true,
            decoration: const InputDecoration(labelText: 'Artist name')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, artistController.text.trim()),
            child: const Text('UPDATE')),
        ],
      ),
    );
    artistController.dispose();
    if (!mounted || proposed == null || proposed.isEmpty) return;
    setState(() => _updatingArtists = true);
    var success = 0;
    final errors = <String>[];
    final selected = _selectedImports.toList();
    // Preserve existing titles, never attempt lyric lookups during metadata edits.
    final byId = {for (final row in _imports) (row['id'] ?? '').toString(): row};
    for (final id in selected) {
      final row = byId[id];
      if (row == null) {
        errors.add('$id: missing from server index');
        continue;
      }
      final title = (row['title'] ?? '').toString().trim();
      if (title.isEmpty) {
        errors.add('$id: missing title');
        continue;
      }
      try {
        await _server.updateImportedMetadata(id, title, proposed);
        success++;
      } catch (e) {
        errors.add('$id: $e');
      }
    }
    if (mounted) setState(() {
      _updatingArtists = false;
      for (final id in selected) {
        if (!errors.any((err) => err.startsWith('$id:'))) _selectedImports.remove(id);
      }
    });
    await _reloadImports();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
      'Artist updated for $success / $count tracks. ${errors.length} failed.')));
  }

  Future<void> _lookupBatch() async {
    if (_selectedImports.isEmpty || _job.running) return;
    final ids = _selectedImports.toList();
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Find lyrics for ${ids.length} songs?'),
      content: const Text('Tracks are processed individually. Failures remain available for review. You can leave Music Library and return without interrupting the job.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('START')),
      ],
    ));
    if (confirm != true || !mounted) return;
    // The singleton owns the future and does not depend on this route staying mounted.
    _job.start(
      ids: ids,
      imports: [..._imports, ..._newArrivals],
      reloadLibrary: widget.onReload,
      currentSongs: widget.currentSongs,
    );
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
    if (suggestedArtist.trim().isEmpty || _looksLikeTrackNumber(suggestedArtist)) {
      suggestedArtist = '';
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
        _job.resolveFailure(id);
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

  bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> _refreshAll() async {
    if (_busy || _processingBatch) return;
    await Future.wait([_reloadImports(), _loadInbox(), widget.onReload()]);
  }


  Future<void> _editInfo(Map<String, dynamic> entry) async {
    final id = (entry['id'] ?? '').toString();
    final title = TextEditingController(text: (entry['title'] ?? '').toString());
    final artist = TextEditingController(text: (entry['artist'] ?? '').toString());
    final album = TextEditingController(text: (entry['album'] ?? '').toString());
    final year = TextEditingController(text: entry['year']?.toString() ?? '');
    final genre = TextEditingController(text: (entry['genre'] ?? '').toString());
    final track = TextEditingController(text: (entry['track_number'] ?? '').toString());
    final inputs = [title, artist, album, year, genre, track];
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit song information'),
        content: SizedBox(width: 450, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
            TextField(controller: artist, decoration: const InputDecoration(labelText: 'Artist')),
            TextField(controller: album, decoration: const InputDecoration(labelText: 'Album (optional)')),
            TextField(controller: year, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Year (optional)')),
            TextField(controller: genre, decoration: const InputDecoration(labelText: 'Genre (optional)')),
            TextField(controller: track, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Track number (optional)')),
          ],
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final y = year.text.trim();
            final n = track.text.trim();
            final parsedYear = int.tryParse(y);
            final parsedTrack = int.tryParse(n);
            if (title.text.trim().isEmpty || artist.text.trim().isEmpty ||
                (y.isNotEmpty && (parsedYear == null || parsedYear < 1850 || parsedYear > 2200)) ||
                (n.isNotEmpty && (parsedTrack == null || parsedTrack < 1 || parsedTrack > 999))) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                content: Text('Enter title, artist, and valid optional numbers.')));
              return;
            }
            Navigator.pop(ctx, {
              'title': title.text.trim(), 'artist': artist.text.trim(),
              'album': album.text.trim(), 'genre': genre.text.trim(),
              'year': parsedYear, 'trackNumber': parsedTrack,
            });
          }, child: const Text('SAVE')),
        ],
      ),
    );
    for (final c in inputs) { c.dispose(); }
    if (values == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _server.updateImportedMetadataFields(id, values);
      await _reloadImports();
      await widget.onReload();
      if (mounted) setState(() => _songs = widget.currentSongs());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metadata saved on Windows server.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot save metadata: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addManualLyrics(Map<String, dynamic> entry) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add lyrics · ${entry['title'] ?? ''}'),
        content: SizedBox(width: 570, child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Paste one lyric phrase per line. Times will be provisional; calibrate in Lyrics Timeline afterward.'),
          const SizedBox(height: 12),
          TextField(controller: controller, autofocus: true, minLines: 7, maxLines: 14,
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Paste lyrics here…')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (controller.text.trim().isEmpty) return;
            Navigator.pop(ctx, controller.text.trim());
          }, child: const Text('SAVE PROVISIONAL LYRICS')),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final id = (entry['id'] ?? '').toString();
      await _server.addManualImportedLyrics(id, result);
      _job.resolveFailure(id);
      await widget.onReload();
      await _reloadImports();
      if (mounted) setState(() => _songs = widget.currentSongs());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Lyrics saved. Open Completed → EDIT to calibrate timings.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot save manual lyrics: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreReviewToPending(List<Map<String, dynamic>> review) async {
    if (_job.running || review.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Return to Pending?'),
        content: Text('Move ${review.length} tracks from Review to Pending? '
            'This only clears local error markers. No MP3, lyrics, or server records are changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('MOVE TO PENDING')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = review.map((e) => (e['id'] ?? '').toString())
        .where((id) => id.isNotEmpty).toSet();
    _job.returnFailuresToPending(ids);
    setState(() {
      _reviewReasons.removeWhere((id, _) => ids.contains(id));
      _selectedImports.removeAll(ids);
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Returned ${ids.length} tracks to Pending')));
  }

  Widget _importRow(Map<String, dynamic> entry, int index, List<Map<String, dynamic>> visible) {
    final id = (entry['id'] ?? '').toString();
    final failed = _reviewReasons[id];
    final title = (entry['title'] ?? '').toString();
    final artist = (entry['artist'] ?? '').toString();
    final ready = entry['lyricsReady'] == true;
    final shownArtist = _looksLikeTrackNumber(artist) ? 'Artist not assigned' : artist;
    return InkWell(
      onTap: !_isMac || ready || _processingBatch || _updatingArtists ? null
          : () => _toggleImportSelection(index, visible),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        leading: Checkbox(
          value: _selectedImports.contains(id),
          onChanged: !_isMac || ready || _processingBatch || _updatingArtists ? null
              : (_) => _toggleImportSelection(index, visible),
        ),
        title: Text(title.isEmpty ? '(Unknown title)' : title,
          maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(failed == null
            ? '$shownArtist · ${entry['album'] ?? ''}'
            : '$shownArtist · $failed',
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: failed == null ? null : const TextStyle(color: Colors.orangeAccent)),
        trailing: _isMac ? Wrap(spacing: 2, children: [
          IconButton(
            tooltip: 'Edit metadata', icon: const Icon(Icons.tune_rounded),
            onPressed: _busy || _updatingArtists ? null : () => _editInfo(entry)),
          IconButton(
            tooltip: 'Add lyrics manually', icon: const Icon(Icons.edit_note_rounded),
            onPressed: _busy || _processingBatch ? null : () => _addManualLyrics(entry)),
          TextButton(
            onPressed: _processingBatch || _busy || ready || _updatingArtists
                ? null : () => _findLyrics(entry),
            child: const Text('FIND LYRICS')),
        ]) : null,
      ),
    );
  }

  Widget _completedRow(SyncedLyricsSong song) => Card(
    color: const Color(0xFF151515),
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ListTile(
          leading: const Icon(Icons.music_note_rounded),
          title: Text(song.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${song.artist} · ${song.lines.length} lyric lines'
              '${song.hasManualCalibration ? ' · ${song.manualCalibrationCount} manually adjusted' : ''}'),
        ),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(() => widget.onPreview(song)),
            icon: const Icon(Icons.play_arrow_rounded), label: const Text('PREVIEW')),
          if (_imports.any((entry) => entry['lyricsReady'] == true &&
              (entry['artist']?.toString().toLowerCase() == song.artist.toLowerCase()) &&
              (entry['title']?.toString().toLowerCase() == song.title.toLowerCase())))
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _editInfo(_imports.firstWhere((entry) =>
                entry['lyricsReady'] == true &&
                entry['artist']?.toString().toLowerCase() == song.artist.toLowerCase() &&
                entry['title']?.toString().toLowerCase() == song.title.toLowerCase())),
              icon: const Icon(Icons.tune_rounded), label: const Text('EDIT INFO')),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _run(() => widget.onEdit(song)),
            icon: const Icon(Icons.timeline_rounded), label: const Text('EDIT')),
          IconButton(
            tooltip: 'Delete song',
            onPressed: _busy || widget.remoteLibraryMode
                ? null : () => _run(() => widget.onDelete(song)),
            icon: const Icon(Icons.delete_outline_rounded)),
        ]),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final needle = _query.trim().toLowerCase();
    final completed = _songs.where((s) =>
        s.title.toLowerCase().contains(needle) ||
        s.artist.toLowerCase().contains(needle)).toList();
    final filteredImports = _imports.where((s) =>
        (s['title']?.toString().toLowerCase() ?? '').contains(needle) ||
        (s['artist']?.toString().toLowerCase() ?? '').contains(needle)).toList();
    final pending = filteredImports.where((e) =>
        e['lyricsReady'] != true && !_reviewReasons.containsKey((e['id'] ?? '').toString())).toList();
    final review = filteredImports.where((e) =>
        e['lyricsReady'] != true && _reviewReasons.containsKey((e['id'] ?? '').toString())).toList();
    final selectedList = _section == 0 ? pending : review;
    if (_selectionAnchor != null && _selectionAnchor! >= selectedList.length) {
      _selectionAnchor = null;
    }
    final tabs = ['Pending (${pending.length})', 'Review (${review.length})',
      'Completed (${completed.length})'];
    final isMac = _isMac;

    final controls = Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(
        onChanged: (value) => setState(() => _query = value),
        decoration: InputDecoration(
          hintText: 'Search title or artist',
          prefixIcon: const Icon(Icons.search_rounded),
          filled: true, fillColor: const Color(0xFF191919),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        if (isMac) ...[
          OutlinedButton.icon(onPressed: _processingBatch ? null : _importFolder,
            icon: const Icon(Icons.create_new_folder_outlined), label: const Text('SCAN WINDOWS FOLDER')),
          const SizedBox(width: 8),
        ],
        TextButton.icon(onPressed: _refreshAll, icon: const Icon(Icons.refresh), label: const Text('Sync')),
      ]),
      const SizedBox(height: 6),
      isMac
        ? LibraryMacLayout(
            tabs: tabs, selected: _section, onSelect: (v) => setState(() => _section = v))
        : LibraryIosLayout(
            tabs: tabs, selected: _section, onSelect: (v) => setState(() => _section = v)),
      if (_importError != null) Text('Server: $_importError',
        style: const TextStyle(color: Colors.orangeAccent)),
      if (_loadingImports) const LinearProgressIndicator(minHeight: 2),
      if (_job.acousticRunning || _job.acousticPhase.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 9),
          child: Text(
            _job.acousticRunning
                ? 'Acoustic catalog updating in background — lyrics are already saved'
                : _job.acousticPhase,
            style: TextStyle(color: _job.acousticError == null
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : Theme.of(context).colorScheme.error),
          ),
        ),
      if (_job.running || _job.total > 0) ...[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(color: const Color(0xFF23202C),
            borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_job.running
              ? 'Processing ${_job.completed} / ${_job.total} · ${_job.phase}'
              : 'Last batch: ${_job.succeeded} completed · ${_job.failures.length} failed${_job.lastError == null ? '' : ' · Action needed'}',
              style: const TextStyle(color: Colors.white)),
            if (_job.currentTitle.isNotEmpty)
              Text(_job.currentTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            if (_job.running)
              LinearProgressIndicator(value: _job.total == 0 ? null : _job.completed / _job.total),
            if (_job.lastError != null)
              Text(_job.lastError!, style: const TextStyle(color: Colors.orangeAccent)),
            if (_job.failures.isNotEmpty)
              Text('${_job.failures.length} tracks need review',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          ]),
        ),
      ],
      if (_section == 1 && review.isNotEmpty && !_job.running)
        Align(alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _restoreReviewToPending(review),
            icon: const Icon(Icons.undo_rounded),
            label: Text('MOVE ${review.length} TO PENDING'),
          )),
      if (_section != 2) ...[
        Row(children: [
          Text('${selectedList.length} tracks', style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          if (isMac) TextButton(
            onPressed: _processingBatch ? null : () => setState(() {
              final eligible = selectedList.map((e) => (e['id'] ?? '').toString()).toSet();
              if (_selectedImports.containsAll(eligible)) {
                _selectedImports.removeAll(eligible);
              } else { _selectedImports.addAll(eligible); }
            }), child: const Text('Select / clear visible')),
        ]),
        if (isMac) Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            OutlinedButton.icon(
              onPressed: _selectedImports.isEmpty || _processingBatch || _updatingArtists
                  ? null : _editSelectedArtist,
              icon: const Icon(Icons.edit_outlined),
              label: Text('SET ARTIST (${_selectedImports.length})'),
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('Shift + click: select range',
              style: TextStyle(fontSize: 11, color: Colors.white54))),
          ]),
        ),
        if (isMac) SizedBox(width: double.infinity,
          child: FilledButton.icon(
            onPressed: _processingBatch || _selectedImports.isEmpty ? null : _lookupBatch,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text('PROCESS SELECTED (${_selectedImports.length})'),
          ))
        else const Padding(padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Review and playback are available on iPhone. Import processing remains on macOS.',
            style: TextStyle(color: Colors.white54))),
      ],
    ]);

    final list = _section == 2
        ? ListView.builder(
            padding: const EdgeInsets.only(top: 10, bottom: 24),
            itemCount: completed.length,
            itemBuilder: (context, i) => _completedRow(completed[i]),
          )
        : ListView.builder(
            padding: const EdgeInsets.only(top: 10, bottom: 24),
            itemCount: selectedList.length,
            itemBuilder: (context, i) => _importRow(selectedList[i], i, selectedList),
          );

    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      appBar: AppBar(title: const Text('Music Library'),
        actions: [
          const Center(child: Text(
            String.fromEnvironment('LYRIKO_BUILD', defaultValue: 'local'),
            style: TextStyle(fontSize: 11, color: Colors.white54),
          )),
          IconButton(onPressed: _refreshAll, icon: const Icon(Icons.refresh_rounded)),
        ]),
      body: Center(child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isMac ? 1080 : 600),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: isMac ? 24 : 14, vertical: 12),
          child: Column(children: [
            controls, // stays fixed while the list scrolls
            const Divider(height: 18),
            Expanded(child: list),
          ]),
        ),
      )),
    );
  }
}
