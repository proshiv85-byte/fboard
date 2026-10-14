// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../models/settings.dart';
import 'dialogs.dart';
import 'preferences_dialog.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = app.settings;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _PlayModeChip(),
          const SizedBox(width: 4),
          _Toggle(
            icon: s.hotkeysEnabled ? Icons.keyboard_rounded : Icons.keyboard_hide_rounded,
            label: 'Hotkeys',
            on: s.hotkeysEnabled,
            tooltip:
                'Hotkeys ${s.hotkeysEnabled ? 'enabled' : 'disabled'} (${app.hotkeys.active?.label ?? 'no backend'}).\n'
                'Double-click to toggle, right-click for options.',
            onDoubleTap: () => app.toggleHotkeysEnabled(),
            onSecondary: (pos) => _hotkeyMenu(context, pos),
            warn: app.hotkeys.error != null,
          ),
          _Toggle(
            icon: Icons.smart_button_rounded,
            label: s.autoKeys.isEmpty ? 'Auto Keys' : 'Auto Keys (${s.autoKeys.where((k) => k.enabled).length})',
            on: s.autoKeysEnabled && s.autoKeys.any((k) => k.enabled),
            tooltip:
                'Auto Keys ${s.autoKeysEnabled ? 'enabled' : 'disabled'}.\nDouble-click to toggle, click for options.',
            onDoubleTap: () => app.toggleAutoKeys(),
            onTap: (pos) => _autoKeysMenu(context, pos),
            onSecondary: (pos) => _autoKeysMenu(context, pos),
          ),
          _Toggle(
            icon: Icons.repeat_one_rounded,
            on: s.repeatCurrent,
            tooltip: 'Repeat playback of current file',
            onTap: (_) => app.toggleRepeat(),
          ),
          _Toggle(
            icon: Icons.playlist_play_rounded,
            on: s.continuePlayback,
            tooltip: 'Continue playback after current file',
            onTap: (_) => app.toggleContinue(),
          ),
          _Toggle(
            icon: Icons.hearing_rounded,
            on: s.hearMyself,
            tooltip: 'Hear myself (play your microphone on your speakers)',
            onTap: (_) => app.toggleHearMyself(),
          ),
          _Toggle(
            icon: Icons.voice_over_off_rounded,
            on: s.blockVoice,
            tooltip: 'Block voice while a sound plays on the microphone',
            onTap: (_) => app.toggleBlockVoice(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: app.statusMessage,
              builder: (_, msg, _) => Text(
                msg,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
              ),
            ),
          ),
          if (!app.audioConnected || app.audioError != null)
            Tooltip(
              message: app.audioError ?? 'Not connected to the sound server',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.mic_off_rounded, color: cs.error, size: 20),
              ),
            )
          else
            Tooltip(
              message:
                  'Voice apps should use "fboard Microphone" as their input device'
                  '${s.setDefaultMic ? ' (it is the system default while fboard runs)' : ''}.',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.mic_rounded, color: cs.primary, size: 20),
              ),
            ),
          GestureDetector(
            onSecondaryTap: () => showNoticesDialog(context),
            child: IconButton(
              tooltip: 'Notifications (right-click to show confirmed ones again)',
              onPressed: () => showNoticesDialog(context),
              icon: Badge(
                isLabelVisible: app.unconfirmedNotices > 0,
                label: Text('${app.unconfirmedNotices}'),
                child: const Icon(Icons.notifications_none_rounded, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _hotkeyMenu(BuildContext context, Offset pos) {
    final s = app.settings;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy - 200, pos.dx, 0),
      items: [
        CheckedPopupMenuItem(
          checked: s.hotkeysEnabled,
          onTap: () => app.toggleHotkeysEnabled(),
          child: const Text('Hotkeys enabled'),
        ),
        CheckedPopupMenuItem(
          checked: s.passHotkeys,
          enabled: app.hotkeys.active == HotkeyBackend.evdev,
          onTap: () {
            s.passHotkeys = !s.passHotkeys;
            app.settingsChanged(hotkeyTable: true);
          },
          child: const Text('Pass hotkeys to other applications'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(onTap: () => showHotkeyOverview(context), child: const Text('Hotkey overview')),
        PopupMenuItem(
          onTap: () => showPreferences(context, page: PrefsPage.hotkeys),
          child: const Text('Hotkey preferences…'),
        ),
      ],
    );
  }

  void _autoKeysMenu(BuildContext context, Offset pos) {
    final s = app.settings;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy - 200, pos.dx, 0),
      items: [
        CheckedPopupMenuItem(
          checked: s.autoKeysEnabled,
          onTap: () => app.toggleAutoKeys(),
          child: const Text('Auto Keys enabled'),
        ),
        if (s.autoKeys.isNotEmpty) const PopupMenuDivider(),
        for (final k in s.autoKeys)
          CheckedPopupMenuItem(
            checked: k.enabled,
            onTap: () {
              k.enabled = !k.enabled;
              app.settingsChanged();
            },
            child: Text(k.name.isEmpty ? 'Auto key' : k.name),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(onTap: () => showAutoKeysTroubleshooting(context), child: const Text('Troubleshooting')),
        PopupMenuItem(
          onTap: () => showPreferences(context, page: PrefsPage.autoKeys),
          child: const Text('Configure Auto Keys…'),
        ),
      ],
    );
  }
}

class _PlayModeChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final m = app.playMode;
    final icon = switch (m) {
      PlayMode.both => Icons.surround_sound_rounded,
      PlayMode.speakers => Icons.volume_up_rounded,
      PlayMode.mic => Icons.mic_rounded,
    };
    return MenuAnchor(
      builder: (context, ctl, _) => Tooltip(
        message: 'Play mode: ${m.label}',
        child: ActionChip(
          avatar: Icon(icon, size: 18),
          label: Text(m.label),
          onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
        ),
      ),
      menuChildren: [
        for (final mode in PlayMode.values)
          MenuItemButton(
            leadingIcon: Icon(mode == m ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
            onPressed: () => app.setPlayMode(mode),
            child: Text(mode.label),
          ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final String? label;
  final bool on;
  final String tooltip;
  final bool warn;
  final void Function(Offset)? onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Offset)? onSecondary;

  const _Toggle({
    required this.icon,
    this.label,
    required this.on,
    required this.tooltip,
    this.warn = false,
    this.onTap,
    this.onDoubleTap,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = warn ? cs.error : (on ? cs.onSecondaryContainer : cs.onSurfaceVariant.withValues(alpha: 0.6));
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTapUp: onTap == null ? null : (d) => onTap!(d.globalPosition),
        onDoubleTap: onDoubleTap,
        onSecondaryTapUp: onSecondary == null ? null : (d) => onSecondary!(d.globalPosition),
        child: Container(
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: EdgeInsets.symmetric(horizontal: label == null ? 6 : 10),
          decoration: BoxDecoration(
            color: on ? cs.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              if (label != null) ...[
                const SizedBox(width: 6),
                Text(label!, style: TextStyle(fontSize: 12.5, color: color)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
