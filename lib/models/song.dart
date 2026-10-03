import 'lyric_line.dart';

class Song {
  final String id;
  final String title;
  final String artist;
  final List<LyricLine> lyrics;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.lyrics,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    final lyricsJson = json['lyrics'] as List<dynamic>;

    return Song(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      lyrics: lyricsJson
          .map(
            (item) => LyricLine.fromJson(
              item as Map<String, dynamic>,
            ),
          )
          .toList(),
    );
  }
}