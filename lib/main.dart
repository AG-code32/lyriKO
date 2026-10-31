import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      windowButtonVisibility: true,
    );

    await windowManager.waitUntilReadyToShow(
      windowOptions,
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  // LYRIKO_SCREEN_AWAKE_CHANNEL_V1
  WidgetsBinding.instance.addObserver(_LyrikoScreenAwakeObserver.instance);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _LyrikoScreenAwakeObserver.instance.enable();
  });
  runApp(
    const LyricsApp(),
  );
}

class LyricsApp extends StatelessWidget {
  const LyricsApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      title: 'Lyriko',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(
          0xFF080808,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// LYRIKO_SCREEN_AWAKE_CHANNEL_V1
class _LyrikoScreenAwakeObserver with WidgetsBindingObserver {
  _LyrikoScreenAwakeObserver._();
  static final instance = _LyrikoScreenAwakeObserver._();
  static const _channel = MethodChannel('lyriko/screen_awake');
  Future<void> enable() async {
    if (!Platform.isIOS) return;
    try {
      final enabled = await _channel.invokeMethod<bool>('enable');
      debugPrint('LyriKO screen awake: ${enabled == true ? "ON" : "FAILED"}');
    } catch (error) {
      debugPrint('LyriKO screen awake channel error: $error');
    }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) enable();
  }
}
