// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:fboard/models/hotkey.dart';
import 'package:fboard/models/settings.dart';
import 'package:fboard/models/sound_list.dart';
import 'package:fboard/services/dsp.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hotkey', () {
    test('labels', () {
      expect(const Hotkey(Mod.ctrl, 59).label(), 'Ctrl+F1');
      expect(const Hotkey(Mod.rctrl | Mod.shift, 30).label(), 'Ctrl+Shift+A');
      expect(const Hotkey(Mod.rctrl, 59).label(sided: true), 'RCtrl+F1');
      expect(const Hotkey(0, Btn.side).label(), 'Mouse 4');
    });

    test('matching folds left/right modifiers unless sided', () {
      const h = Hotkey(Mod.lctrl, 59);
      expect(h.matches(Mod.rctrl, 59, sided: false), isTrue);
      expect(h.matches(Mod.rctrl, 59, sided: true), isFalse);
      expect(h.matches(Mod.lctrl | Mod.lshift, 59, sided: false), isFalse);
    });

    test('plain left/right click and modifier-only keys are not allowed', () {
      expect(const Hotkey(0, Btn.left).isAllowed, isFalse);
      expect(const Hotkey(Mod.ctrl, Btn.left).isAllowed, isTrue);
      expect(const Hotkey(0, 29).isAllowed, isFalse);
    });

    test('portal triggers', () {
      expect(const Hotkey(Mod.ctrl | Mod.shift, 30).portalTrigger, 'CTRL+SHIFT+a');
      expect(const Hotkey(Mod.meta, 82).portalTrigger, 'LOGO+KP_0');
      expect(const Hotkey(0, Btn.middle).portalTrigger, isNull);
    });

    test('Flutter physical keys map to evdev codes', () {
      expect(evdevFromPhysical(PhysicalKeyboardKey.keyA), 30);
      expect(evdevFromPhysical(PhysicalKeyboardKey.f1), 59);
      expect(evdevFromPhysical(PhysicalKeyboardKey.numpad7), 71);
      expect(evdevFromPhysical(PhysicalKeyboardKey.controlRight), 97);
    });

    test('digits', () {
      expect(numpadDigit(82), 0);
      expect(anyDigit(2), 1);
      expect(anyDigit(11), 0);
      expect(anyDigit(30), isNull);
    });
  });

  group('SoundList', () {
    test('JSON round trip keeps everything', () {
      final a = Sound(path: '/a.mp3', title: 'A', artist: 'X', duration: 1.5, hotkey: const Hotkey(Mod.alt, 2));
      final b = Sound(path: '/b.wav');
      final child = SoundCategory(name: 'Child', soundIds: [b.id]);
      final cat = SoundCategory(name: 'Cat', soundIds: [a.id], children: [child], randomHotkey: const Hotkey(0, 60));
      final list = SoundList(sounds: [a, b], categories: [cat])
        ..hotbar.pages[0][3] = HotbarEntry(a.id, color: 0xFF112233)
        ..hotbar.cellHotkeys[3] = const Hotkey(Mod.ctrl, 4)
        ..rowHotkeys[0] = const Hotkey(0, 61);

      final copy = SoundList.fromJson(jsonDecode(jsonEncode(list.toJson())) as Map<String, dynamic>);
      expect(copy.sounds.map((s) => s.id), [a.id, b.id]);
      expect(copy.sounds.first.hotkey, const Hotkey(Mod.alt, 2));
      expect(copy.categories.single.children.single.parent?.name, 'Cat');
      expect(copy.categories.single.randomHotkey, const Hotkey(0, 60));
      expect(copy.hotbar.pages[0][3]?.soundId, a.id);
      expect(copy.hotbar.pages[0][3]?.color, 0xFF112233);
      expect(copy.hotbar.cellHotkeys[3], const Hotkey(Mod.ctrl, 4));
      expect(copy.rowHotkeys[0], const Hotkey(0, 61));
    });

    test('tag falls back to the file name', () {
      expect(Sound(path: '/x/Funny Sound.mp3').tag, 'Funny Sound');
      expect(Sound(path: '/x.mp3', title: 'T', artist: 'A').tag, 'A - T');
      expect(Sound(path: '/x.mp3', artist: 'A').tag, 'A');
    });

    test('removing sounds cleans categories and hotbar', () {
      final a = Sound(path: '/a.mp3');
      final cat = SoundCategory(name: 'C', soundIds: [a.id]);
      final list = SoundList(sounds: [a], categories: [cat])..hotbar.pages[0][0] = HotbarEntry(a.id);
      list.removeSounds({a.id});
      expect(list.sounds, isEmpty);
      expect(cat.soundIds, isEmpty);
      expect(list.hotbar.pages[0][0], isNull);
    });

    test('ancestor checks prevent moving a category into itself', () {
      final c = SoundCategory(name: 'c');
      final b = SoundCategory(name: 'b', children: [c]);
      final a = SoundCategory(name: 'a', children: [b]);
      expect(a.isAncestorOf(c), isTrue);
      expect(c.isAncestorOf(a), isFalse);
      expect(c.depth, 2);
    });
  });

  group('Settings', () {
    test('round trip', () {
      final s = Settings()
        ..playMode = PlayMode.mic
        ..specialHotkeys[SpecialAction.stop] = const Hotkey(Mod.ctrl, 1)
        ..autoKeys.add(AutoKey(code: 37, when: AutoKeyWhen.running, apps: ['cs2']))
        ..normalizeTarget = -18;
      final c = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(c.playMode, PlayMode.mic);
      expect(c.specialHotkeys[SpecialAction.stop], const Hotkey(Mod.ctrl, 1));
      expect(c.autoKeys.single.apps, ['cs2']);
      expect(c.autoKeys.single.when, AutoKeyWhen.running);
      expect(c.normalizeTarget, -18);
    });

    test('unknown or missing values fall back to defaults', () {
      final c = Settings.fromJson({'playMode': 'nonsense', 'speakerVolume': 1});
      expect(c.playMode, PlayMode.both);
      expect(c.speakerVolume, 1.0);
      expect(c.columnOrder.toSet(), allColumns.keys.toSet());
    });
  });

  group('DSP', () {
    test('trimSilence keeps a little padding', () {
      final d = Float32List(48000 * 2); // 1 s stereo
      for (var i = 24000 * 2; i < 25000 * 2; i++) {
        d[i] = 0.5;
      }
      final t = trimSilence(d, 2);
      final frames = t.length ~/ 2;
      expect(frames, greaterThan(1000));
      expect(frames, lessThan(1000 + 2 * 960 + 2));
    });

    test('normalization gain respects the peak', () {
      expect(normalizationGain(-30, -20, 0.1), closeTo(3.1623, 1e-3));
      expect(normalizationGain(-30, -10, 0.5), closeTo(0.999 / 0.5, 1e-9));
      expect(normalizationGain(double.negativeInfinity, -20, 0.1), 1);
    });

    test('Soundpad dB scale', () {
      expect(lufsToSoundpadDb(-23), 89);
      expect(soundpadDbToLufs(89), -23);
    });

    test('durations', () {
      expect(formatDuration(65), '01:05');
      expect(formatDuration(3725), '1:02:05');
      expect(formatDuration(1.25, millis: true), '00:01.250');
    });
  });
}
