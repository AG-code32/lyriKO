import 'dart:async';

import '../models/lyric_line.dart';

class LyricsSyncService {
  final List<LyricLine> lyrics;

  LyricsSyncService({
    required this.lyrics,
  });

  final _positionController = StreamController<Duration>.broadcast();

  Stream<Duration> get positionStream => _positionController.stream;

  Timer? _timer;

  Duration _position = Duration.zero;

  bool _isPlaying = false;

  Duration get position => _position;

  bool get isPlaying => _isPlaying;

  void play() {
    if (_isPlaying) return;

    _isPlaying = true;

    _timer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) {
        _position += const Duration(milliseconds: 50);
        _positionController.add(_position);
      },
    );
  }

  void pause() {
    _isPlaying = false;
    _timer?.cancel();
    _timer = null;
  }

  void toggle() {
    if (_isPlaying) {
      pause();
    } else {
      play();
    }
  }

  void seek(Duration position) {
    _position = position;
    _positionController.add(_position);
  }

  void reset() {
    seek(Duration.zero);
  }

  int getCurrentLineIndex(Duration position) {
    for (var i = 0; i < lyrics.length; i++) {
      if (lyrics[i].isActive(position)) {
        return i;
      }
    }

    return -1;
  }

  void dispose() {
    _timer?.cancel();
    _positionController.close();
  }
}