import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class WaveformData {
  final List<double> samples;

  const WaveformData({
    required this.samples,
  });
}

class WaveformCacheService {
  static const int _targetPoints = 5000;

  String cachePathForJson(
    String songJsonPath,
  ) {
    return songJsonPath.replaceFirst(
      RegExp(
        r'\.json$',
        caseSensitive: false,
      ),
      '.waveform.json',
    );
  }

  Future<String> _writableCachePath(String songJsonPath) async {
    final name = songJsonPath.replaceAll('\\', '/').split('/').last
        .replaceFirst(RegExp(r'\.json$', caseSensitive: false), '.waveform.json');
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/lyriko_waveforms');
    await directory.create(recursive: true);
    return '${directory.path}/$name';
  }

  Future<void> clearCache(String songJsonPath) async {
    if (Platform.isIOS || Platform.isAndroid) {
      final file = File(await _writableCachePath(songJsonPath));
      if (await file.exists()) await file.delete();
    } else {
      final file = File(cachePathForJson(songJsonPath));
      if (await file.exists()) await file.delete();
    }
  }

  Future<WaveformData?> _bundledWaveform(String songJsonPath) async {
    if (!(Platform.isIOS || Platform.isAndroid)) return null;
    if (!songJsonPath.startsWith('assets/lyrics/')) return null;
    try {
      final raw = await rootBundle.loadString(cachePathForJson(songJsonPath));
      final json = jsonDecode(raw);
      if (json is! Map || json['samples'] is! List) return null;
      return WaveformData(samples: (json['samples'] as List)
          .whereType<num>().map((item) => item.toDouble()).toList());
    } catch (_) {
      return null;
    }
  }

  Future<WaveformData?> loadOrCreate({
    required String songJsonPath,
    required String audioPath,
  }) async {
    final mobile = Platform.isIOS || Platform.isAndroid;
    final cachePath = mobile
        ? await _writableCachePath(songJsonPath)
        : cachePathForJson(songJsonPath);
    // Local waveform cache is highest priority, followed by bundled data.
    final cached = await _loadCache(cachePath);
    if (cached != null) return cached;
    final bundled = await _bundledWaveform(songJsonPath);
    if (bundled != null) return bundled;
    if (audioPath.trim().isEmpty || !await File(audioPath).exists()) return null;
    final generated = mobile
        ? await _generateMobileWaveform(audioPath)
        : await _generateWaveform(audioPath);
    if (generated == null || generated.samples.isEmpty) return null;
    await _saveCache(cachePath, generated);
    return generated;
  }

  Future<WaveformData?> _loadCache(
    String path,
  ) async {
    try {
      final file =
          File(path);

      if (!await file.exists()) {
        return null;
      }

      final raw =
          jsonDecode(
        await file.readAsString(),
      );

      if (raw is! Map) {
        return null;
      }

      final samples =
          raw['samples'];

      if (samples is! List) {
        return null;
      }

      return WaveformData(
        samples: samples
            .whereType<num>()
            .map(
              (value) =>
                  value.toDouble(),
            )
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache(
    String path,
    WaveformData data,
  ) async {
    final file =
        File(path);

    await file.writeAsString(
      jsonEncode(
        {
          'version': 1,
          'samples':
              data.samples,
        },
      ),
      flush: true,
    );
  }

  Future<WaveformData?> _generateMobileWaveform(String audioPath) async {
    try {
      final controller = WaveformExtractionController();
      final values = await controller.extractWaveformData(
        path: audioPath,
        noOfSamples: _targetPoints,
      );
      if (values.isEmpty) return null;
      final peak = values.fold<double>(0.0,
          (maxValue, value) => math.max(maxValue, value.abs()));
      if (peak == 0) return WaveformData(samples: List.filled(values.length, 0));
      return WaveformData(samples: values
          .map((value) => (value.abs() / peak).clamp(0.0, 1.0).toDouble())
          .toList());
    } catch (error) {
      return null;
    }
  }

  Future<WaveformData?> _generateWaveform(
    String audioPath,
  ) async {
    Process process;

    try {
      process =
          await Process.start(
        'ffmpeg',
        [
          '-v',
          'error',
          '-i',
          audioPath,
          '-ac',
          '1',
          '-ar',
          '8000',
          '-f',
          's16le',
          '-acodec',
          'pcm_s16le',
          'pipe:1',
        ],
        runInShell: true,
      );
    } catch (_) {
      return null;
    }

    final bytes =
        <int>[];

    final stderrBuffer =
        StringBuffer();

    final stdoutFuture =
        process.stdout.listen(
      bytes.addAll,
    ).asFuture<void>();

    final stderrFuture =
        process.stderr
            .transform(
              utf8.decoder,
            )
            .listen(
              stderrBuffer.write,
            )
            .asFuture<void>();

    final exitCode =
        await process.exitCode;

    await stdoutFuture;
    await stderrFuture;

    if (exitCode != 0 ||
        bytes.length < 2) {
      return null;
    }

    final pcmSamples =
        bytes.length ~/ 2;

    if (pcmSamples <= 0) {
      return null;
    }

    final points =
        math.min(
      _targetPoints,
      pcmSamples,
    );

    final bucketSize =
        math.max(
      1,
      (pcmSamples / points).ceil(),
    );

    final waveform =
        <double>[];

    for (var start = 0;
        start < pcmSamples;
        start += bucketSize) {
      final end =
          math.min(
        pcmSamples,
        start + bucketSize,
      );

      var peak = 0;

      for (var sampleIndex = start;
          sampleIndex < end;
          sampleIndex++) {
        final byteIndex =
            sampleIndex * 2;

        final low =
            bytes[byteIndex];

        final high =
            bytes[byteIndex + 1];

        var value =
            low |
                (high << 8);

        if (value >= 0x8000) {
          value -= 0x10000;
        }

        final absolute =
            value.abs();

        if (absolute > peak) {
          peak = absolute;
        }
      }

      waveform.add(
        (peak / 32768.0)
            .clamp(
              0.0,
              1.0,
            )
            .toDouble(),
      );
    }

    return WaveformData(
      samples: waveform,
    );
  }
}