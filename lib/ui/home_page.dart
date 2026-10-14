// SPDX-License-Identifier: GPL-3.0-or-later
// Panels read the global app state, so they are deliberately not const:
// const widgets would be skipped when the page rebuilds.
// ignore_for_file: prefer_const_constructors
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../main.dart' show quitApp;
import '../models/settings.dart';
import '../models/sound_list.dart';
import 'categories_panel.dart';
import 'common.dart';
import 'dialogs.dart';
import 'editor_dialog.dart';
import 'hotbar_panel.dart';
import 'hotkey_dialog.dart';
import 'preferences_dialog.dart';
import 'recorder_panel.dart';
import 'sound_table.dart';
import 'status_bar.dart';
import 'toolbar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _rootFocus = FocusNode(debugLabel: 'root');
  final _searchFocus = FocusNode(debugLabel: 'search');
  final _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    app.addListener(_onChange);
  }

  @override
  void dispose() {
    app.removeListener(_onChange);
    _rootFocus.dispose();
    _searchFocus.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!app.searchOpen && _searchCtl.text.isNotEmpty) _searchCtl.clear();
    setState(() {});
  }

  // ================================================================ actions
  Future<void> _addFiles() async {
    final files = await pickAudioFiles(context);
    if (files.isNotEmpty) await app.addFiles(files);
  }

  Future<void> _addFolder() async {
    final d = await pickDirectory(context, 'Add folder');
    if (d != null) await app.addFiles([d]);
  }

  Future<bool> _confirmDiscard() async {
    if (!app.dirty || app.list.sounds.isEmpty) return true;
    return confirm(
      context,
      title: 'Unsaved changes',
      message: 'The current sound list has unsaved changes. Continue without saving?',
      confirm: 'Continue',
      destructive: true,
    );
  }

  Future<void> _newList() async {
    if (await _confirmDiscard()) app.newList();
  }

  Future<void> _loadList([String? path]) async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    path ??= await pickListFile(context);
    if (path != null) app.loadList(path);
  }

  Future<void> _save() async {
    if (app.listPath == null) {
      await _saveAs();
    } else {
      app.saveList();
    }
  }

  Future<void> _saveAs() async {
    final name = app.listPath != null ? p.basename(app.listPath!) : 'soundlist.${SoundList.fileExtension}';
    final path = await pickSavePath(
      context,
      title: 'Save sound list as',
      fileName: name,
      extensions: [SoundList.fileExtension],
    );
    if (path != null) app.saveList(path);
  }

  Future<void> _exportSounds() async {
    final d = await pickDirectory(context, 'Export sound files to');
    if (d != null) await app.exportSoundFiles(d);
  }

  Future<void> _exportPrefs() async {
    final path = await pickSavePath(
      context,
      title: 'Export preferences',
      fileName: 'fboard-preferences.json',
      extensions: ['json'],
    );
    if (path != null) app.exportPreferences(path);
  }

  Future<void> _importPrefs() async {
    final path = await pickJsonFile(context, 'Import preferences');
    if (path != null) app.importPreferences(path);
  }

  void _rename() {
    final s = app.focused ?? (app.selectedSounds.isNotEmpty ? app.selectedSounds.first : null);
    if (s != null) showRenameDialog(context, s);
  }

  void _edit() {
    final s = app.focused ?? (app.selectedSounds.isNotEmpty ? app.selectedSounds.first : null);
    if (s != null) showEditorDialog(context, s);
  }

  void _setHotkey() {
    final s = app.focused ?? (app.selectedSounds.isNotEmpty ? app.selectedSounds.first : null);
    if (s != null) showHotkeyDialogForSound(context, s);
  }

  void _openSearch([String initial = '']) {
    app.openSearch(initial);
    _searchCtl.text = initial;
    _searchCtl.selection = TextSelection.collapsed(offset: initial.length);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _closeSearch() {
    app.closeSearch();
    _searchCtl.clear();
    _rootFocus.requestFocus();
  }

  void _toggleRecorder() {
    app.settings.showRecorder = !app.settings.showRecorder;
    app.settingsChanged();
  }

  // ================================================================ keyboard
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    final ctrl = k.isControlPressed, shift = k.isShiftPressed, alt = k.isAltPressed;
    final key = e.logicalKey;
    final inSearch = _searchFocus.hasFocus;

    if (inSearch) {
      if (key == LogicalKeyboardKey.escape) {
        _closeSearch();
      } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
        if (ctrl) {
          app.playSelected();
        } else if (shift) {
          app.previousHit();
        } else {
          app.nextHit();
        }
      } else if (key == LogicalKeyboardKey.arrowDown) {
        app.nextHit();
      } else if (key == LogicalKeyboardKey.arrowUp) {
        app.previousHit();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    // Ignore keys while another text field (dialogs) has focus.
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary != _rootFocus && primary.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }

    bool done(void Function() f) {
      f();
      return true;
    }

    final handled = switch (key) {
      LogicalKeyboardKey.arrowUp when ctrl => done(() => app.moveSelection(-1)),
      LogicalKeyboardKey.arrowDown when ctrl => done(() => app.moveSelection(1)),
      LogicalKeyboardKey.arrowUp => done(() => app.moveFocus(-1, extend: shift)),
      LogicalKeyboardKey.arrowDown => done(() => app.moveFocus(1, extend: shift)),
      LogicalKeyboardKey.pageUp => done(() => app.moveFocus(-15, extend: shift)),
      LogicalKeyboardKey.pageDown => done(() => app.moveFocus(15, extend: shift)),
      LogicalKeyboardKey.home when !ctrl => done(() => app.moveFocus(-1 << 30, extend: shift)),
      LogicalKeyboardKey.end when !ctrl => done(() => app.moveFocus(1 << 30, extend: shift)),
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => done(() => app.playSelected()),
      LogicalKeyboardKey.space when !ctrl => done(app.pauseResume),
      LogicalKeyboardKey.delete when shift => done(() => confirmTrash(context)),
      LogicalKeyboardKey.delete => done(() => app.removeSelected()),
      LogicalKeyboardKey.f2 => done(_rename),
      LogicalKeyboardKey.escape => done(app.selectNone),
      LogicalKeyboardKey.keyA when ctrl => done(app.selectAll),
      LogicalKeyboardKey.keyC when ctrl => done(() => app.copy()),
      LogicalKeyboardKey.keyX when ctrl => done(() => app.copy(cut: true)),
      LogicalKeyboardKey.keyV when ctrl => done(app.paste),
      LogicalKeyboardKey.keyZ when ctrl && shift => done(app.redo),
      LogicalKeyboardKey.keyZ when ctrl => done(app.undo),
      LogicalKeyboardKey.keyY when ctrl => done(app.redo),
      LogicalKeyboardKey.keyF when ctrl => done(_openSearch),
      LogicalKeyboardKey.keyS when ctrl && shift => done(_saveAs),
      LogicalKeyboardKey.keyS when ctrl => done(_save),
      LogicalKeyboardKey.keyO when ctrl => done(_loadList),
      LogicalKeyboardKey.keyN when ctrl => done(_newList),
      LogicalKeyboardKey.keyR when ctrl => done(_toggleRecorder),
      LogicalKeyboardKey.keyH when ctrl => done(_setHotkey),
      LogicalKeyboardKey.keyE when ctrl => done(_edit),
      LogicalKeyboardKey.keyQ when ctrl => done(quitApp),
      LogicalKeyboardKey.comma when ctrl => done(() => showPreferences(context)),
      LogicalKeyboardKey.insert => done(_addFiles),
      _ => false,
    };
    if (handled) return KeyEventResult.handled;

    // Typing begins search.
    final ch = e.character;
    if (app.settings.typingBeginsSearch &&
        !ctrl &&
        !alt &&
        ch != null &&
        ch.length == 1 &&
        ch.codeUnitAt(0) >= 0x20 &&
        ch != ' ') {
      _openSearch(ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ================================================================ build
  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    return Scaffold(
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (_) {
            if (!_searchFocus.hasFocus) _rootFocus.requestFocus();
          },
          child: Column(
            children: [
              _menuBar(context),
              PlayerToolbar(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (s.showCategories) ...[
                      CategoriesPanel(),
                      _ResizeHandle(
                        onDrag: (dx) {
                          s.categoriesWidth = (s.categoriesWidth + dx).clamp(160.0, 520.0);
                          app.refresh();
                        },
                        onEnd: app.saveSettings,
                      ),
                    ] else
                      const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        children: [
                          if (app.searchOpen) _searchBar(context),
                          Expanded(child: SoundTable()),
                          if (s.showHotbar) HotbarPanel(),
                          if (s.showRecorder || app.recorder.active) RecorderPanel(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              StatusBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hits = app.searchHits.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
      child: SearchBar(
        controller: _searchCtl,
        focusNode: _searchFocus,
        hintText: 'Search sounds',
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
        leading: const Icon(Icons.search_rounded),
        onChanged: app.setSearch,
        trailing: [
          if (app.searchQuery.isNotEmpty)
            Text(
              hits == 0 ? 'No results' : '${app.searchHitIndex + 1} of $hits',
              style: TextStyle(color: hits == 0 ? cs.error : cs.onSurfaceVariant),
            ),
          IconButton(
            tooltip: 'Previous hit (Shift+Enter)',
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
            onPressed: app.previousHit,
          ),
          IconButton(
            tooltip: 'Next hit (Enter)',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: app.nextHit,
          ),
          IconButton(
            tooltip: 'Play selected hit (Ctrl+Enter)',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: () => app.playSelected(),
          ),
          IconButton(tooltip: 'Clear search (Esc)', icon: const Icon(Icons.close_rounded), onPressed: _closeSearch),
        ],
      ),
    );
  }

  // ================================================================ menu bar
  Widget _menuBar(BuildContext context) {
    final s = app.settings;
    final hasSel = app.selection.isNotEmpty;
    MenuItemButton item(String label, VoidCallback? fn, {IconData? icon, String? shortcut}) => MenuItemButton(
      leadingIcon: icon == null ? const SizedBox(width: 24) : Icon(icon, size: 20),
      trailingIcon: shortcut == null
          ? null
          : Text(shortcut, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      onPressed: fn,
      child: Text(label),
    );
    CheckboxMenuButton check(String label, bool value, VoidCallback fn) =>
        CheckboxMenuButton(value: value, onChanged: (_) => fn(), child: Text(label));

    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Image.asset('assets/icon.png', width: 22, height: 22),
        ),
        Expanded(
          child: MenuBar(
            children: [
              SubmenuButton(
                menuChildren: [
                  item('New sound list', _newList, icon: Icons.note_add_outlined, shortcut: 'Ctrl+N'),
                  item('Load sound list…', () => _loadList(), icon: Icons.folder_open_outlined, shortcut: 'Ctrl+O'),
                  SubmenuButton(
                    leadingIcon: const Icon(Icons.history_rounded, size: 20),
                    menuChildren: [
                      for (final r in s.recentLists)
                        MenuItemButton(onPressed: File(r).existsSync() ? () => _loadList(r) : null, child: Text(r)),
                      if (s.recentLists.isEmpty) const MenuItemButton(child: Text('No recent lists')),
                    ],
                    child: const Text('Load recent sound list'),
                  ),
                  item('Save sound list', _save, icon: Icons.save_outlined, shortcut: 'Ctrl+S'),
                  item('Save sound list as…', _saveAs, shortcut: 'Ctrl+Shift+S'),
                  const Divider(),
                  item('Add sound files…', _addFiles, icon: Icons.library_add_outlined, shortcut: 'Insert'),
                  item('Add folder…', _addFolder, icon: Icons.create_new_folder_outlined),
                  const Divider(),
                  item('Restore sound list…', () => showBackupsDialog(context), icon: Icons.restore_rounded),
                  SubmenuButton(
                    leadingIcon: const Icon(Icons.ios_share_rounded, size: 20),
                    menuChildren: [item('Sound files…', _exportSounds), item('Preferences…', _exportPrefs)],
                    child: const Text('Export'),
                  ),
                  item('Import preferences…', _importPrefs, icon: Icons.download_rounded),
                  const Divider(),
                  item(
                    'Preferences…',
                    () => showPreferences(context),
                    icon: Icons.settings_outlined,
                    shortcut: 'Ctrl+,',
                  ),
                  const Divider(),
                  item('Quit', quitApp, icon: Icons.power_settings_new_rounded, shortcut: 'Ctrl+Q'),
                ],
                child: const Text('File'),
              ),
              SubmenuButton(
                menuChildren: [
                  item('Undo', app.canUndo ? app.undo : null, icon: Icons.undo_rounded, shortcut: 'Ctrl+Z'),
                  item('Redo', app.canRedo ? app.redo : null, icon: Icons.redo_rounded, shortcut: 'Ctrl+Y'),
                  const Divider(),
                  item('Cut', hasSel ? () => app.copy(cut: true) : null, icon: Icons.cut_rounded, shortcut: 'Ctrl+X'),
                  item('Copy', hasSel ? () => app.copy() : null, icon: Icons.copy_rounded, shortcut: 'Ctrl+C'),
                  item('Paste', app.paste, icon: Icons.paste_rounded, shortcut: 'Ctrl+V'),
                  const Divider(),
                  item(
                    'Remove selected entries',
                    hasSel ? () => app.removeSelected() : null,
                    icon: Icons.remove_circle_outline_rounded,
                    shortcut: 'Del',
                  ),
                  item(
                    'Move files to trash',
                    hasSel ? () => confirmTrash(context) : null,
                    icon: Icons.delete_outline_rounded,
                    shortcut: 'Shift+Del',
                  ),
                  item(
                    'Rename file',
                    hasSel ? _rename : null,
                    icon: Icons.drive_file_rename_outline_rounded,
                    shortcut: 'F2',
                  ),
                  item('Edit file…', hasSel ? _edit : null, icon: Icons.content_cut_rounded, shortcut: 'Ctrl+E'),
                  item('Set hotkey…', hasSel ? _setHotkey : null, icon: Icons.keyboard_rounded, shortcut: 'Ctrl+H'),
                  item(
                    'Add to category…',
                    hasSel && app.list.allCategories.isNotEmpty ? () => showAddToCategoryDialog(context) : null,
                    icon: Icons.drive_file_move_outline,
                  ),
                  const Divider(),
                  item(
                    'Move up',
                    hasSel ? () => app.moveSelection(-1) : null,
                    icon: Icons.arrow_upward_rounded,
                    shortcut: 'Ctrl+↑',
                  ),
                  item(
                    'Move down',
                    hasSel ? () => app.moveSelection(1) : null,
                    icon: Icons.arrow_downward_rounded,
                    shortcut: 'Ctrl+↓',
                  ),
                  const Divider(),
                  item('Select all', app.selectAll, icon: Icons.select_all_rounded, shortcut: 'Ctrl+A'),
                  item('Select none', app.selectNone, shortcut: 'Esc'),
                  item('Invert selection', app.invertSelection),
                  const Divider(),
                  item('Search', _openSearch, icon: Icons.search_rounded, shortcut: 'Ctrl+F'),
                ],
                child: const Text('Edit'),
              ),
              SubmenuButton(
                menuChildren: [
                  item(
                    'Play selected file',
                    () => app.playSelected(),
                    icon: Icons.play_arrow_rounded,
                    shortcut: 'Enter',
                  ),
                  item(
                    'Play selected file on speakers',
                    () => app.playSelected(mode: PlayMode.speakers),
                    icon: Icons.volume_up_rounded,
                  ),
                  item(
                    'Play selected file on microphone',
                    () => app.playSelected(mode: PlayMode.mic),
                    icon: Icons.mic_rounded,
                  ),
                  item('Pause/resume', app.pauseResume, icon: Icons.pause_rounded, shortcut: 'Space'),
                  item('Stop', app.stop, icon: Icons.stop_rounded),
                  item('Play previous file', () => app.playPrevious(), icon: Icons.skip_previous_rounded),
                  item('Play next file', () => app.playNext(), icon: Icons.skip_next_rounded),
                  const Divider(),
                  item('Play random file', () => app.playRandom(), icon: Icons.shuffle_rounded),
                  item('Play random file on speakers only', () => app.playRandom(mode: PlayMode.speakers)),
                  item('Play random file on microphone only', () => app.playRandom(mode: PlayMode.mic)),
                  item('Play random file from all categories', () => app.playRandom(allCategories: true)),
                  const Divider(),
                  for (final m in PlayMode.values)
                    RadioMenuButton<PlayMode>(
                      value: m,
                      groupValue: s.playMode,
                      onChanged: (v) => app.setPlayMode(v!),
                      child: Text(m.label),
                    ),
                  const Divider(),
                  check('Repeat playback of current file', s.repeatCurrent, app.toggleRepeat),
                  check('Continue playback after current file', s.continuePlayback, app.toggleContinue),
                  check('Repeat playback of sound list', s.repeatList, app.toggleRepeatList),
                  const Divider(),
                  check('Hear myself', s.hearMyself, app.toggleHearMyself),
                  check('Block voice', s.blockVoice, app.toggleBlockVoice),
                ],
                child: const Text('Play'),
              ),
              SubmenuButton(
                menuChildren: [
                  SubmenuButton(
                    menuChildren: [
                      check('Open', s.showCategories, () {
                        s.showCategories = !s.showCategories;
                        app.settingsChanged();
                      }),
                      check('Show info', s.showCategoryInfo, () {
                        s.showCategoryInfo = !s.showCategoryInfo;
                        app.settingsChanged();
                      }),
                      const Divider(),
                      for (final (i, n) in [(0, 'Smaller'), (1, 'Small'), (2, 'Medium'), (3, 'Large')])
                        RadioMenuButton<int>(
                          value: i,
                          groupValue: s.categoryIconSize,
                          onChanged: (v) {
                            s.categoryIconSize = v!;
                            app.settingsChanged();
                          },
                          child: Text(n),
                        ),
                    ],
                    child: const Text('Categories'),
                  ),
                  SubmenuButton(
                    menuChildren: [
                      check('Open', s.showHotbar, () {
                        s.showHotbar = !s.showHotbar;
                        app.settingsChanged();
                      }),
                      item('Set hotbar format…', () => showHotbarFormatDialog(context)),
                      check(
                        'Same colors on all pages',
                        app.list.hotbar.sameColorsOnAllPages,
                        () => app.hotbarSetSameColors(!app.list.hotbar.sameColorsOnAllPages),
                      ),
                    ],
                    child: const Text('Hotbar'),
                  ),
                  check('Sound recorder', s.showRecorder, _toggleRecorder),
                  SubmenuButton(
                    menuChildren: [
                      check('Hotkeys enabled', s.hotkeysEnabled, () => app.toggleHotkeysEnabled()),
                      item('Hotkey overview', () => showHotkeyOverview(context)),
                    ],
                    child: const Text('Hotkeys'),
                  ),
                  item('Notifications', () => showNoticesDialog(context)),
                ],
                child: const Text('Window'),
              ),
              SubmenuButton(
                menuChildren: [
                  item('Auto Keys troubleshooting', () => showAutoKeysTroubleshooting(context)),
                  item('About fboard', () => showAboutFboard(context), icon: Icons.info_outline_rounded),
                ],
                child: const Text('Help'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onEnd;
  const _ResizeHandle({required this.onDrag, required this.onEnd});
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => onEnd(),
      child: const SizedBox(width: 8),
    ),
  );
}
