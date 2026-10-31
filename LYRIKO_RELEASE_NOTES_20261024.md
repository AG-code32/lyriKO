# LyriKO consolidated source — 24 Oct 2026

This package is assembled from the user's `LyriKO_Flutter_Current.zip`, not the older partial-screen ZIPs.

## Included changes
* Restored `macos/Runner/AppDelegate.swift` from the last full Mac-native source (LyriKO_Flutter_Light), including the `LyrikoMacAudioRecognizer` implementation required by `MainFlutterWindow.swift`. This replaces accidentally copied iOS UIKit code. It keeps the current `ios/Runner/AppDelegate.swift` intact, including the working screen-awake channel.
* `lib/screens/my_music_screen.dart`: On compact displays, swiping from lyrics returns to the artist/song browser without stopping playback. A compact mini player with title, artist, time and playback controls appears at the bottom of MY MUSIC. Tapping it reopens lyrics.
* Added Browse lyrics mode: scroll anywhere without seeking; tap a line to seek and return to follow mode.

## Outstanding (NOT implemented in this package)
* A globally persistent mini player on Home and media/remote commands for AirPods require a shared audio controller; the current audio player still belongs to MyMusicScreen.
* Automatic repair of numeric artists, server-wide metadata identity remapping and complete cross-device synchronization need coordinated backend changes.
* Additional karaoke timing and iOS playback issues may still need device tests.

## Install safely
1. Back up the live project: `cp -a ~/Documents/flutter_projects/lyriKO ~/Documents/flutter_projects/lyriKO_backup_20261024` (check space first).
2. Unzip into the backed-up project root (project-relative paths). Do not uninstall the iPhone app or clear local caches.
3. `cd ~/Documents/flutter_projects/lyriKO && flutter pub get && flutter analyze && flutter build macos --release`
4. For iOS after analysis passes: `flutter run --release -d 00008120-001018310A8BC01E`
5. No Windows backend restart needed for this package.

Environment limitation: Flutter/Dart/Xcode are not available in the authoring environment. macOS and iOS builds are NOT verified here. This is a consolidated source snapshot, not a verified full feature release.
