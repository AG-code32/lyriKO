import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/song.dart';

class SongLoaderService {
  Future<Song> loadFromAsset(String path) async {
    final jsonString = await rootBundle.loadString(path);

    final jsonData =
        jsonDecode(jsonString) as Map<String, dynamic>;

    return Song.fromJson(jsonData);
  }
}