// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../app/paths.dart';
import '../models/hotkey.dart';
import '../models/settings.dart';
import '../services/auto_keys.dart';
import '../services/dsp.dart';
import 'common.dart';
import 'dialogs.dart';
import 'hotkey_dialog.dart';
import 'theme.dart';

enum PrefsPage {
  interface('Interface', Icons.palette_outlined),
  audio('Audio', Icons.graphic_eq_rounded),
  devices('Devices', Icons.settings_input_component_outlined),
  hotkeys('Hotkeys', Icons.keyboard_outlined),
  special('Special hotkeys', Icons.keyboard_command_key_rounded),
  autoKeys('Auto Keys', Icons.smart_button_outlined),
  recorder('Recorder', Icons.fiber_manual_record_outlined),
  notifications('Notifications', Icons.notifications_none_rounded);

  final String label;
  final IconData icon;
  const PrefsPage(this.label, this.icon);
}

Future<void> showPreferences(BuildContext context, {PrefsPage page = PrefsPage.interface}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _Prefs(page)));

class _Prefs extends StatefulWidget {
  final PrefsPage initial;
  const _Prefs(this.initial);
  @override
  State<_Prefs> createState() => _PrefsState();
}

class _PrefsState extends State<_Prefs> {
  late PrefsPage _page = widget.initial;

  @override
  void initState() {
    super.initState();
    app.addListener(_changed);
  }

  @override
  void dispose() {
    app.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context)},
      child: Focus(autofocus: true, child: _scaffold(context)),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Preferences')),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _page.index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _page = PrefsPage.values[i]),
            destinations: [
              for (final p in PrefsPage.values) NavigationRailDestination(icon: Icon(p.icon), label: Text(p.label)),
            ],
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(padding: const EdgeInsets.only(bottom: 32), children: _content(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context) => switch (_page) {
    PrefsPage.interface => _interface(context),
    PrefsPage.audio => _audio(context),
    PrefsPage.devices => _devices(context),
    PrefsPage.hotkeys => _hotkeys(context),
    PrefsPage.special => _special(context),
    PrefsPage.autoKeys => _autoKeys(context),
    PrefsPage.recorder => _recorder(context),
    PrefsPage.notifications => _notifications(context),
  };

  Settings get s => app.settings;

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged, {String? subtitle, bool enabled = true}) =>
      SwitchListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: enabled ? onChanged : null,
      );

  Widget _hint(String text, {bool error = false}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(text, style: TextStyle(color: error ? cs.error : cs.onSurfaceVariant, fontSize: 13)),
    );
  }

  // ================================================================ interface
  List<Widget> _interface(BuildContext context) => [
    const SectionHeader('Appearance'),
    ListTile(
      title: const Text('Theme'),
      trailing: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'system', label: Text('System'), icon: Icon(Icons.brightness_auto_outlined)),
          ButtonSegment(value: 'light', label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
          ButtonSegment(value: 'dark', label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
        ],
        selected: {s.themeMode},
        onSelectionChanged: (v) {
          s.themeMode = v.first;
          app.settingsChanged();
        },
      ),
    ),
    _switch('Use the system accent color', s.dynamicColor, (v) {
      s.dynamicColor = v;
      app.settingsChanged();
    }, subtitle: 'Falls back to the color below when the desktop has no accent color'),
    ListTile(
      title: const Text('Accent color'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in [
              0xFF6750A4,
              0xFF006A6A,
              0xFF386A20,
              0xFF8B5000,
              0xFFB3261E,
              0xFF0061A4,
              0xFF7D5260,
              ...hotbarColors,
            ])
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  s.seedColor = c;
                  app.settingsChanged();
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: s.seedColor == c
                        ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3)
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    const SectionHeader('Behaviour'),
    _switch('Typing begins search', s.typingBeginsSearch, (v) {
      s.typingBeginsSearch = v;
      app.settingsChanged();
    }),
    _switch('Allow resume in another play mode', s.allowResumeInOtherMode, (v) {
      s.allowResumeInOtherMode = v;
      app.settingsChanged();
    }, subtitle: 'While paused, the play buttons resume in their mode'),
    _switch('Display microphone level on toolbar', s.showMicLevel, (v) {
      s.showMicLevel = v;
      app.settingsChanged();
    }),
    ListTile(
      title: const Text('"Switch to next play mode" cycles through'),
      subtitle: Wrap(
        spacing: 8,
        children: [
          for (final m in PlayMode.values)
            FilterChip(
              label: Text(m.label),
              selected: s.playModeCycle.contains(m),
              onSelected: (v) {
                if (v) {
                  s.playModeCycle = PlayMode.values.where((x) => x == m || s.playModeCycle.contains(x)).toList();
                } else if (s.playModeCycle.length > 2) {
                  s.playModeCycle = s.playModeCycle.where((x) => x != m).toList();
                }
                app.settingsChanged();
              },
            ),
        ],
      ),
    ),
    const SectionHeader('Window and tray'),
    _switch('Show tray icon', s.showTray, (v) {
      s.showTray = v;
      app.settingsChanged();
    }),
    _switch('Closing the window keeps fboard running in the tray', s.closeToTray, (v) {
      s.closeToTray = v;
      app.settingsChanged();
    }, enabled: s.showTray),
    _switch('Start minimized to the tray', s.startMinimized, (v) {
      s.startMinimized = v;
      app.settingsChanged();
    }, enabled: s.showTray),
    const SectionHeader('Categories'),
    ListTile(
      title: const Text('Icon size'),
      trailing: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 0, label: Text('Smaller')),
          ButtonSegment(value: 1, label: Text('Small')),
          ButtonSegment(value: 2, label: Text('Medium')),
          ButtonSegment(value: 3, label: Text('Large')),
        ],
        selected: {s.categoryIconSize},
        onSelectionChanged: (v) {
          s.categoryIconSize = v.first;
          app.settingsChanged();
        },
      ),
    ),
  ];

  // ================================================================ audio
  List<Widget> _audio(BuildContext context) => [
    const SectionHeader('Volume normalization'),
    _switch('Normalize volume', s.normalize, (v) {
      s.normalize = v;
      app.settingsChanged(audio: true);
    }, subtitle: 'Plays all sounds equally loud (EBU R128). This is how loud others hear your sounds.'),
    ListTile(
      enabled: s.normalize,
      title: Text(
        'Target loudness: ${s.normalizeTarget.toStringAsFixed(0)} LUFS '
        '(${lufsToSoundpadDb(s.normalizeTarget).toStringAsFixed(0)} dB)',
      ),
      subtitle: Slider(
        value: s.normalizeTarget.clamp(minLoudnessTarget, maxLoudnessTarget),
        min: minLoudnessTarget,
        max: maxLoudnessTarget,
        onChanged: s.normalize
            ? (v) {
                s.normalizeTarget = v.roundToDouble();
                app.settingsChanged(audio: true);
              }
            : null,
      ),
      trailing: OutlinedButton.icon(
        icon: const Icon(Icons.mic_none_rounded),
        label: const Text('Measure my voice'),
        onPressed: s.normalize ? () => showVoiceMeasureDialog(context) : null,
      ),
    ),
    _switch(
      'Dynamic volume adjustment',
      s.dynamicNormalization,
      (v) {
        s.dynamicNormalization = v;
        app.settingsChanged(audio: true);
      },
      subtitle: 'Analyzes the first 6 seconds on playback and refines the volume while the sound plays',
      enabled: s.normalize,
    ),
    ListTile(
      enabled: !s.normalize,
      title: Text('Microphone volume: ${(s.micVolume * 100).round()}%'),
      subtitle: Slider(
        value: s.micVolume.clamp(0.0, 2.0),
        max: 2,
        onChanged: s.normalize
            ? null
            : (v) {
                s.micVolume = v;
                app.settingsChanged(audio: true);
              },
      ),
    ),
    _hint('Used when normalization is off.'),
    const SectionHeader('Microphone'),
    _switch('Block voice', s.blockVoice, (v) {
      s.blockVoice = v;
      app.settingsChanged(audio: true);
    }, subtitle: 'Mutes your real microphone while a sound plays on the microphone'),
    _switch('Hear myself', s.hearMyself, (v) {
      s.hearMyself = v;
      app.settingsChanged(audio: true);
    }, subtitle: 'Plays your microphone on your speakers or headphones'),
    _switch('Play voice activation sound', s.activationSound, (v) {
      s.activationSound = v;
      app.settingsChanged(audio: true);
    }, subtitle: 'A short, loud sound before each sound so voice activation opens in time'),
    ListTile(
      enabled: s.activationSound,
      title: const Text('Voice activation sound'),
      subtitle: Text(s.activationSoundPath ?? 'Built-in'),
      trailing: Wrap(
        spacing: 8,
        children: [
          if (s.activationSoundPath != null)
            TextButton(
              onPressed: () {
                s.activationSoundPath = null;
                app.settingsChanged(audio: true);
              },
              child: const Text('Use built-in'),
            ),
          OutlinedButton(
            onPressed: () async {
              final f = await pickAudioFile(context);
              if (f != null) {
                s.activationSoundPath = f;
                app.settingsChanged(audio: true);
              }
            },
            child: const Text('Choose…'),
          ),
        ],
      ),
    ),
  ];

  // ================================================================ devices
  List<Widget> _devices(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mics = app.sources.where((d) => !d.monitor).toList();
    final good = app.audioConnected && app.audioError == null;
    return [
      const SectionHeader('Status'),
      ListTile(
        leading: Icon(good ? Icons.check_circle_rounded : Icons.error_rounded, color: good ? Colors.green : cs.error),
        title: Text(good ? 'Good' : (app.audioError ?? 'Not connected to the sound server')),
        subtitle: Text(
          good
              ? 'In Discord, TeamSpeak, Mumble, games etc. choose "fboard Microphone" as the input device'
                    '${s.setDefaultMic ? ', or keep "Default" – fboard makes its microphone the default while it runs' : ''}. '
                    'Turn off noise suppression in those apps, it can cut off sounds.'
              : 'Check that PipeWire (pipewire-pulse) or PulseAudio is running.',
        ),
      ),
      const SectionHeader('Your microphone'),
      ListTile(
        title: const Text('Input device'),
        subtitle: const Text('Your real microphone. Your voice is mixed into the fboard Microphone.'),
        trailing: SizedBox(
          width: 340,
          child: DropdownButton<String?>(
            isExpanded: true,
            value: mics.any((d) => d.name == s.micSource) ? s.micSource : null,
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(
                  'System default (${mics.where((d) => d.name == app.defaultSource).firstOrNull?.desc ?? app.defaultSource})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final d in mics)
                DropdownMenuItem(
                  value: d.name,
                  child: Text(d.desc, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              s.micSource = v;
              app.settingsChanged(vmic: true);
            },
          ),
        ),
      ),
      _switch('Make "fboard Microphone" the default input while fboard runs', s.setDefaultMic, (v) {
        s.setDefaultMic = v;
        app.settingsChanged(vmic: true);
      }, subtitle: 'Apps that use the default microphone then hear your sounds without any setup'),
      const SectionHeader('Speakers'),
      ListTile(
        title: const Text('Output device'),
        subtitle: const Text('Where you hear sounds (and yourself, with Hear myself)'),
        trailing: SizedBox(
          width: 340,
          child: DropdownButton<String?>(
            isExpanded: true,
            value: app.sinks.any((d) => d.name == s.outputSink) ? s.outputSink : null,
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(
                  'System default (${app.sinks.where((d) => d.name == app.defaultSink).firstOrNull?.desc ?? app.defaultSink})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final d in app.sinks)
                DropdownMenuItem(
                  value: d.name,
                  child: Text(d.desc, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              s.outputSink = v;
              app.settingsChanged(audio: true);
            },
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Recreate virtual microphone'),
            onPressed: () {
              app.refreshDevices();
              app.settingsChanged(vmic: true);
              app.showStatus('Virtual microphone recreated');
            },
          ),
        ),
      ),
    ];
  }

  // ================================================================ hotkeys
  List<Widget> _hotkeys(BuildContext context) {
    final hk = app.hotkeys;
    Widget modChips(int mods, ValueChanged<int> onChanged, {bool enabled = true}) => Wrap(
      spacing: 8,
      children: [
        for (final (bit, name) in [(Mod.ctrl, 'Ctrl'), (Mod.shift, 'Shift'), (Mod.alt, 'Alt'), (Mod.meta, 'Super')])
          FilterChip(
            label: Text(name),
            selected: mods & bit != 0,
            onSelected: enabled ? (v) => onChanged(v ? mods | bit : mods & ~bit) : null,
          ),
      ],
    );
    return [
      const SectionHeader('Global hotkeys'),
      ListTile(
        title: const Text('Method'),
        subtitle: Text('Active: ${hk.active?.label ?? 'none'}'),
        trailing: DropdownButton<HotkeyBackend>(
          value: s.hotkeyBackend,
          items: [for (final b in HotkeyBackend.values) DropdownMenuItem(value: b, child: Text(b.label))],
          onChanged: (v) {
            s.hotkeyBackend = v!;
            app.settingsChanged(backend: true);
          },
        ),
      ),
      if (hk.error != null) _hint(hk.error!, error: true),
      _hint(
        'evdev works on every desktop (X11 and all Wayland compositors) and supports mouse buttons, numpad codes '
        'and blocking. It needs your user in the "input" group: sudo usermod -aG input \$USER, then log in again. '
        'The portal method needs no permissions but the desktop decides the final keys.',
      ),
      _switch('Hotkeys enabled', s.hotkeysEnabled, (v) => app.toggleHotkeysEnabled(v)),
      _switch(
        'Pass hotkeys to other applications',
        s.passHotkeys,
        (v) {
          s.passHotkeys = v;
          app.settingsChanged(hotkeyTable: true);
        },
        subtitle: hk.active == HotkeyBackend.evdev
            ? 'When off, fboard swallows its hotkeys so the focused app doesn\'t also receive them'
            : 'Only the evdev method can pass or block keys; X11 and the portal always block',
        enabled: hk.active == HotkeyBackend.evdev,
      ),
      _switch('Auto stop (recommended)', s.autoStop, (v) {
        s.autoStop = v;
        app.settingsChanged();
      }, subtitle: 'Sounds played by hotkey stop at the end even if repeat or continue is on'),
      _switch(
        'Distinguish left and right modifiers',
        s.sidedModifiers,
        (v) {
          s.sidedModifiers = v;
          app.settingsChanged(hotkeyTable: true);
        },
        subtitle: 'Ctrl+F1 and RCtrl+F1 become different hotkeys (evdev only)',
        enabled: hk.active == HotkeyBackend.evdev,
      ),
      _switch('Same hotkeys in all categories', s.sameHotkeysInAllCategories, (v) {
        s.sameHotkeysInAllCategories = v;
        app.settingsChanged(hotkeyTable: true);
      }, subtitle: 'Hotkeys belong to rows: a hotkey plays the sound in its row of the selected category'),
      const SectionHeader('Numpad hotkeys'),
      _switch(
        'Numcode',
        s.numcodeEnabled,
        (v) {
          s.numcodeEnabled = v;
          app.settingsChanged(hotkeyTable: true);
        },
        subtitle: 'Hold the modifier and type a number on the numpad to play that sound (e.g. Alt+123)',
        enabled: hk.supportsNumcode,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: modChips(s.numcodeMods, (m) {
          if (m == 0) return;
          s.numcodeMods = m;
          app.settingsChanged(hotkeyTable: true);
        }, enabled: s.numcodeEnabled),
      ),
      _switch('Index hotkeys', s.indexHotkeysEnabled, (v) {
        s.indexHotkeysEnabled = v;
        app.settingsChanged(hotkeyTable: true);
      }, subtitle: 'Modifier + 1…9, 0 plays sound 1…10 of "All sounds"'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: modChips(s.indexHotkeyMods, (m) {
          if (m == 0) return;
          s.indexHotkeyMods = m;
          app.settingsChanged(hotkeyTable: true);
        }, enabled: s.indexHotkeysEnabled),
      ),
      const SectionHeader('Special hotkey values'),
      ListTile(
        title: Text('Jump back/forward by ${s.jumpSeconds.toStringAsFixed(0)} seconds'),
        subtitle: Slider(
          value: s.jumpSeconds,
          min: 1,
          max: 60,
          onChanged: (v) {
            s.jumpSeconds = v.roundToDouble();
            app.settingsChanged();
          },
        ),
      ),
      ListTile(
        title: Text('Raise/lower speakers volume by ${(s.volumeStep * 100).round()}%'),
        subtitle: Slider(
          value: s.volumeStep,
          min: 0.01,
          max: 0.5,
          onChanged: (v) {
            s.volumeStep = (v * 100).roundToDouble() / 100;
            app.settingsChanged();
          },
        ),
      ),
      ListTile(
        title: Text('"Set speakers volume" sets ${(s.volumeSetValue * 100).round()}%'),
        subtitle: Slider(
          value: s.volumeSetValue,
          onChanged: (v) {
            s.volumeSetValue = (v * 100).roundToDouble() / 100;
            app.settingsChanged();
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.list_alt_rounded),
            label: const Text('Hotkey overview'),
            onPressed: () => showHotkeyOverview(context),
          ),
        ),
      ),
    ];
  }

  List<Widget> _special(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return [
      const SectionHeader('Special hotkeys'),
      _hint('These control fboard itself. They take priority over sound hotkeys.'),
      for (final a in SpecialAction.values)
        ListTile(
          title: Text(a.label),
          subtitle: a.alwaysActive ? const Text('Works even while hotkeys are disabled') : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ActionChip(
                label: Text(
                  s.specialHotkeys[a]?.label(sided: s.sidedModifiers) ?? 'Not set',
                  style: TextStyle(color: s.specialHotkeys[a] == null ? cs.onSurfaceVariant : null),
                ),
                onPressed: () async {
                  final r = await captureHotkey(context, title: a.label, current: s.specialHotkeys[a]);
                  if (r == null) return;
                  if (r.hotkey == null) {
                    s.specialHotkeys.remove(a);
                  } else {
                    final h = r.hotkey!;
                    // A special hotkey can't be shared.
                    s.specialHotkeys.removeWhere((_, v) => v == h);
                    s.specialHotkeys[a] = h;
                  }
                  app.settingsChanged(hotkeyTable: true);
                },
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: s.specialHotkeys[a] == null
                    ? null
                    : () {
                        s.specialHotkeys.remove(a);
                        app.settingsChanged(hotkeyTable: true);
                      },
              ),
            ],
          ),
        ),
    ];
  }

  // ================================================================ auto keys
  List<Widget> _autoKeys(BuildContext context) => [
    const SectionHeader('Auto Keys'),
    _hint(
      'fboard presses these keys for you while a sound plays on the microphone – for example a game\'s '
      'push-to-talk key, or a mute key in your voice app. Set the conditions as strictly as you can: '
      'pressed keys go to whatever application is focused.',
    ),
    _switch('Auto Keys enabled', s.autoKeysEnabled, (v) => app.toggleAutoKeys(v)),
    for (final k in s.autoKeys)
      ListTile(
        leading: Switch(
          value: k.enabled,
          onChanged: (v) {
            k.enabled = v;
            app.settingsChanged();
          },
        ),
        title: Text(k.name.isEmpty ? keyName(k.code) : '${k.name} (${keyName(k.code)})'),
        subtitle: Text(
          '${k.press == AutoKeyPress.hold ? 'Hold during the sound' : 'Press before and after'} · '
          '${k.when.label}${k.apps.isNotEmpty ? ': ${k.apps.join(', ')}' : ''}'
          '${k.onlyHotkey ? ' · hotkey playback only' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editAutoKey(context, k)),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () {
                s.autoKeys.remove(k);
                app.settingsChanged();
              },
            ),
          ],
        ),
      ),
    Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 12,
        children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add auto key'),
            onPressed: () => _editAutoKey(context, null),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.troubleshoot_rounded),
            label: const Text('Troubleshooting'),
            onPressed: () => showAutoKeysTroubleshooting(context),
          ),
        ],
      ),
    ),
    if (app.autoKeys.windowDetectionMethod == null)
      _hint(
        'Note: this desktop doesn\'t let apps see the active window, so the "fullscreen" and '
        '"in foreground" conditions never match here. Use "always" or "application is running".',
      ),
  ];

  Future<void> _editAutoKey(BuildContext context, AutoKey? existing) async {
    final k = existing == null ? AutoKey(code: 0) : AutoKey.fromJson(existing.toJson());
    final name = TextEditingController(text: k.name);
    final apps = TextEditingController(text: k.apps.join(', '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? 'Add auto key' : 'Edit auto key'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name (e.g. "Game PTT")'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Key: '),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: Text(k.code == 0 ? 'Choose key…' : keyName(k.code)),
                        onPressed: () async {
                          final r = await captureHotkey(
                            ctx,
                            title: 'Key to press',
                            current: k.code == 0 ? null : Hotkey(0, k.code),
                            singleKey: true,
                            checkConflicts: false,
                          );
                          if (r?.hotkey != null) setState(() => k.code = r!.hotkey!.code);
                        },
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: k.onlyHotkey,
                    onChanged: (v) => setState(() => k.onlyHotkey = v ?? true),
                    title: const Text('Press only if the sound is played by hotkey'),
                  ),
                  const SizedBox(height: 4),
                  Text('How to press', style: Theme.of(ctx).textTheme.titleSmall),
                  RadioGroup<AutoKeyPress>(
                    groupValue: k.press,
                    onChanged: (v) => setState(() => k.press = v!),
                    child: const Column(
                      children: [
                        RadioListTile(
                          contentPadding: EdgeInsets.zero,
                          value: AutoKeyPress.hold,
                          title: Text('Press and hold'),
                          subtitle: Text('Held for the whole sound, released when it ends or is stopped'),
                        ),
                        RadioListTile(
                          contentPadding: EdgeInsets.zero,
                          value: AutoKeyPress.beforeAndAfter,
                          title: Text('Press before and after'),
                          subtitle: Text('Tapped before the sound starts and again when it ends (toggle keys)'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('When to press', style: Theme.of(ctx).textTheme.titleSmall),
                  RadioGroup<AutoKeyWhen>(
                    groupValue: k.when,
                    onChanged: (v) => setState(() => k.when = v!),
                    child: Column(
                      children: [
                        for (final w in AutoKeyWhen.values)
                          RadioListTile(contentPadding: EdgeInsets.zero, value: w, title: Text(w.label)),
                      ],
                    ),
                  ),
                  if (k.when == AutoKeyWhen.running || k.when == AutoKeyWhen.foreground) ...[
                    TextField(
                      controller: apps,
                      decoration: const InputDecoration(
                        labelText: 'Applications',
                        helperText:
                            'Process names or window classes, separated by commas (e.g. cs2, discord, game.exe)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.list_rounded),
                      label: const Text('Pick from running applications'),
                      onPressed: () async {
                        final procs = AutoKeysService.runningProcesses().toList()..sort();
                        final pick = await showDialog<String>(
                          context: ctx,
                          builder: (c2) => SimpleDialog(
                            title: const Text('Running applications'),
                            children: [
                              SizedBox(
                                width: 400,
                                height: 400,
                                child: ListView(
                                  children: [
                                    for (final pr in procs)
                                      ListTile(title: Text(pr), onTap: () => Navigator.pop(c2, pr)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                        if (pick != null) {
                          apps.text = [
                            ...apps.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
                            pick,
                          ].join(', ');
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: k.code == 0 ? null : () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    k.name = name.text.trim();
    k.apps = apps.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (existing == null) {
      s.autoKeys.add(k);
    } else {
      s.autoKeys[s.autoKeys.indexOf(existing)] = k;
    }
    app.settingsChanged();
  }

  // ================================================================ recorder
  List<Widget> _recorder(BuildContext context) {
    final sources = app.sources;
    return [
      const SectionHeader('Recording'),
      ListTile(
        title: const Text('Record from'),
        trailing: SizedBox(
          width: 340,
          child: DropdownButton<String?>(
            isExpanded: true,
            value: sources.any((d) => d.name == s.recordSource) ? s.recordSource : null,
            items: [
              const DropdownMenuItem(value: null, child: Text('What you hear (speakers)')),
              for (final d in sources)
                DropdownMenuItem(
                  value: d.name,
                  child: Text(d.desc, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              s.recordSource = v;
              app.settingsChanged();
            },
          ),
        ),
      ),
      ListTile(
        title: const Text('Save as'),
        subtitle: const Text('Also used when saving edited sounds'),
        trailing: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'm4a', label: Text('M4A')),
            ButtonSegment(value: 'mp3', label: Text('MP3')),
            ButtonSegment(value: 'ogg', label: Text('OGG')),
            ButtonSegment(value: 'opus', label: Text('OPUS')),
            ButtonSegment(value: 'flac', label: Text('FLAC')),
            ButtonSegment(value: 'wav', label: Text('WAV')),
          ],
          selected: {s.recordFormat},
          onSelectionChanged: (v) {
            s.recordFormat = v.first;
            app.settingsChanged();
          },
        ),
      ),
      ListTile(
        title: const Text('Insert position in sound list'),
        trailing: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Beginning')),
            ButtonSegment(value: true, label: Text('End')),
          ],
          selected: {s.recordInsertAtEnd},
          onSelectionChanged: (v) {
            s.recordInsertAtEnd = v.first;
            app.settingsChanged();
          },
        ),
      ),
      ListTile(
        title: const Text('Recordings folder'),
        subtitle: Text(s.recordDirectory ?? Paths.recordings),
        trailing: OutlinedButton(
          onPressed: () async {
            final d = await pickDirectory(context, 'Recordings folder');
            if (d != null) {
              s.recordDirectory = d;
              app.settingsChanged();
            }
          },
          child: const Text('Change…'),
        ),
      ),
      _switch('Automatically normalize recordings', s.recordNormalize, (v) {
        s.recordNormalize = v;
        app.settingsChanged();
      }),
      ListTile(
        enabled: s.recordNormalize,
        title: Text(
          'Normalize to ${s.recordNormalizeTarget.toStringAsFixed(0)} LUFS '
          '(${lufsToSoundpadDb(s.recordNormalizeTarget).toStringAsFixed(0)} dB)',
        ),
        subtitle: Slider(
          value: s.recordNormalizeTarget.clamp(-40.0, -8.0),
          min: -40,
          max: -8,
          onChanged: s.recordNormalize
              ? (v) {
                  s.recordNormalizeTarget = v.roundToDouble();
                  app.settingsChanged();
                }
              : null,
        ),
      ),
      if (s.recordNormalizeTarget > -13) _hint('Values above 99 dB (-13 LUFS) may clip and distort.', error: true),
      _switch('Trim silence', s.recordTrimSilence, (v) {
        s.recordTrimSilence = v;
        app.settingsChanged();
      }, subtitle: 'Removes silence at the beginning and end of new recordings'),
      ListTile(
        title: Text(
          s.recordMaxSeconds <= 0
              ? 'Maximum recording time: unlimited'
              : 'Maximum recording time: ${formatDuration(s.recordMaxSeconds)}',
        ),
        subtitle: Slider(
          value: s.recordMaxSeconds.clamp(0, 3600),
          max: 3600,
          onChanged: (v) {
            s.recordMaxSeconds = (v / 30).roundToDouble() * 30;
            app.settingsChanged();
          },
        ),
      ),
      _hint('Recordings are stereo, 48 kHz. 0 = no limit (recording continues until stopped).'),
    ];
  }

  // ================================================================ notifications
  List<Widget> _notifications(BuildContext context) {
    Widget pref(String title, NotificationPref n, int kind) => ListTile(
      title: Text(title),
      subtitle: Text(n.path ?? 'Built-in tone'),
      leading: Switch(
        value: n.enabled,
        onChanged: (v) {
          n.enabled = v;
          app.settingsChanged();
        },
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            tooltip: 'Test',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: () => app.native.playNotification(kind, n.path),
          ),
          if (n.path != null)
            IconButton(
              tooltip: 'Use built-in tone',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: () {
                n.path = null;
                app.settingsChanged();
              },
            ),
          IconButton(
            tooltip: 'Choose sound…',
            icon: const Icon(Icons.audio_file_outlined),
            onPressed: () async {
              final f = await pickAudioFile(context);
              if (f != null && File(f).existsSync()) {
                n.path = f;
                app.settingsChanged();
              }
            },
          ),
        ],
      ),
    );
    return [
      const SectionHeader('Acoustic notifications'),
      _hint('Played on your speakers only, so you know what a hotkey did while you\'re in a game.'),
      pref('Play mode changed by hotkey', s.notifyPlayMode, 0),
      pref('Recorder started/stopped by hotkey', s.notifyRecorder, 2),
      pref('Hotkeys enabled/disabled by hotkey', s.notifyHotkeysToggle, 1),
      pref('Auto Keys enabled/disabled by hotkey', s.notifyAutoKeysToggle, 1),
      _switch('Notify me when playing the first sound after start in a mode other than default', s.notifyFirstSound, (
        v,
      ) {
        s.notifyFirstSound = v;
        app.settingsChanged();
      }),
    ];
  }
}
