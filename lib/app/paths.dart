// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

/// XDG base directories for fboard.
class Paths {
  static String _xdg(String env, String fallback) {
    final v = Platform.environment[env];
    if (v != null && v.isNotEmpty) return v;
    return '${Platform.environment['HOME']}/$fallback';
  }

  static String get config => _ensure('${_xdg('XDG_CONFIG_HOME', '.config')}/fboard');
  static String get data => _ensure('${_xdg('XDG_DATA_HOME', '.local/share')}/fboard');
  static String get cache => _ensure('${_xdg('XDG_CACHE_HOME', '.cache')}/fboard');
  static String get backups => _ensure('$data/backups');
  static String get recordings => _ensure('$data/recordings');
  static String get settingsFile => '$config/settings.json';
  static String get workingCopy => '$data/working.fbl';
  static String get home => Platform.environment['HOME'] ?? '/';

  static String _ensure(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) d.createSync(recursive: true);
    return dir;
  }
}
