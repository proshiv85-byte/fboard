// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import '../app/controller.dart';
import '../models/hotkey.dart';
import '../models/settings.dart';
import 'portal_shortcuts.dart';

typedef KeyCapture = void Function(int code, bool down, int mods);

class _Binding {
  final Hotkey key;
  final String id; // stable id (used by the portal)
  final String description;
  final void Function() action;
  _Binding(this.key, this.id, this.description, this.action);
}

/// Global hotkeys. Picks a backend that works on the current desktop:
///  * evdev  – reads /dev/input directly; works everywhere (X11, any Wayland
///             compositor, even the console). Needs the user in the "input"
///             group. Supports mouse buttons, numpad codes and blocking.
///  * x11    – XGrabKey on X11 sessions.
///  * portal – org.freedesktop.portal.GlobalShortcuts (KDE, GNOME 48+,
///             Hyprland…); the desktop decides the final key binding.
class HotkeyService {
  final AppController app;
  HotkeyService(this.app);

  HotkeyBackend? active;
  String? error;
  List<_Binding> _bindings = [];
  PortalShortcuts? _portal;
  Timer? _portalDebounce;
  final Set<int> _down = {};

  /// When set, raw key events go here instead of triggering hotkeys
  /// (used by the hotkey dialog).
  KeyCapture? capture;

  // numcode state
  String _numBuffer = '';
  Timer? _numTimer;

  bool get canCaptureRaw => active == HotkeyBackend.evdev;
  bool get supportsMouse => active == HotkeyBackend.evdev || active == HotkeyBackend.x11;
  bool get supportsNumcode => active == HotkeyBackend.evdev || active == HotkeyBackend.x11;

  static bool get isX11Session {
    final t = Platform.environment['XDG_SESSION_TYPE'];
    if (t == 'x11') return true;
    if (t == 'wayland') return false;
    return Platform.environment['DISPLAY'] != null && Platform.environment['WAYLAND_DISPLAY'] == null;
  }

  void start() {
    error = null;
    final want = app.settings.hotkeyBackend;
    final n = app.native;
    if (want == HotkeyBackend.auto || want == HotkeyBackend.evdev) {
      final r = n.evdevStart();
      if (r == 0) {
        active = HotkeyBackend.evdev;
      } else if (want == HotkeyBackend.evdev) {
        error =
            'Cannot read input devices (${r == -13 ? 'permission denied' : 'error $r'}). '
            'Add your user to the "input" group and log in again.';
      }
    }
    if (active == null && (want == HotkeyBackend.x11 || (want == HotkeyBackend.auto && isX11Session))) {
      if (n.x11Start() == 0) {
        active = HotkeyBackend.x11;
      } else if (want == HotkeyBackend.x11) {
        error = 'Could not connect to the X server.';
      }
    }
    if (active == null && (want == HotkeyBackend.portal || want == HotkeyBackend.auto)) {
      active = HotkeyBackend.portal;
      _portal = PortalShortcuts(
        onActivated: _onPortalActivated,
        onError: (e) {
          error = e;
          app.notify('Global shortcuts portal: $e', NoticeLevel.warning);
        },
      );
    }
    if (error != null) app.notify(error!, NoticeLevel.warning);
    rebuild();
  }

  void stop() {
    switch (active) {
      case HotkeyBackend.evdev:
        app.native.evdevSetBlock(false);
        app.native.evdevStop();
      case HotkeyBackend.x11:
        app.native.x11Stop();
      case HotkeyBackend.portal:
        _portal?.close();
        _portal = null;
      default:
    }
    active = null;
    _down.clear();
  }

  void restart() {
    stop();
    start();
    app.refresh();
  }

  /// Rebuilds the binding table (after any change of hotkeys or settings).
  void rebuild() {
    final s = app.settings;
    final list = app.list;
    final b = <_Binding>[];
    void add(Hotkey? h, String id, String desc, void Function() fn) {
      if (h != null) b.add(_Binding(h, id, desc, fn));
    }

    for (final e in s.specialHotkeys.entries) {
      add(e.value, 'special-${e.key.name}', e.key.label, () => runSpecial(e.key));
    }
    if (s.sameHotkeysInAllCategories) {
      for (final e in list.rowHotkeys.entries) {
        final row = e.key;
        add(e.value, 'row-$row', 'Play row ${row + 1} of the selected category', () {
          final v = list.soundsOf(app.selectedCategory);
          if (row < v.length) app.play(v[row], byHotkey: true);
        });
      }
    } else {
      for (final snd in list.sounds) {
        add(snd.hotkey, 'sound-${snd.id}', 'Play ${snd.tag}', () => app.play(snd, byHotkey: true));
      }
    }
    for (final c in list.allCategories) {
      add(
        c.randomHotkey,
        'category-${c.id}',
        'Play random file from ${c.name}',
        () => app.playRandom(from: c, byHotkey: true),
      );
    }
    for (final e in list.hotbar.cellHotkeys.entries) {
      final cell = e.key;
      add(e.value, 'hotbar-$cell', 'Hotbar button ${cell + 1}', () {
        final hb = list.hotbar;
        final entry = hb.pages[hb.page][cell];
        final snd = entry == null ? null : list.byId(entry.soundId);
        if (snd != null) app.play(snd, byHotkey: true);
      });
    }
    if (s.indexHotkeysEnabled) {
      for (var d = 0; d <= 9; d++) {
        final idx = d == 0 ? 9 : d - 1;
        void fn() {
          if (idx < list.sounds.length) app.play(list.sounds[idx], byHotkey: true);
        }

        add(Hotkey(s.indexHotkeyMods, d == 0 ? 11 : d + 1), 'index-$d', 'Play sound #${idx + 1}', fn);
        add(
          Hotkey(s.indexHotkeyMods, const [82, 79, 80, 81, 75, 76, 77, 71, 72, 73][d]),
          'index-num-$d',
          'Play sound #${idx + 1}',
          fn,
        );
      }
    }
    _bindings = b;
    _pushTable();
  }

  List<_Binding> get _activeBindings {
    if (app.settings.hotkeysEnabled) return _bindings;
    return _bindings
        .where((b) => b.id.startsWith('special-') && SpecialAction.values.byName(b.id.substring(8)).alwaysActive)
        .toList();
  }

  void _pushTable() {
    final s = app.settings;
    final table = <(int, int)>[for (final b in _activeBindings) (b.key.mods, b.key.code)];
    if (s.numcodeEnabled && s.hotkeysEnabled) {
      for (final code in const [82, 79, 80, 81, 75, 76, 77, 71, 72, 73]) {
        table.add((s.numcodeMods, code));
      }
    }
    switch (active) {
      case HotkeyBackend.evdev:
        app.native.evdevSetTable(table, s.sidedModifiers);
        final r = app.native.evdevSetBlock(!s.passHotkeys);
        if (r != 0 && !s.passHotkeys) {
          app.notify(
            'Hotkeys cannot be blocked: /dev/uinput is not writable. Hotkeys are passed to other apps.',
            NoticeLevel.warning,
          );
        }
      case HotkeyBackend.x11:
        app.native.x11SetTable(table);
      case HotkeyBackend.portal:
        _portalDebounce?.cancel();
        _portalDebounce = Timer(const Duration(seconds: 2), () {
          _portal?.bind([for (final b in _activeBindings) PortalShortcut(b.id, b.description, b.key.portalTrigger)]);
        });
      default:
    }
  }

  // ------------------------------------------------------------ events
  void onKey(int code, int value, int mods) {
    final down = value != 0;
    if (capture != null) {
      capture!(code, down, mods);
      return;
    }
    if (!down) {
      _down.remove(code);
      // Numcode commits when the modifier is released.
      if (Mod.bitForCode(code) != 0 && _numBuffer.isNotEmpty) {
        final rest = mods & ~Mod.bitForCode(code);
        if (!_modsMatch(rest, app.settings.numcodeMods)) _commitNumcode();
      }
      return;
    }
    if (!_down.add(code)) return; // auto-repeat
    if (Mod.bitForCode(code) != 0) return;

    final s = app.settings;
    if (s.numcodeEnabled && s.hotkeysEnabled && supportsNumcode) {
      final d = numpadDigit(code);
      if (d != null && _modsMatch(mods, s.numcodeMods)) {
        _numBuffer += '$d';
        _numTimer?.cancel();
        // X11 doesn't report the modifier release; commit after a pause.
        _numTimer = Timer(const Duration(milliseconds: 1500), _commitNumcode);
        return;
      }
    }
    for (final b in _activeBindings) {
      if (b.key.matches(mods, code, sided: s.sidedModifiers)) {
        b.action();
        return;
      }
    }
  }

  bool _modsMatch(int mask, int want) =>
      app.settings.sidedModifiers ? mask == want : Mod.unsided(mask) == Mod.unsided(want);

  void _commitNumcode() {
    _numTimer?.cancel();
    final n = int.tryParse(_numBuffer);
    _numBuffer = '';
    if (n == null || n < 1) return;
    final sounds = app.list.sounds;
    if (n <= sounds.length) app.play(sounds[n - 1], byHotkey: true);
  }

  void _onPortalActivated(String id) {
    if (capture != null) return;
    for (final b in _activeBindings) {
      if (b.id == id) {
        b.action();
        return;
      }
    }
  }

  // ------------------------------------------------------------ overview
  List<(String, String)> overview() => [
    for (final b in _bindings) (b.key.label(sided: app.settings.sidedModifiers), b.description),
  ];

  // ------------------------------------------------------------ actions
  void runSpecial(SpecialAction a) {
    final s = app.settings;
    switch (a) {
      case SpecialAction.stop:
        app.stop();
      case SpecialAction.play:
        app.playOrResume(byHotkey: true);
      case SpecialAction.pauseResume:
        app.pauseResume();
      case SpecialAction.playPrevious:
        app.playPrevious(byHotkey: true);
      case SpecialAction.playNext:
        app.playNext(byHotkey: true);
      case SpecialAction.selectPrevious:
        app.moveFocus(-1);
      case SpecialAction.selectNext:
        app.moveFocus(1);
      case SpecialAction.playSelected:
        app.playSelected(byHotkey: true);
      case SpecialAction.playSelectedSpeakers:
        app.playSelected(mode: PlayMode.speakers, byHotkey: true);
      case SpecialAction.playSelectedMic:
        app.playSelected(mode: PlayMode.mic, byHotkey: true);
      case SpecialAction.playRandom:
        app.playRandom(byHotkey: true);
      case SpecialAction.playRandomAll:
        app.playRandom(allCategories: true, byHotkey: true);
      case SpecialAction.playRandomSpeakers:
        app.playRandom(mode: PlayMode.speakers, byHotkey: true);
      case SpecialAction.playRandomMic:
        app.playRandom(mode: PlayMode.mic, byHotkey: true);
      case SpecialAction.selectPreviousCategory:
        app.selectRelativeCategory(-1);
      case SpecialAction.selectNextCategory:
        app.selectRelativeCategory(1);
      case SpecialAction.startRecording:
        app.recorder.start(byHotkey: true);
      case SpecialAction.stopRecording:
        app.recorder.stop(byHotkey: true);
      case SpecialAction.toggleRecording:
        app.recorder.active ? app.recorder.stop(byHotkey: true) : app.recorder.start(byHotkey: true);
      case SpecialAction.jumpBack:
        app.jump(-s.jumpSeconds);
      case SpecialAction.jumpForward:
        app.jump(s.jumpSeconds);
      case SpecialAction.volumeDown:
        app.setSpeakerVolume(s.speakerVolume - s.volumeStep);
      case SpecialAction.volumeUp:
        app.setSpeakerVolume(s.speakerVolume + s.volumeStep);
      case SpecialAction.volumeSet:
        app.setSpeakerVolume(s.volumeSetValue);
      case SpecialAction.muteSpeakers:
        app.toggleSpeakerMute();
      case SpecialAction.modeDefault:
        app.setPlayMode(PlayMode.both, byHotkey: true);
      case SpecialAction.modeSpeakers:
        app.setPlayMode(PlayMode.speakers, byHotkey: true);
      case SpecialAction.modeMic:
        app.setPlayMode(PlayMode.mic, byHotkey: true);
      case SpecialAction.modeNext:
        app.nextPlayMode(byHotkey: true);
      case SpecialAction.autoKeysEnable:
        _toggleAutoKeys(true);
      case SpecialAction.autoKeysDisable:
        _toggleAutoKeys(false);
      case SpecialAction.autoKeysToggle:
        _toggleAutoKeys(!s.autoKeysEnabled);
      case SpecialAction.hotkeysEnable:
        _toggleHotkeys(true);
      case SpecialAction.hotkeysDisable:
        _toggleHotkeys(false);
      case SpecialAction.hotkeysToggle:
        _toggleHotkeys(!s.hotkeysEnabled);
      case SpecialAction.toggleRepeat:
        app.toggleRepeat();
      case SpecialAction.toggleContinue:
        app.toggleContinue();
      case SpecialAction.toggleHearMyself:
        app.toggleHearMyself();
      case SpecialAction.toggleBlockVoice:
        app.toggleBlockVoice();
      case SpecialAction.showWindow:
        _toggleWindow();
    }
  }

  void _toggleHotkeys(bool on) {
    app.toggleHotkeysEnabled(on);
    final n = app.settings.notifyHotkeysToggle;
    if (n.enabled) app.native.playNotification(on ? 2 : 3, n.path);
  }

  void _toggleAutoKeys(bool on) {
    app.toggleAutoKeys(on);
    final n = app.settings.notifyAutoKeysToggle;
    if (n.enabled) app.native.playNotification(on ? 2 : 3, n.path);
  }

  Future<void> _toggleWindow() async {
    if (await windowManager.isVisible() && await windowManager.isFocused()) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }
}
