# Lyriko Timeline Editor v9 (iPhone)

Replace exactly these two files in your Flutter project:
- `lib/screens/lyrics_edit_screen.dart`
- `lib/widgets/lyrics_timeline/lyrics_track.dart`

Changes:
- Pinch with two fingers over the timeline to zoom in/out centered on the gesture. Zoom buttons remain available.
- iPhone lyric clips stretch to almost all of the enlarged lyrics lane height (10px vertical margins). Windows clip height stays unchanged.
- Double tap and hold the second tap, then drag over clips, to create a multi-selection rectangle on iPhone. Desktop empty-space drag selection stays available.
- Other playback and waveform logic untouched.

Check on your Mac:
`flutter analyze lib/screens/lyrics_edit_screen.dart lib/widgets/lyrics_timeline/lyrics_track.dart`

No Flutter SDK is available in this artifact-building environment, so analyzer and iOS runtime behavior have not been verified here.
