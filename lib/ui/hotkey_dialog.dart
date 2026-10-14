// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../models/hotkey.dart';
import '../models/settings.dart';
import '../models/sound_list.dart';

/// Result of the hotkey dialog: [hotkey] null with [removed] = remove.
class HotkeyResult {
  final Hotkey? hotkey;
  final bool removed;
  HotkeyResult(this.hotkey, {this.removed = false});
}

Future<void> showHotkeyDialogForSound(BuildContext context, Sound s) async {
  final r = await captureHotkey(context, title: 'Hotkey for "${s.tag}"', current: app.hotkeyOf(s));
  if (r != null) app.setSoundHotkey(s, r.hotkey);
}

Future<void> showHotkeyDialogForCategory(BuildContext context, SoundCategory c) async {
  final r = await captureHotkey(context, title: 'Random file hotkey for "${c.name}"', current: c.randomHotkey);
  if (r != null) app.setCategoryHotkey(c, r.hotkey);
}

Future<void> showHotkeyDialogForHotbar(BuildContext context, int cell) async {
  final r = await captureHotkey(
    context,
    title: 'Hotkey for hotbar button ${cell + 1}',
    current: app.list.hotbar.cellHotkeys[cell],
  );
  if (r != null) app.setHotbarHotkey(cell, r.hotkey);
}

/// Opens the capture dialog. With [singleKey] any one key (including
/// modifiers) is accepted, which is what Auto Keys need.
Future<HotkeyResult?> captureHotkey(
  BuildContext context, {
  required String title,
  Hotkey? current,
  bool singleKey = false,
  bool checkConflicts = true,
}) {
  return showDialog<HotkeyResult>(
    context: context,
    builder: (_) => _HotkeyDialog(title, current, singleKey, checkConflicts),
  );
}

class _HotkeyDialog extends StatefulWidget {
  final String title;
  final Hotkey? current;
  final bool singleKey;
  final bool checkConflicts;
  const _HotkeyDialog(this.title, this.current, this.singleKey, this.checkConflicts);
  @override
  State<_HotkeyDialog> createState() => _HotkeyDialogState();
}

class _HotkeyDialogState extends State<_HotkeyDialog> {
  Hotkey? _key;
  int _liveMods = 0;
  final _focus = FocusNode();
  late final bool _raw = app.hotkeys.canCaptureRaw;

  @override
  void initState() {
    super.initState();
    _key = widget.current;
    if (_raw) app.hotkeys.capture = _onRaw;
  }

  @override
  void dispose() {
    if (_raw) app.hotkeys.capture = null;
    _focus.dispose();
    super.dispose();
  }

  bool get _sided => app.settings.sidedModifiers;

  // Dialog keys (without modifiers): Esc cancels, Enter saves, Del/Backspace removes.
  bool _dialogKey(int code, int mods) {
    if (mods != 0 || widget.singleKey && code != 1) return false;
    switch (code) {
      case 1:
        Navigator.pop(context);
        return true;
      case 28:
      case 96:
        _save();
        return true;
      case 111:
      case 14:
        Navigator.pop(context, HotkeyResult(null, removed: true));
        return true;
    }
    return false;
  }

  void _accept(int code, int mods) {
    if (widget.singleKey) {
      if (code == Btn.left || code == Btn.right) return;
      setState(() => _key = Hotkey(0, code));
      return;
    }
    final h = Hotkey(_sided ? mods : Mod.unsided(mods), code);
    if (h.isModifierOnly) return;
    if (!h.isAllowed) return;
    if (h.isMouse && !app.hotkeys.supportsMouse) return;
    setState(() => _key = h);
  }

  void _onRaw(int code, bool down, int mods) {
    if (!mounted) return;
    final bit = Mod.bitForCode(code);
    if (bit != 0) {
      setState(() => _liveMods = down ? (mods | bit) : (mods & ~bit));
      if (down && widget.singleKey) _accept(code, 0);
      return;
    }
    if (!down) return;
    if (_dialogKey(code, mods)) return;
    _accept(code, mods);
  }

  int _flutterMods() {
    final k = HardwareKeyboard.instance.logicalKeysPressed;
    var m = 0;
    if (k.contains(LogicalKeyboardKey.controlLeft)) m |= Mod.lctrl;
    if (k.contains(LogicalKeyboardKey.controlRight)) m |= Mod.rctrl;
    if (k.contains(LogicalKeyboardKey.shiftLeft)) m |= Mod.lshift;
    if (k.contains(LogicalKeyboardKey.shiftRight)) m |= Mod.rshift;
    if (k.contains(LogicalKeyboardKey.altLeft)) m |= Mod.lalt;
    if (k.contains(LogicalKeyboardKey.altRight)) m |= Mod.ralt;
    if (k.contains(LogicalKeyboardKey.metaLeft)) m |= Mod.lmeta;
    if (k.contains(LogicalKeyboardKey.metaRight)) m |= Mod.rmeta;
    return m;
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (_raw) return KeyEventResult.handled; // evdev delivers the keys
    final code = evdevFromPhysical(e.physicalKey);
    final mods = _flutterMods();
    setState(() => _liveMods = mods);
    if (e is KeyDownEvent && code != 0) {
      final bit = Mod.bitForCode(code);
      if (bit != 0) {
        if (widget.singleKey) _accept(code, 0);
      } else if (!_dialogKey(code, mods & ~bit)) {
        _accept(code, mods);
      }
    }
    return KeyEventResult.handled;
  }

  void _onPointer(PointerDownEvent e) {
    if (_raw) return;
    final code = switch (e.buttons) {
      kMiddleMouseButton => Btn.middle,
      kBackMouseButton => Btn.side,
      kForwardMouseButton => Btn.extra,
      _ => 0,
    };
    if (code != 0) _accept(code, _flutterMods());
  }

  void _save() => Navigator.pop(context, HotkeyResult(_key, removed: _key == null));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final owner = widget.checkConflicts && _key != null && _key != widget.current ? app.hotkeyOwner(_key!) : null;
    final live = _liveMods != 0 ? Hotkey(_liveMods, 0).label(sided: _sided).replaceAll(RegExp(r'\+?Key 0$'), '') : '';
    final backend = app.hotkeys.active;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerDown: _onPointer,
        child: AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 88,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: cs.primary, width: 2),
                  ),
                  child: Text(
                    _key != null
                        ? _key!.label(sided: _sided)
                        : (live.isNotEmpty
                              ? '$live+…'
                              : (widget.singleKey ? 'Press a key' : 'Press a key combination')),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: _key != null ? cs.onSurface : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.singleKey
                      ? 'Press the key fboard should press for you. Mouse buttons work too.'
                      : 'Enter saves · Esc cancels · Del/Backspace removes the hotkey.\n'
                            '${app.hotkeys.supportsMouse ? 'Mouse buttons (middle, 4, 5) and modifier+click work too.' : ''}',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                if (owner != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: cs.tertiary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Already used by: $owner. Saving moves the hotkey here.',
                          style: TextStyle(color: cs.tertiary),
                        ),
                      ),
                    ],
                  ),
                ],
                if (backend == HotkeyBackend.portal && !widget.singleKey) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Your desktop manages global shortcuts and may ask you to confirm or change this one.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, HotkeyResult(null, removed: true)),
              child: const Text('Remove'),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: _key == null ? null : _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
