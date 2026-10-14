// SPDX-License-Identifier: GPL-3.0-or-later
// System tray icon (StatusNotifierItem).
import 'package:tray_manager/tray_manager.dart' as tray;

import '../app/controller.dart';
import '../models/settings.dart';

class Tray {
  final Future<void> Function() onShow;
  final Future<void> Function() onQuit;
  Tray({required this.onShow, required this.onQuit});

  tray.TrayIcon? _icon;
  tray.Menu? _menu;
  String _state = '';

  bool get visible => _icon != null;

  void sync() {
    final s = app.settings;
    if (!s.showTray) {
      _destroy();
      return;
    }
    if (_icon == null) {
      try {
        _icon = tray.TrayIcon.create();
        if (_icon == null) return;
        _icon!.icon = tray.ImageAsset.fromAsset('assets/tray.png');
        _icon!.setTooltip('fboard');
        _icon!.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
        _icon!.addListener((e) {
          if (e is tray.TrayIconClickedEvent) onShow();
        });
        _menu = tray.Menu.create();
        _icon!.setContextMenu(_menu);
        _icon!.setVisible(true);
      } catch (_) {
        _icon = null;
        return;
      }
    }
    final state = '${s.playMode}${s.hotkeysEnabled}${s.autoKeysEnabled}';
    if (state == _state) return;
    _state = state;
    final m = _menu!;
    m.clear();
    void item(String label, void Function() fn, {bool? checked}) {
      final it = tray.MenuItem.createWithLabelAndType(
        label,
        checked == null ? tray.MenuItemType.normal : tray.MenuItemType.checkbox,
      );
      if (it == null) return;
      if (checked != null) it.state = checked ? tray.MenuItemState.checked : tray.MenuItemState.unchecked;
      it.addListener((e) {
        if (e is tray.MenuItemClickedEvent) fn();
      });
      m.addItem(it);
    }

    item('Show fboard', onShow);
    m.addSeparator();
    item('Stop playback', app.stop);
    item('Play random file', () => app.playRandom());
    m.addSeparator();
    for (final mode in PlayMode.values) {
      item(mode.label, () => app.setPlayMode(mode), checked: s.playMode == mode);
    }
    m.addSeparator();
    item('Hotkeys enabled', () => app.toggleHotkeysEnabled(), checked: s.hotkeysEnabled);
    item('Auto Keys enabled', () => app.toggleAutoKeys(), checked: s.autoKeysEnabled);
    m.addSeparator();
    item('Quit', onQuit);
  }

  void _destroy() {
    _icon?.setVisible(false);
    _icon?.dispose();
    _menu?.dispose();
    _icon = null;
    _menu = null;
    _state = '';
  }

  void dispose() => _destroy();
}
