// SPDX-License-Identifier: GPL-3.0-or-later
// Hotkeys are stored as (modifier mask, Linux evdev key code). Mouse buttons
// use the evdev BTN_* codes.
import 'package:flutter/services.dart';

class Mod {
  static const lctrl = 0x01, rctrl = 0x02, lshift = 0x04, rshift = 0x08;
  static const lalt = 0x10, ralt = 0x20, lmeta = 0x40, rmeta = 0x80;
  static const ctrl = lctrl, shift = lshift, alt = lalt, meta = lmeta;

  /// Folds right-hand modifiers onto the left bits.
  static int unsided(int m) => (m | (m >> 1)) & (lctrl | lshift | lalt | lmeta);

  static int bitForCode(int code) => switch (code) {
    29 => lctrl,
    97 => rctrl,
    42 => lshift,
    54 => rshift,
    56 => lalt,
    100 => ralt,
    125 => lmeta,
    126 => rmeta,
    _ => 0,
  };
}

class Btn {
  static const left = 0x110, right = 0x111, middle = 0x112, side = 0x113, extra = 0x114;
  static bool isMouse(int code) => code >= 0x110 && code <= 0x117;
}

class Hotkey {
  final int mods;
  final int code;
  const Hotkey(this.mods, this.code);

  bool get isMouse => Btn.isMouse(code);
  bool get isModifierOnly => Mod.bitForCode(code) != 0;

  /// Plain left/right click hotkeys are not allowed (same as Soundpad).
  bool get isAllowed => !((code == Btn.left || code == Btn.right) && mods == 0) && !isModifierOnly;

  bool matches(int mask, int keyCode, {required bool sided}) {
    if (keyCode != code) return false;
    return sided ? mask == mods : Mod.unsided(mask) == Mod.unsided(mods);
  }

  Hotkey normalized(bool sided) => sided ? this : Hotkey(Mod.unsided(mods), code);

  @override
  bool operator ==(Object other) => other is Hotkey && other.mods == mods && other.code == code;
  @override
  int get hashCode => Object.hash(mods, code);

  Map<String, dynamic> toJson() => {'m': mods, 'c': code};
  static Hotkey? fromJson(dynamic j) => j is Map ? Hotkey(j['m'] as int, j['c'] as int) : null;

  String label({bool sided = false}) {
    final parts = <String>[];
    void mod(int l, int r, String name) {
      if (sided) {
        if (mods & l != 0) parts.add(name);
        if (mods & r != 0) parts.add('R$name');
      } else if (mods & (l | r) != 0) {
        parts.add(name);
      }
    }

    mod(Mod.lctrl, Mod.rctrl, 'Ctrl');
    mod(Mod.lshift, Mod.rshift, 'Shift');
    mod(Mod.lalt, Mod.ralt, 'Alt');
    mod(Mod.lmeta, Mod.rmeta, 'Super');
    parts.add(keyName(code));
    return parts.join('+');
  }

  @override
  String toString() => label();

  /// XDG shortcut trigger string (for the GlobalShortcuts portal).
  String? get portalTrigger {
    final k = _portalKey(code);
    if (k == null) return null;
    final p = <String>[];
    final u = Mod.unsided(mods);
    if (u & Mod.ctrl != 0) p.add('CTRL');
    if (u & Mod.shift != 0) p.add('SHIFT');
    if (u & Mod.alt != 0) p.add('ALT');
    if (u & Mod.meta != 0) p.add('LOGO');
    p.add(k);
    return p.join('+');
  }
}

const Map<int, String> _names = {
  1: 'Esc', 2: '1', 3: '2', 4: '3', 5: '4', 6: '5', 7: '6', 8: '7', 9: '8', 10: '9', 11: '0', //
  12: '-', 13: '=', 14: 'Backspace', 15: 'Tab', 16: 'Q', 17: 'W', 18: 'E', 19: 'R', 20: 'T', 21: 'Y',
  22: 'U', 23: 'I', 24: 'O', 25: 'P', 26: '[', 27: ']', 28: 'Enter', 29: 'Ctrl', 30: 'A', 31: 'S', 32: 'D',
  33: 'F', 34: 'G', 35: 'H', 36: 'J', 37: 'K', 38: 'L', 39: ';', 40: "'", 41: '`', 42: 'Shift', 43: '\\',
  44: 'Z', 45: 'X', 46: 'C', 47: 'V', 48: 'B', 49: 'N', 50: 'M', 51: ',', 52: '.', 53: '/', 54: 'RShift',
  55: 'Num *', 56: 'Alt', 57: 'Space', 58: 'Caps Lock', 59: 'F1', 60: 'F2', 61: 'F3', 62: 'F4', 63: 'F5',
  64: 'F6', 65: 'F7', 66: 'F8', 67: 'F9', 68: 'F10', 69: 'Num Lock', 70: 'Scroll Lock', 71: 'Num 7',
  72: 'Num 8', 73: 'Num 9', 74: 'Num -', 75: 'Num 4', 76: 'Num 5', 77: 'Num 6', 78: 'Num +', 79: 'Num 1',
  80: 'Num 2', 81: 'Num 3', 82: 'Num 0', 83: 'Num .', 86: '<>', 87: 'F11', 88: 'F12', 96: 'Num Enter',
  97: 'RCtrl', 98: 'Num /', 99: 'Print', 100: 'AltGr', 102: 'Home', 103: 'Up', 104: 'Page Up', 105: 'Left',
  106: 'Right', 107: 'End', 108: 'Down', 109: 'Page Down', 110: 'Insert', 111: 'Delete', 113: 'Mute',
  114: 'Volume Down', 115: 'Volume Up', 119: 'Pause', 125: 'Super', 126: 'RSuper', 127: 'Menu',
  163: 'Next Track', 164: 'Play/Pause', 165: 'Previous Track', 166: 'Stop Media', 183: 'F13', 184: 'F14',
  185: 'F15', 186: 'F16', 187: 'F17', 188: 'F18', 189: 'F19', 190: 'F20', 191: 'F21', 192: 'F22',
  193: 'F23', 194: 'F24', 0x110: 'Mouse Left', 0x111: 'Mouse Right', 0x112: 'Mouse Middle',
  0x113: 'Mouse 4', 0x114: 'Mouse 5', 0x115: 'Mouse 6', 0x116: 'Mouse 7', 0x117: 'Mouse 8',
};

String keyName(int code) => _names[code] ?? 'Key $code';

/// Numpad digit (0-9) for an evdev code, or null.
int? numpadDigit(int code) => const {
  82: 0, 79: 1, 80: 2, 81: 3, 75: 4, 76: 5, 77: 6, 71: 7, 72: 8, 73: 9, //
}[code];

/// Digit (0-9) from the top row or numpad, or null.
int? anyDigit(int code) {
  final n = numpadDigit(code);
  if (n != null) return n;
  if (code >= 2 && code <= 10) return code - 1;
  if (code == 11) return 0;
  return null;
}

String? _portalKey(int code) {
  if (code >= 0x110) return null;
  const special = {
    1: 'Escape',
    12: 'minus',
    13: 'equal',
    14: 'BackSpace',
    15: 'Tab',
    26: 'bracketleft',
    27: 'bracketright',
    28: 'Return',
    39: 'semicolon',
    40: 'apostrophe',
    41: 'grave',
    43: 'backslash',
    51: 'comma',
    52: 'period',
    53: 'slash',
    55: 'KP_Multiply',
    57: 'space',
    69: 'Num_Lock',
    70: 'Scroll_Lock',
    71: 'KP_7',
    72: 'KP_8',
    73: 'KP_9',
    74: 'KP_Subtract',
    75: 'KP_4',
    76: 'KP_5',
    77: 'KP_6',
    78: 'KP_Add',
    79: 'KP_1',
    80: 'KP_2',
    81: 'KP_3',
    82: 'KP_0',
    83: 'KP_Decimal',
    96: 'KP_Enter',
    98: 'KP_Divide',
    99: 'Print',
    102: 'Home',
    103: 'Up',
    104: 'Page_Up',
    105: 'Left',
    106: 'Right',
    107: 'End',
    108: 'Down',
    109: 'Page_Down',
    110: 'Insert',
    111: 'Delete',
    113: 'XF86AudioMute',
    114: 'XF86AudioLowerVolume',
    115: 'XF86AudioRaiseVolume',
    119: 'Pause',
    127: 'Menu',
    163: 'XF86AudioNext',
    164: 'XF86AudioPlay',
    165: 'XF86AudioPrev',
    166: 'XF86AudioStop',
  };
  if (special.containsKey(code)) return special[code];
  final n = _names[code];
  if (n == null) return null;
  if (n.length == 1) return n.toLowerCase();
  if (RegExp(r'^F\d+$').hasMatch(n)) return n;
  return null;
}

// USB HID usage (keyboard page) -> evdev code, from the Linux kernel's
// hid-input.c table. Used to capture hotkeys from Flutter key events.
const List<int> _hidToEvdev = [
  0, 0, 0, 0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, //
  50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44, 2, 3,
  4, 5, 6, 7, 8, 9, 10, 11, 28, 1, 14, 15, 57, 12, 13, 26,
  27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64,
  65, 66, 67, 68, 87, 88, 99, 70, 119, 110, 102, 104, 111, 107, 109, 106,
  105, 108, 103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71,
  72, 73, 82, 83, 86, 127, 116, 117, 183, 184, 185, 186, 187, 188, 189, 190,
  191, 192, 193, 194, 134, 138, 130, 132, 128, 129, 131, 137, 133, 135, 136, 113,
  115, 114, 0, 0, 0, 121, 0, 89, 93, 124, 92, 94, 95, 0, 0, 0,
  122, 123, 90, 91, 85, 0, 0, 0, 0, 0, 0, 0, 111, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 179, 180, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 111, 0, 0, 0, 0, 0, 0, 0,
  29, 42, 56, 125, 97, 54, 100, 126, 164, 166, 165, 163, 161, 115, 114, 113,
  150, 158, 159, 128, 136, 177, 178, 176, 142, 152, 173, 140, 0, 0, 0, 0,
];

/// evdev code for a Flutter physical key, or 0.
int evdevFromPhysical(PhysicalKeyboardKey key) {
  final u = key.usbHidUsage;
  if ((u >> 16) == 0x07) {
    final id = u & 0xffff;
    if (id < _hidToEvdev.length) return _hidToEvdev[id];
  }
  // Consumer page media keys
  if ((u >> 16) == 0x0c) {
    return const {0xe2: 113, 0xea: 114, 0xe9: 115, 0xb5: 163, 0xcd: 164, 0xb6: 165, 0xb7: 166}[u & 0xffff] ?? 0;
  }
  return 0;
}
