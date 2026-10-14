// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';

const sampleRate = 48000;

/// Removes leading/trailing silence below [threshold] (linear amplitude).
Float32List trimSilence(Float32List data, int channels, {double threshold = 0.01}) {
  final frames = data.length ~/ channels;
  var start = 0, end = frames;
  bool loud(int f) {
    for (var c = 0; c < channels; c++) {
      if (data[f * channels + c].abs() > threshold) return true;
    }
    return false;
  }

  while (start < frames && !loud(start)) {
    start++;
  }
  while (end > start && !loud(end - 1)) {
    end--;
  }
  // Keep 20 ms of padding so the sound doesn't start abruptly.
  const pad = sampleRate ~/ 50;
  start = math.max(0, start - pad);
  end = math.min(frames, end + pad);
  return Float32List.sublistView(data, start * channels, end * channels);
}

/// Applies a linear gain with hard clipping.
Float32List applyGain(Float32List data, double gain) {
  final out = Float32List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = (data[i] * gain).clamp(-1.0, 1.0);
  }
  return out;
}

double peakOf(Float32List data) {
  var p = 0.0;
  for (final v in data) {
    final a = v.abs();
    if (a > p) p = a;
  }
  return p;
}

/// Gain that brings [lufs] to [target], limited so the peak doesn't clip.
double normalizationGain(double lufs, double target, double peak) {
  if (!lufs.isFinite) return 1;
  var g = math.pow(10, (target - lufs) / 20).toDouble();
  if (peak > 0 && g * peak > 0.999) g = 0.999 / peak;
  return g;
}

Float32List fade(Float32List data, int channels, int from, int to, {required bool fadeIn}) {
  final out = Float32List.fromList(data);
  final len = to - from;
  if (len <= 0) return out;
  for (var f = from; f < to; f++) {
    final t = (f - from) / len;
    final g = fadeIn ? t : 1 - t;
    for (var c = 0; c < channels; c++) {
      out[f * channels + c] *= g;
    }
  }
  return out;
}

String formatDuration(double seconds, {bool millis = false}) {
  if (!seconds.isFinite || seconds < 0) seconds = 0;
  final total = seconds.floor();
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final base = h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  if (!millis) return base;
  final ms = ((seconds - total) * 1000).floor();
  return '$base.${ms.toString().padLeft(3, '0')}';
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Soundpad expresses loudness targets in "dB" where 89 dB = -23 LUFS.
double lufsToSoundpadDb(double lufs) => lufs + 112;
double soundpadDbToLufs(double db) => db - 112;
