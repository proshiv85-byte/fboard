// SPDX-License-Identifier: GPL-3.0-or-later
// Auto Keys: presses keys (e.g. a game's push-to-talk) while a sound plays,
// through a uinput virtual device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../models/hotkey.dart';
import '../models/settings.dart';
import 'hotkey_service.dart';

class ActiveWindow {
  final String appClass;
  final int pid;
  final bool fullscreen;
  final String processName;
  ActiveWindow(this.appClass, this.pid, this.fullscreen, this.processName);
}

class AutoKeysService {
  final AppController app;
  AutoKeysService(this.app);

  final List<AutoKey> _held = [];
  final List<AutoKey> _tapAfter = [];
  bool _uinputOk = false;
  bool _uinputReported = false;

  bool _ensureUinput() {
    if (_uinputOk) return true;
    final r = app.native.uinputOpen();
    _uinputOk = r == 0;
    if (!_uinputOk && !_uinputReported) {
      _uinputReported = true;
      app.notify(
        'Auto Keys need write access to /dev/uinput (error $r). Install the fboard udev rule or add your user to the "input" group.',
        NoticeLevel.error,
      );
    }
    return _uinputOk;
  }

  Future<void> onPlaybackStart({required bool byHotkey, required PlayMode mode}) async {
    final s = app.settings;
    if (!s.autoKeysEnabled || mode == PlayMode.speakers) return;
    final candidates = s.autoKeys.where((k) => k.enabled && (byHotkey || !k.onlyHotkey)).toList();
    if (candidates.isEmpty) return;
    final win = candidates.any((k) => k.when == AutoKeyWhen.fullscreen || k.when == AutoKeyWhen.foreground)
        ? await activeWindow()
        : null;
    final procs = candidates.any((k) => k.when == AutoKeyWhen.running) ? runningProcesses() : <String>{};
    var pressed = false;
    for (final k in candidates) {
      if (!_conditionMet(k, win, procs)) continue;
      if (!_ensureUinput()) return;
      if (k.press == AutoKeyPress.hold) {
        if (_held.contains(k)) continue;
        app.native.uinputKey(k.code, 1);
        _held.add(k);
      } else {
        await _tap(k.code);
        _tapAfter.add(k);
      }
      pressed = true;
    }
    // Give voice apps a moment to open the microphone.
    if (pressed) await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  void onPlaybackEnd() {
    for (final k in _held) {
      app.native.uinputKey(k.code, 0);
    }
    _held.clear();
    final taps = [..._tapAfter];
    _tapAfter.clear();
    for (final k in taps) {
      _tap(k.code);
    }
  }

  void releaseAll() => onPlaybackEnd();

  Future<void> _tap(int code) async {
    app.native.uinputKey(code, 1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    app.native.uinputKey(code, 0);
  }

  bool _conditionMet(AutoKey k, ActiveWindow? win, Set<String> procs) {
    bool matchesApp(String name) => k.apps.any((a) => _sameApp(a, name));
    switch (k.when) {
      case AutoKeyWhen.always:
        return true;
      case AutoKeyWhen.fullscreen:
        return win?.fullscreen ?? false;
      case AutoKeyWhen.running:
        return procs.any(matchesApp);
      case AutoKeyWhen.foreground:
        if (win == null) return false;
        return matchesApp(win.appClass) || matchesApp(win.processName);
    }
  }

  static bool _sameApp(String configured, String actual) {
    String norm(String s) {
      s = s.trim().toLowerCase();
      if (s.endsWith('.exe')) s = s.substring(0, s.length - 4);
      return s;
    }

    final a = norm(configured), b = norm(actual);
    if (a.isEmpty || b.isEmpty) return false;
    // /proc/*/comm is truncated to 15 characters.
    return a == b || (b.length == 15 && a.startsWith(b));
  }

  // ------------------------------------------------------------ processes
  static Set<String> runningProcesses() {
    final out = <String>{};
    for (final e in Directory('/proc').listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (int.tryParse(name) == null) continue;
      try {
        out.add(File('${e.path}/comm').readAsStringSync().trim());
        final cmd = File('${e.path}/cmdline').readAsStringSync();
        final argv0 = cmd.split('\u0000').first;
        if (argv0.isNotEmpty) out.add(p.basename(argv0.replaceAll('\\', '/')));
      } catch (_) {}
    }
    return out;
  }

  static String processName(int pid) {
    if (pid <= 0) return '';
    try {
      return File('/proc/$pid/comm').readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }

  // ------------------------------------------------------------ active window
  /// How the active window can be detected on this desktop, or null.
  String? get windowDetectionMethod {
    final env = Platform.environment;
    if (env['HYPRLAND_INSTANCE_SIGNATURE'] != null) return 'Hyprland IPC';
    if (env['SWAYSOCK'] != null) return 'Sway IPC';
    if (HotkeyService.isX11Session) return 'X11';
    return null;
  }

  Future<ActiveWindow?> activeWindow() async {
    final env = Platform.environment;
    try {
      if (env['HYPRLAND_INSTANCE_SIGNATURE'] != null) return await _hyprland(env['HYPRLAND_INSTANCE_SIGNATURE']!);
      if (env['SWAYSOCK'] != null) return await _sway(env['SWAYSOCK']!);
      if (HotkeyService.isX11Session) {
        final w = app.native.x11ActiveWindow();
        if (w == null) return null;
        return ActiveWindow(w.$1, w.$2, w.$3, processName(w.$2));
      }
    } catch (_) {}
    return null;
  }

  Future<ActiveWindow?> _hyprland(String sig) async {
    final runtime = Platform.environment['XDG_RUNTIME_DIR'] ?? '/run/user/0';
    var path = '$runtime/hypr/$sig/.socket.sock';
    if (!File(path).existsSync()) path = '/tmp/hypr/$sig/.socket.sock';
    final sock = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0);
    sock.write('j/activewindow');
    await sock.flush();
    final data = await sock.fold<List<int>>([], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 1));
    sock.destroy();
    final j = jsonDecode(utf8.decode(data));
    if (j is! Map) return null;
    final fs = j['fullscreen'];
    final pid = (j['pid'] as num?)?.toInt() ?? 0;
    return ActiveWindow(j['class'] as String? ?? '', pid, fs == true || (fs is num && fs > 0), processName(pid));
  }

  Future<ActiveWindow?> _sway(String path) async {
    final sock = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0);
    final header = BytesBuilder()
      ..add(ascii.encode('i3-ipc'))
      ..add(
        (ByteData(8)
              ..setUint32(0, 0, Endian.host)
              ..setUint32(4, 4, Endian.host)) // GET_TREE
            .buffer
            .asUint8List(),
      );
    sock.add(header.toBytes());
    await sock.flush();
    final buf = BytesBuilder();
    int? need;
    await for (final chunk in sock.timeout(const Duration(seconds: 1))) {
      buf.add(chunk);
      final b = buf.toBytes();
      if (need == null && b.length >= 14) {
        need = 14 + ByteData.sublistView(Uint8List.fromList(b), 6, 10).getUint32(0, Endian.host);
      }
      if (need != null && b.length >= need) break;
    }
    sock.destroy();
    final bytes = buf.toBytes();
    final tree = jsonDecode(utf8.decode(bytes.sublist(14)));
    Map? focused;
    void walk(dynamic n) {
      if (n is! Map || focused != null) return;
      if (n['focused'] == true && (n['pid'] != null)) {
        focused = n;
        return;
      }
      for (final c in [...(n['nodes'] as List? ?? []), ...(n['floating_nodes'] as List? ?? [])]) {
        walk(c);
      }
    }

    walk(tree);
    final f = focused;
    if (f == null) return null;
    final cls = (f['app_id'] as String?) ?? ((f['window_properties'] as Map?)?['class'] as String?) ?? '';
    final pid = (f['pid'] as num?)?.toInt() ?? 0;
    return ActiveWindow(cls, pid, (f['fullscreen_mode'] as num? ?? 0) > 0, processName(pid));
  }

  // ------------------------------------------------------------ troubleshooting
  /// Explains for each auto key whether it would fire right now.
  Future<List<String>> troubleshoot({required bool byHotkey}) async {
    final s = app.settings;
    final out = <String>[];
    if (!s.autoKeysEnabled) out.add('Auto Keys are disabled (status bar / special hotkey).');
    if (s.playMode == PlayMode.speakers) out.add('Play mode is "speakers only": Auto Keys never fire in this mode.');
    if (!_ensureUinput()) out.add('/dev/uinput is not writable, keys cannot be pressed.');
    final win = await activeWindow();
    final method = windowDetectionMethod;
    if (method == null) {
      out.add(
        'This desktop does not expose the active window, so "fullscreen" and "in foreground" conditions '
        'cannot be detected.',
      );
    } else if (win != null) {
      out.add(
        'Active window ($method): ${win.appClass} (process ${win.processName}, '
        '${win.fullscreen ? 'fullscreen' : 'not fullscreen'}).',
      );
    }
    final procs = runningProcesses();
    for (final k in s.autoKeys) {
      final name = k.name.isEmpty ? keyName(k.code) : k.name;
      final problems = <String>[];
      if (!k.enabled) problems.add('it is disabled');
      if (k.onlyHotkey && !byHotkey) problems.add('it only fires for sounds played by hotkey');
      if (!_conditionMet(k, win, procs)) {
        problems.add(switch (k.when) {
          AutoKeyWhen.fullscreen => 'the foreground application is not fullscreen',
          AutoKeyWhen.running => 'none of ${k.apps.join(', ')} is running',
          AutoKeyWhen.foreground => 'none of ${k.apps.join(', ')} is in the foreground',
          AutoKeyWhen.always => '',
        });
      }
      out.add(problems.isEmpty ? '✔ $name (${keyName(k.code)}) would be pressed.' : '✘ $name: ${problems.join('; ')}.');
    }
    if (s.autoKeys.isEmpty) out.add('No Auto Keys are configured.');
    return out;
  }
}
