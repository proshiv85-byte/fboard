// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy media work (probing, analysis, decoding, encoding) runs in background
// isolates so the UI never blocks.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../native/bindings.dart';

const audioExtensions = {
  'mp3', 'wav', 'ogg', 'oga', 'opus', 'flac', 'm4a', 'aac', 'wma', 'webm', 'mka', 'mp4', 'aif', 'aiff', //
  'ape', 'wv', 'mpc', 'ac3', 'amr', '3gp', 'mkv', 'mov', 'avi', 'caf', 'spx', 'mp2', 'au', 'tta',
};

bool isAudioFile(String path) {
  final i = path.lastIndexOf('.');
  if (i < 0) return false;
  return audioExtensions.contains(path.substring(i + 1).toLowerCase());
}

/// Expands directories (recursively) into audio files.
List<String> expandPaths(Iterable<String> paths) {
  final out = <String>[];
  for (final p in paths) {
    final type = FileSystemEntity.typeSync(p);
    if (type == FileSystemEntityType.directory) {
      final files =
          Directory(p)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .map((f) => f.path)
              .where(isAudioFile)
              .toList()
            ..sort();
      out.addAll(files);
    } else if (type == FileSystemEntityType.file) {
      out.add(p);
    }
  }
  return out;
}

class ProbeResult {
  final String path;
  final double duration;
  final String format;
  final int size;
  final String title;
  final String artist;
  ProbeResult(this.path, this.duration, this.format, this.size, this.title, this.artist);
}

Future<List<ProbeResult>> probeFiles(List<String> paths) => Isolate.run(() {
  final n = Native.forIsolate();
  final out = <ProbeResult>[];
  for (final p in paths) {
    final i = n.probe(p);
    if (i == null) continue;
    out.add(ProbeResult(p, i.duration, i.format, i.size, i.title, i.artist));
  }
  return out;
});

/// path -> integrated loudness (LUFS)
Future<Map<String, double>> analyzeFiles(List<String> paths) => Isolate.run(() {
  final n = Native.forIsolate();
  final out = <String, double>{};
  for (final p in paths) {
    final r = n.analyze(p);
    if (r != null) out[p] = r.$1;
  }
  return out;
});

Future<DecodedAudio?> decodeFile(String path) => Isolate.run(() => Native.forIsolate().decode(path));

Future<MediaInfo?> probeFile(String path) => Isolate.run(() => Native.forIsolate().probe(path));

Future<bool> encodeFile(String path, String format, Float32List data, int channels) =>
    Isolate.run(() => Native.forIsolate().encode(path, format, data, channels));

Future<double> loudnessOf(Float32List data, int channels) =>
    Isolate.run(() => Native.forIsolate().loudness(data, channels));
