// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;

/// Moves a file to the trash (freedesktop.org trash specification).
Future<bool> moveToTrash(String path) async {
  // Prefer gio, which also handles trash directories on other filesystems.
  try {
    final r = await Process.run('gio', ['trash', path]);
    if (r.exitCode == 0) return true;
  } catch (_) {}
  try {
    final dataHome = Platform.environment['XDG_DATA_HOME'] ?? '${Platform.environment['HOME']}/.local/share';
    final trash = Directory(p.join(dataHome, 'Trash'));
    final files = Directory(p.join(trash.path, 'files'))..createSync(recursive: true);
    final info = Directory(p.join(trash.path, 'info'))..createSync(recursive: true);
    var name = p.basename(path);
    var i = 1;
    while (File(p.join(files.path, name)).existsSync() || File(p.join(info.path, '$name.trashinfo')).existsSync()) {
      name = '${p.basenameWithoutExtension(path)}.$i${p.extension(path)}';
      i++;
    }
    final now = DateTime.now().toIso8601String().split('.').first;
    File(p.join(info.path, '$name.trashinfo'))
        .writeAsStringSync('[Trash Info]\nPath=${Uri.file(path).path}\nDeletionDate=$now\n');
    await File(path).rename(p.join(files.path, name));
    return true;
  } catch (_) {
    return false;
  }
}

/// Opens the file manager with the file selected.
Future<void> showInFileManager(String path) async {
  final bus = DBusClient.session();
  try {
    await DBusRemoteObject(
      bus,
      name: 'org.freedesktop.FileManager1',
      path: DBusObjectPath('/org/freedesktop/FileManager1'),
    ).callMethod('org.freedesktop.FileManager1', 'ShowItems', [
      DBusArray.string([Uri.file(path).toString()]),
      const DBusString(''),
    ], replySignature: DBusSignature(''));
  } catch (_) {
    await Process.start('xdg-open', [p.dirname(path)], mode: ProcessStartMode.detached);
  } finally {
    await bus.close();
  }
}
