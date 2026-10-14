// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../models/settings.dart' show minLoudnessTarget, maxLoudnessTarget;
import '../models/sound_list.dart';
import '../services/dsp.dart';
import 'common.dart';

// ------------------------------------------------------------ rename
Future<void> showRenameDialog(BuildContext context, Sound s) async {
  final name = await promptText(
    context,
    title: 'Rename file',
    initial: s.baseName,
    label: 'File name',
    confirm: 'Rename',
  );
  if (name != null) await app.renameFile(s, name);
}

// ------------------------------------------------------------ trash
Future<void> confirmTrash(BuildContext context) async {
  final n = app.selectedSounds.length;
  if (n == 0) return;
  if (await confirm(
    context,
    title: 'Move to trash',
    message:
        'Move ${n == 1 ? 'this file' : '$n files'} to the trash and remove ${n == 1 ? 'it' : 'them'} from the list?',
    confirm: 'Move to trash',
    destructive: true,
  )) {
    await app.removeSelected(trash: true);
  }
}

// ------------------------------------------------------------ categories
Future<void> showAddToCategoryDialog(BuildContext context) async {
  final ids = app.selectedSounds.map((s) => s.id).toList();
  if (ids.isEmpty) return;
  final cats = app.list.allCategories.toList();
  var move = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Add ${ids.length == 1 ? 'sound' : '${ids.length} sounds'} to category'),
        content: SizedBox(
          width: 380,
          height: 360,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (final c in cats)
                      ListTile(
                        contentPadding: EdgeInsets.only(left: 12.0 + c.depth * 20),
                        leading: const Icon(Icons.folder_rounded),
                        title: Text(c.name),
                        onTap: () {
                          app.addToCategory(c, ids, move: move);
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
              ),
              if (app.selectedCategory != null)
                CheckboxListTile(
                  value: move,
                  onChanged: (v) => setState(() => move = v ?? false),
                  title: Text('Remove from "${app.selectedCategory!.name}"'),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    ),
  );
}

// ------------------------------------------------------------ voice measure
Future<void> showVoiceMeasureDialog(BuildContext context) async {
  await showDialog<void>(context: context, builder: (_) => const _VoiceMeasureDialog());
}

class _VoiceMeasureDialog extends StatefulWidget {
  const _VoiceMeasureDialog();
  @override
  State<_VoiceMeasureDialog> createState() => _VoiceMeasureDialogState();
}

class _VoiceMeasureDialogState extends State<_VoiceMeasureDialog> {
  bool _running = false;
  double _left = 0;
  double? _result;
  bool _done = false;
  Timer? _timer;

  void _start() {
    app.native.measureVoiceStart();
    setState(() {
      _running = true;
      _left = 8;
      _result = null;
    });
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      setState(() => _left -= 0.1);
      if (_left <= 0) _finish();
    });
  }

  void _finish() {
    _timer?.cancel();
    final v = app.native.measureVoiceStop();
    setState(() {
      _running = false;
      _done = true;
      // A near-silent result means the mic barely picked anything up; using
      // it as a target would make every sound inaudible.
      _result = v.isFinite && v >= minLoudnessTarget ? v : null;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_running) app.native.measureVoiceStop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Measure voice volume'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Speak normally into your microphone for a few seconds, the way you talk in voice chat. '
              'fboard then sets the volume normalization target so sounds are as loud as your voice.',
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder(
              valueListenable: app.status,
              builder: (_, st, _) => LevelMeter(level: peakToMeter(st.micPeak), width: 380, height: 10),
            ),
            const SizedBox(height: 16),
            if (_running) Text('Listening… ${_left.ceil()} s', style: TextStyle(color: cs.primary)),
            if (_result != null)
              Text(
                'Your voice: ${_result!.toStringAsFixed(1)} LUFS (${lufsToSoundpadDb(_result!).toStringAsFixed(0)} dB)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            if (_done && _result == null)
              Text(
                'No voice was detected. Check the input device in Preferences › Devices.',
                style: TextStyle(color: cs.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (!_running) FilledButton.tonal(onPressed: _start, child: Text(_result == null ? 'Start' : 'Measure again')),
        if (_running) FilledButton.tonal(onPressed: _finish, child: const Text('Stop')),
        if (_result != null)
          FilledButton(
            onPressed: () {
              app.settings.normalize = true;
              app.settings.normalizeTarget = _result!.clamp(minLoudnessTarget, maxLoudnessTarget).roundToDouble();
              app.settingsChanged(audio: true);
              app.notify('Volume normalization set to ${app.settings.normalizeTarget.toStringAsFixed(1)} LUFS');
              Navigator.pop(context);
            },
            child: const Text('Use as target'),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------ backups
Future<void> showBackupsDialog(BuildContext context) async {
  final files = app.backups();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Restore sound list'),
      content: SizedBox(
        width: 420,
        height: 380,
        child: files.isEmpty
            ? const Center(child: Text('No backups yet. A backup is made once a day when fboard starts.'))
            : ListView(
                children: [
                  for (final f in files)
                    ListTile(
                      leading: const Icon(Icons.history_rounded),
                      title: Text(p.basenameWithoutExtension(f.path)),
                      subtitle: Text(formatSize(f.lengthSync())),
                      onTap: () async {
                        if (await confirm(
                          ctx,
                          title: 'Restore backup',
                          message:
                              'Replace the current sound list with the backup from '
                              '${p.basenameWithoutExtension(f.path)}? You can undo this with Ctrl+Z.',
                          confirm: 'Restore',
                        )) {
                          app.restoreBackup(f);
                          if (ctx.mounted) Navigator.pop(ctx);
                        }
                      },
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

// ------------------------------------------------------------ hotkey overview
Future<void> showHotkeyOverview(BuildContext context) async {
  final rows = app.hotkeys.overview()..sort((a, b) => a.$1.compareTo(b.$1));
  final cs = Theme.of(context).colorScheme;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Hotkey overview'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: rows.isEmpty
            ? const Center(child: Text('No hotkeys are set.'))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(),
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 170,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                        child: Text(rows[i].$1, style: TextStyle(color: cs.onSecondaryContainer)),
                      ),
                      const SizedBox(width: 16),
                      Expanded(child: Text(rows[i].$2)),
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        Text('Backend: ${app.hotkeys.active?.label ?? 'none'}', style: TextStyle(color: cs.onSurfaceVariant)),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

// ------------------------------------------------------------ notices
Future<void> showNoticesDialog(BuildContext context) async {
  final cs = Theme.of(context).colorScheme;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Notifications'),
      content: SizedBox(
        width: 560,
        height: 400,
        child: app.notices.isEmpty
            ? const Center(child: Text('No notifications.'))
            : ListView(
                children: [
                  for (final n in app.notices)
                    ListTile(
                      leading: Icon(
                        n.level == NoticeLevel.error ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
                        color: n.level == NoticeLevel.error ? cs.error : cs.tertiary,
                      ),
                      title: Text(n.text),
                      subtitle: Text(
                        '${n.time.hour.toString().padLeft(2, '0')}:${n.time.minute.toString().padLeft(2, '0')}',
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            app.notices.clear();
            app.refresh();
            Navigator.pop(ctx);
          },
          child: const Text('Clear'),
        ),
        FilledButton(
          onPressed: () {
            app.confirmNotices();
            Navigator.pop(ctx);
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------ auto keys
Future<void> showAutoKeysTroubleshooting(BuildContext context) async {
  final viaHotkey = await app.autoKeys.troubleshoot(byHotkey: true);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Auto Keys troubleshooting'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('For a sound played by hotkey right now:'),
            const SizedBox(height: 8),
            for (final l in viaHotkey) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(l)),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

// ------------------------------------------------------------ about
void showAboutFboard(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'fboard',
    applicationVersion: '1.0.0',
    applicationIcon: Image.asset('assets/icon.png', width: 64, height: 64),
    applicationLegalese: 'Free and open-source software, licensed under the GNU GPL v3 or later.',
    children: [
      const SizedBox(height: 12),
      const Text(
        'A soundboard for Linux: play sounds into your microphone, with global hotkeys, '
        'categories, a hotbar, a recorder and a sound editor.',
      ),
      const SizedBox(height: 12),
      Text(
        'Sound server: ${app.audioConnected ? 'connected' : 'not connected'} · '
        'Hotkeys: ${app.hotkeys.active?.label ?? 'none'} · '
        'Session: ${Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown'}',
      ),
    ],
  );
}
