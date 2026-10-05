import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding
      .ensureInitialized();

  runApp(
    const LyricsApp(),
  );
}

class LyricsApp
    extends StatelessWidget {
  const LyricsApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      title: 'Lyriko',
      debugShowCheckedModeBanner:
          false,
      theme: ThemeData(
        brightness:
            Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor:
            const Color(
          0xFF080808,
        ),
      ),
      home:
          const HomeScreen(),
    );
  }
}