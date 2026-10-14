// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../app/paths.dart';
import '../native/bindings.dart';
import 'dsp.dart';

class RecorderState {
  final bool active;
  final bool encoding;
  final double seconds;
  final double peak;
  const RecorderState(this.active, this.encoding, this.seconds, this.peak);
}

class RecorderService {
  final AppController app;
  RecorderService(this.app);

  final state = ValueNotifier(const RecorderState(false, false, 0, 0));
  String? _temp;
  Timer? _timer;
  bool _starting = false;

  bool get active => state.value.active;

  Future<void> start({bool byHotkey = false}) async {
    if (active || _starting || state.value.encoding) return;
    _starting = true;
    final s = app.settings;
    if (byHotkey && s.notifyRecorder.enabled) {
      app.native.playNotification(2, s.notifyRecorder.path);
      // Start after the notification so it isn't recorded.
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
    _temp = p.join(Paths.cache, 'recording-${DateTime.now().millisecondsSinceEpoch}.raw');
    app.native.recSetGain(s.recordGain);
    final r = app.native.recStart(s.recordSource, s.recordMaxSeconds, _temp!);
    _starting = false;
    if (r != 0) {
      app.notify('Could not start recording (error $r).', NoticeLevel.error);
      return;
    }
    state.value = const RecorderState(true, false, 0, 0);
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      state.value = RecorderState(true, false, app.native.recSeconds, app.native.recPeak());
    });
    app.showStatus('Recording…');
  }

  void onLimitReached() {
    if (active) {
      app.notify('Maximum recording time reached.');
      stop();
    }
  }

  Future<void> stop({bool byHotkey = false}) async {
    if (!active) return;
    _timer?.cancel();
    final frames = app.native.recStop();
    final s = app.settings;
    if (byHotkey && s.notifyRecorder.enabled) app.native.playNotification(3, s.notifyRecorder.path);
    final temp = _temp!;
    if (frames < 4800) {
      state.value = const RecorderState(false, false, 0, 0);
      File(temp).deleteSync();
      app.notify('Recording was too short and was discarded.');
      return;
    }
    state.value = RecorderState(false, true, frames / sampleRate, 0);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'Recording ${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}.${s.recordFormat}';
    final dir = s.recordDirectory ?? Paths.recordings;
    final out = p.join(dir, name);
    final job = _EncodeJob(temp, out, s.recordFormat, s.recordTrimSilence, s.recordNormalize, s.recordNormalizeTarget);
    final ok = await Isolate.run(() => _process(job));
    try {
      File(temp).deleteSync();
    } catch (_) {}
    state.value = const RecorderState(false, false, 0, 0);
    if (!ok) {
      app.notify('Could not encode the recording as ${s.recordFormat.toUpperCase()}.', NoticeLevel.error);
      return;
    }
    await app.addFiles([out], into: null, insertAt: s.recordInsertAtEnd ? null : 0);
    app.notify('Recording saved: $name');
  }

  void cancel() {
    if (!active) return;
    _timer?.cancel();
    app.native.recStop();
    if (_temp != null) {
      try {
        File(_temp!).deleteSync();
      } catch (_) {}
    }
    state.value = const RecorderState(false, false, 0, 0);
  }
}

class _EncodeJob {
  final String raw, out, format;
  final bool trim, normalize;
  final double target;
  _EncodeJob(this.raw, this.out, this.format, this.trim, this.normalize, this.target);
}

bool _process(_EncodeJob j) {
  final bytes = File(j.raw).readAsBytesSync();
  var data = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
  if (j.trim) data = trimSilence(data, 2);
  final n = Native.forIsolate();
  if (j.normalize) {
    final l = n.loudness(data, 2);
    data = applyGain(data, normalizationGain(l, j.target, peakOf(data)));
  }
  return n.encode(j.out, j.format, data, 2);
}
