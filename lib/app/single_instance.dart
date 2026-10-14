// SPDX-License-Identifier: GPL-3.0-or-later
// Only one fboard may run (two would fight over the virtual microphone).
// A second start asks the running instance to show its window.
import 'dart:io';

class SingleInstance {
  static RandomAccessFile? _lock;
  static ServerSocket? _server;

  static String get _dir => Platform.environment['XDG_RUNTIME_DIR'] ?? Directory.systemTemp.path;
  static String get _lockPath => '$_dir/fboard.lock';
  static String get _socketPath => '$_dir/fboard.sock';

  /// Returns false if another instance is running (after activating it).
  static Future<bool> acquire({required void Function() onActivate}) async {
    final f = await File(_lockPath).open(mode: FileMode.append);
    try {
      await f.lock(FileLock.exclusive);
    } on FileSystemException {
      await f.close();
      try {
        final s = await Socket.connect(InternetAddress(_socketPath, type: InternetAddressType.unix), 0);
        s.write('show\n');
        await s.flush();
        await s.close();
      } catch (_) {}
      return false;
    }
    _lock = f;
    try {
      final old = File(_socketPath);
      if (old.existsSync()) old.deleteSync();
      _server = await ServerSocket.bind(InternetAddress(_socketPath, type: InternetAddressType.unix), 0);
      _server!.listen((c) {
        c.listen((_) => onActivate(), onDone: c.destroy, onError: (_) => c.destroy());
      });
    } catch (_) {}
    return true;
  }

  static Future<void> release() async {
    await _server?.close();
    try {
      File(_socketPath).deleteSync();
    } catch (_) {}
    await _lock?.unlock();
    await _lock?.close();
  }
}
