// SPDX-License-Identifier: GPL-3.0-or-later
// dart:ffi bindings for libfboard_native.so (see native/fboard_native.h).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const evPlaybackFinished = 1;
const evPlaybackError = 2;
const evKey = 3;
const evAudioState = 4;
const evDevicesChanged = 5;
const evRecorderLimit = 6;

final class FbMediaInfo extends Struct {
  @Double()
  external double duration;
  @Int32()
  external int sampleRate;
  @Int32()
  external int channels;
  @Int64()
  external int size;
  @Array(32)
  external Array<Uint8> format;
  @Array(256)
  external Array<Uint8> title;
  @Array(256)
  external Array<Uint8> artist;
}

final class FbStatus extends Struct {
  @Int32()
  external int state;
  @Int32()
  external int id;
  @Double()
  external double position;
  @Double()
  external double duration;
  @Int32()
  external int toSpeakers;
  @Int32()
  external int toMic;
  @Float()
  external double micPeak;
  @Float()
  external double outputPeak;
}

String _cstr(Array<Uint8> a, int len) {
  final bytes = <int>[];
  for (var i = 0; i < len; i++) {
    final b = a[i];
    if (b == 0) break;
    bytes.add(b);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

class MediaInfo {
  final double duration;
  final int sampleRate;
  final int channels;
  final int size;
  final String format;
  final String title;
  final String artist;
  MediaInfo(this.duration, this.sampleRate, this.channels, this.size, this.format, this.title, this.artist);
}

class PlaybackStatus {
  final int state; // 0 stopped, 1 playing, 2 paused
  final int id;
  final double position;
  final double duration;
  final bool toSpeakers;
  final bool toMic;
  final double micPeak;
  final double outputPeak;
  const PlaybackStatus(
    this.state,
    this.id,
    this.position,
    this.duration,
    this.toSpeakers,
    this.toMic,
    this.micPeak,
    this.outputPeak,
  );
  static const stopped = PlaybackStatus(0, 0, 0, -1, false, false, 0, 0);
}

class DecodedAudio {
  final Float32List samples; // interleaved, 48 kHz
  final int channels;
  DecodedAudio(this.samples, this.channels);
  int get frames => samples.length ~/ channels;
  double get duration => frames / 48000.0;
}

typedef _EventNative = Void Function(Int32, Int32, Int32, Int64);

/// Thin, synchronous wrapper around the native library. Can be instantiated
/// in background isolates as well (for decoding/encoding/analysis).
class Native {
  static Native? _instance;
  static Native get I => _instance ??= Native._();

  final DynamicLibrary lib;

  Native._() : lib = _open();

  /// Creates an independent instance (for use inside another isolate).
  factory Native.forIsolate() => Native._();

  static DynamicLibrary _open() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = ['$exeDir/lib/libfboard_native.so', 'libfboard_native.so'];
    for (final c in candidates) {
      try {
        return DynamicLibrary.open(c);
      } catch (_) {}
    }
    throw StateError('libfboard_native.so not found');
  }

  late final _setEventCallback = lib
      .lookupFunction<
        Void Function(Pointer<NativeFunction<_EventNative>>),
        void Function(Pointer<NativeFunction<_EventNative>>)
      >('fb_set_event_callback');
  late final _free = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fb_free');
  late final _probe = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<FbMediaInfo>),
        int Function(Pointer<Utf8>, Pointer<FbMediaInfo>)
      >('fb_probe');
  late final _decode = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Pointer<Float>>, Pointer<Int64>, Pointer<Int32>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Float>>, Pointer<Int64>, Pointer<Int32>)
      >('fb_decode');
  late final _encode = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Float>, Int64, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Float>, int, int)
      >('fb_encode');
  late final _loudness = lib
      .lookupFunction<Double Function(Pointer<Float>, Int64, Int32), double Function(Pointer<Float>, int, int)>(
        'fb_loudness',
      );
  late final _analyze = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Double>, Pointer<Double>),
        int Function(Pointer<Utf8>, Pointer<Double>, Pointer<Double>)
      >('fb_analyze');

  late final _audioInit = lib.lookupFunction<Int32 Function(), int Function()>('fb_audio_init');
  late final _audioShutdown = lib.lookupFunction<Void Function(), void Function()>('fb_audio_shutdown');
  late final _audioConnected = lib.lookupFunction<Int32 Function(), int Function()>('fb_audio_connected');
  late final _listDevices = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('fb_list_devices');
  late final _vmicSetup = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
    'fb_vmic_setup',
  );
  late final _vmicTeardown = lib.lookupFunction<Void Function(), void Function()>('fb_vmic_teardown');
  late final _vmicActive = lib.lookupFunction<Int32 Function(), int Function()>('fb_vmic_active');
  late final _setBlockVoice = lib.lookupFunction<Void Function(Int32), void Function(int)>('fb_set_block_voice');
  late final _setHearMyself = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('fb_set_hear_myself');
  late final _setDefaultSource = lib.lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(
    'fb_set_default_source',
  );
  late final _setOutputSink = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
    'fb_set_output_sink',
  );
  late final _play = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Int32, Double, Double),
        int Function(Pointer<Utf8>, int, int, double, double)
      >('fb_play');
  late final _playBuffer = lib
      .lookupFunction<
        Int32 Function(Pointer<Float>, Int64, Int32, Int32, Int32),
        int Function(Pointer<Float>, int, int, int, int)
      >('fb_play_buffer');
  late final _stop = lib.lookupFunction<Void Function(), void Function()>('fb_stop');
  late final _pause = lib.lookupFunction<Void Function(Int32), void Function(int)>('fb_pause');
  late final _seek = lib.lookupFunction<Void Function(Double), void Function(double)>('fb_seek');
  late final _setRouting = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('fb_set_routing');
  late final _setSpeakerVolume = lib.lookupFunction<Void Function(Double), void Function(double)>(
    'fb_set_speaker_volume',
  );
  late final _setMicVolume = lib.lookupFunction<Void Function(Double), void Function(double)>('fb_set_mic_volume');
  late final _setNormalization = lib
      .lookupFunction<Void Function(Int32, Double, Int32), void Function(int, double, int)>('fb_set_normalization');
  late final _setActivationSound = lib
      .lookupFunction<Void Function(Int32, Pointer<Utf8>), void Function(int, Pointer<Utf8>)>(
        'fb_set_activation_sound',
      );
  late final _getStatus = lib.lookupFunction<Void Function(Pointer<FbStatus>), void Function(Pointer<FbStatus>)>(
    'fb_get_status',
  );
  late final _playNotification = lib
      .lookupFunction<Void Function(Int32, Pointer<Utf8>), void Function(int, Pointer<Utf8>)>('fb_play_notification');
  late final _measureStart = lib.lookupFunction<Void Function(), void Function()>('fb_measure_voice_start');
  late final _measureStop = lib.lookupFunction<Double Function(), double Function()>('fb_measure_voice_stop');
  late final _recStart = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Double, Pointer<Utf8>),
        int Function(Pointer<Utf8>, double, Pointer<Utf8>)
      >('fb_rec_start');
  late final _recStop = lib.lookupFunction<Int64 Function(), int Function()>('fb_rec_stop');
  late final _recActive = lib.lookupFunction<Int32 Function(), int Function()>('fb_rec_active');
  late final _recSeconds = lib.lookupFunction<Double Function(), double Function()>('fb_rec_seconds');
  late final _recPeak = lib.lookupFunction<Float Function(), double Function()>('fb_rec_peak');
  late final _recSetGain = lib.lookupFunction<Void Function(Double), void Function(double)>('fb_rec_set_gain');

  late final _evdevStart = lib.lookupFunction<Int32 Function(), int Function()>('fb_evdev_start');
  late final _evdevStop = lib.lookupFunction<Void Function(), void Function()>('fb_evdev_stop');
  late final _evdevDeviceCount = lib.lookupFunction<Int32 Function(), int Function()>('fb_evdev_device_count');
  late final _evdevSetBlock = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('fb_evdev_set_block');
  late final _evdevSetTable = lib
      .lookupFunction<
        Void Function(Pointer<Int32>, Pointer<Int32>, Int32, Int32),
        void Function(Pointer<Int32>, Pointer<Int32>, int, int)
      >('fb_evdev_set_table');
  late final _x11Start = lib.lookupFunction<Int32 Function(), int Function()>('fb_x11_start');
  late final _x11Stop = lib.lookupFunction<Void Function(), void Function()>('fb_x11_stop');
  late final _x11SetTable = lib
      .lookupFunction<
        Void Function(Pointer<Int32>, Pointer<Int32>, Int32),
        void Function(Pointer<Int32>, Pointer<Int32>, int)
      >('fb_x11_set_table');
  late final _x11ActiveWindow = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Pointer<Int32>, Pointer<Int32>),
        int Function(Pointer<Utf8>, int, Pointer<Int32>, Pointer<Int32>)
      >('fb_x11_active_window');
  late final _uinputOpen = lib.lookupFunction<Int32 Function(), int Function()>('fb_uinput_open');
  late final _uinputClose = lib.lookupFunction<Void Function(), void Function()>('fb_uinput_close');
  late final _uinputKey = lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('fb_uinput_key');

  NativeCallable<_EventNative>? _callable;

  /// Registers a listener for native events. Must be called on the main isolate.
  void setEventListener(void Function(int type, int a, int b, int c) fn) {
    _callable?.close();
    _callable = NativeCallable<_EventNative>.listener(fn);
    _setEventCallback(_callable!.nativeFunction);
  }

  T _withStr<T>(String? s, T Function(Pointer<Utf8>) f) {
    if (s == null) return f(nullptr);
    final p = s.toNativeUtf8();
    try {
      return f(p);
    } finally {
      malloc.free(p);
    }
  }

  // ---------------------------------------------------------------- media
  MediaInfo? probe(String path) {
    final info = calloc<FbMediaInfo>();
    try {
      final r = _withStr(path, (p) => _probe(p, info));
      if (r != 0) return null;
      final i = info.ref;
      return MediaInfo(
        i.duration,
        i.sampleRate,
        i.channels,
        i.size,
        _cstr(i.format, 32),
        _cstr(i.title, 256),
        _cstr(i.artist, 256),
      );
    } finally {
      calloc.free(info);
    }
  }

  DecodedAudio? decode(String path) {
    final out = calloc<Pointer<Float>>();
    final frames = calloc<Int64>();
    final ch = calloc<Int32>();
    try {
      final r = _withStr(path, (p) => _decode(p, out, frames, ch));
      if (r != 0) return null;
      final n = frames.value * ch.value;
      final data = Float32List.fromList(out.value.asTypedList(n));
      _free(out.value.cast());
      return DecodedAudio(data, ch.value);
    } finally {
      calloc.free(out);
      calloc.free(frames);
      calloc.free(ch);
    }
  }

  Pointer<Float> _floatCopy(Float32List data) {
    final p = malloc<Float>(data.isEmpty ? 1 : data.length);
    p.asTypedList(data.length).setAll(0, data);
    return p;
  }

  bool encode(String path, String format, Float32List data, int channels) {
    final p = _floatCopy(data);
    try {
      return _withStr(path, (pp) => _withStr(format, (fp) => _encode(pp, fp, p, data.length ~/ channels, channels))) ==
          0;
    } finally {
      malloc.free(p);
    }
  }

  double loudness(Float32List data, int channels) {
    final p = _floatCopy(data);
    try {
      return _loudness(p, data.length ~/ channels, channels);
    } finally {
      malloc.free(p);
    }
  }

  /// Returns (lufs, peak) or null.
  (double, double)? analyze(String path) {
    final l = calloc<Double>();
    final pk = calloc<Double>();
    try {
      final r = _withStr(path, (p) => _analyze(p, l, pk));
      if (r != 0) return null;
      return (l.value, pk.value);
    } finally {
      calloc.free(l);
      calloc.free(pk);
    }
  }

  // ---------------------------------------------------------------- audio
  int audioInit() => _audioInit();
  void audioShutdown() => _audioShutdown();
  bool get audioConnected => _audioConnected() != 0;

  Map<String, dynamic>? listDevices() {
    final p = _listDevices();
    if (p == nullptr) return null;
    final s = p.toDartString();
    _free(p.cast());
    return jsonDecode(s) as Map<String, dynamic>;
  }

  int vmicSetup(String? micSource, bool setDefault) => _withStr(micSource, (p) => _vmicSetup(p, setDefault ? 1 : 0));
  void vmicTeardown() => _vmicTeardown();
  bool get vmicActive => _vmicActive() != 0;
  void setBlockVoice(bool on) => _setBlockVoice(on ? 1 : 0);
  int setHearMyself(bool on) => _setHearMyself(on ? 1 : 0);
  void setOutputSink(String? sink) => _withStr(sink, _setOutputSink);
  int setDefaultSource(String source) => _withStr(source, _setDefaultSource);

  int play(String path, {required bool speakers, required bool mic, double start = 0, double? lufs}) =>
      _withStr(path, (p) => _play(p, speakers ? 1 : 0, mic ? 1 : 0, start, lufs ?? double.nan));

  int playBuffer(Float32List data, int channels, {required bool speakers, required bool mic}) {
    final p = _floatCopy(data);
    try {
      return _playBuffer(p, data.length ~/ channels, channels, speakers ? 1 : 0, mic ? 1 : 0);
    } finally {
      malloc.free(p);
    }
  }

  void stop() => _stop();
  void pause(bool paused) => _pause(paused ? 1 : 0);
  void seek(double sec) => _seek(sec);
  void setRouting(bool speakers, bool mic) => _setRouting(speakers ? 1 : 0, mic ? 1 : 0);
  void setSpeakerVolume(double v) => _setSpeakerVolume(v);
  void setMicVolume(double v) => _setMicVolume(v);
  void setNormalization(bool enabled, double target, bool dynamic) =>
      _setNormalization(enabled ? 1 : 0, target, dynamic ? 1 : 0);
  void setActivationSound(bool enabled, String? path) => _withStr(path, (p) => _setActivationSound(enabled ? 1 : 0, p));

  final Pointer<FbStatus> _status = calloc<FbStatus>();
  PlaybackStatus status() {
    _getStatus(_status);
    final s = _status.ref;
    return PlaybackStatus(
      s.state,
      s.id,
      s.position,
      s.duration,
      s.toSpeakers != 0,
      s.toMic != 0,
      s.micPeak,
      s.outputPeak,
    );
  }

  void playNotification(int kind, String? path) => _withStr(path, (p) => _playNotification(kind, p));
  void measureVoiceStart() => _measureStart();
  double measureVoiceStop() => _measureStop();

  int recStart(String? source, double maxSeconds, String tempPath) =>
      _withStr(source, (s) => _withStr(tempPath, (t) => _recStart(s, maxSeconds, t)));
  int recStop() => _recStop();
  bool get recActive => _recActive() != 0;
  double get recSeconds => _recSeconds();
  double recPeak() => _recPeak();
  void recSetGain(double g) => _recSetGain(g);

  // ---------------------------------------------------------------- input
  int evdevStart() => _evdevStart();
  void evdevStop() => _evdevStop();
  int get evdevDeviceCount => _evdevDeviceCount();
  int evdevSetBlock(bool on) => _evdevSetBlock(on ? 1 : 0);
  void evdevSetTable(List<(int, int)> table, bool sided) {
    final m = malloc<Int32>(table.length + 1);
    final c = malloc<Int32>(table.length + 1);
    for (var i = 0; i < table.length; i++) {
      m[i] = table[i].$1;
      c[i] = table[i].$2;
    }
    _evdevSetTable(m, c, table.length, sided ? 1 : 0);
    malloc.free(m);
    malloc.free(c);
  }

  int x11Start() => _x11Start();
  void x11Stop() => _x11Stop();
  void x11SetTable(List<(int, int)> table) {
    final m = malloc<Int32>(table.length + 1);
    final c = malloc<Int32>(table.length + 1);
    for (var i = 0; i < table.length; i++) {
      m[i] = table[i].$1;
      c[i] = table[i].$2;
    }
    _x11SetTable(m, c, table.length);
    malloc.free(m);
    malloc.free(c);
  }

  /// (wmClass, pid, fullscreen) of the active X11 window.
  (String, int, bool)? x11ActiveWindow() {
    final cls = malloc<Uint8>(256);
    final pid = calloc<Int32>();
    final fs = calloc<Int32>();
    try {
      if (_x11ActiveWindow(cls.cast(), 256, pid, fs) != 0) return null;
      return (cls.cast<Utf8>().toDartString(), pid.value, fs.value != 0);
    } finally {
      malloc.free(cls);
      calloc.free(pid);
      calloc.free(fs);
    }
  }

  int uinputOpen() => _uinputOpen();
  void uinputClose() => _uinputClose();
  int uinputKey(int code, int value) => _uinputKey(code, value);
}
