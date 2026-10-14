// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../models/settings.dart' show allColumns, PlayMode;
import '../models/sound_list.dart';
import '../services/dsp.dart';
import '../services/file_ops.dart';
import 'dialogs.dart';
import 'editor_dialog.dart';
import 'hotkey_dialog.dart';

const _rowHeight = 34.0;

const _defaultWidths = <String, double>{
  'index': 52, 'tag': 340, 'title': 220, 'artist': 180, 'file': 240, 'duration': 84, 'hotkey': 150, //
  'format': 72, 'size': 84, 'playCount': 96, 'added': 150, 'lastPlayed': 150, 'path': 420,
};

/// Payload for dragging sounds around (to categories, hotbar, reordering).
class SoundDragData {
  final List<String> ids;
  SoundDragData(this.ids);
}

class SoundTable extends StatefulWidget {
  const SoundTable({super.key});
  @override
  State<SoundTable> createState() => _SoundTableState();
}

class _SoundTableState extends State<SoundTable> {
  final _vScroll = ScrollController();
  final _hScroll = ScrollController();
  bool _dropHover = false;
  int? _dropIndex;
  String? _lastFocus;

  List<String> get _cols => app.settings.columnOrder.where((c) => !app.settings.hiddenColumns.contains(c)).toList();

  double _width(String c) => app.settings.columnWidths[c] ?? _defaultWidths[c] ?? 120;

  @override
  void dispose() {
    _vScroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  void _ensureFocusVisible(List<Sound> view) {
    final f = app.focusId;
    if (f == null || f == _lastFocus || !_vScroll.hasClients) {
      _lastFocus = f;
      return;
    }
    _lastFocus = f;
    final i = view.indexWhere((s) => s.id == f);
    if (i < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_vScroll.hasClients) return;
      final top = i * _rowHeight;
      final pos = _vScroll.position;
      if (top < pos.pixels) {
        _vScroll.jumpTo(top);
      } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
        _vScroll.jumpTo(math.min(pos.maxScrollExtent, top + _rowHeight - pos.viewportDimension));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final view = app.view;
    _ensureFocusVisible(view);
    final cols = _cols;
    final total = cols.fold<double>(0, (a, c) => a + _width(c)) + 16;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dropHover = true),
      onDragExited: (_) => setState(() => _dropHover = false),
      onDragDone: (d) {
        setState(() => _dropHover = false);
        final rowAt = ((d.localPosition.dy - _rowHeight + (_vScroll.hasClients ? _vScroll.offset : 0)) / _rowHeight)
            .floor()
            .clamp(0, view.length);
        int? insertAt;
        if (rowAt < view.length && app.settings.sortColumn == null) {
          final base = app.selectedCategory == null
              ? app.list.sounds.map((s) => s.id).toList()
              : app.selectedCategory!.soundIds;
          insertAt = base.indexOf(view[rowAt].id);
        }
        app.addFiles(d.files.map((f) => f.path).toList(), insertAt: insertAt);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(0, 0, 8, 0),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: _dropHover ? Border.all(color: cs.primary, width: 2) : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, bc) {
            final w = math.max(total, bc.maxWidth);
            return Scrollbar(
              controller: _hScroll,
              notificationPredicate: (n) => n.depth == 0,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: w,
                  child: Column(
                    children: [
                      _header(context, cols),
                      const Divider(),
                      Expanded(
                        child: view.isEmpty
                            ? _empty(context)
                            : Scrollbar(
                                controller: _vScroll,
                                child: ListView.builder(
                                  controller: _vScroll,
                                  itemExtent: _rowHeight,
                                  itemCount: view.length,
                                  itemBuilder: (context, i) => _row(context, view, i, cols),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined, size: 56, color: cs.outline),
          const SizedBox(height: 12),
          Text(
            app.selectedCategory == null ? 'No sounds yet' : 'This category is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Drop sound files or folders here, or use File › Add sound files',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ header
  Widget _header(BuildContext context, List<String> cols) {
    final cs = Theme.of(context).colorScheme;
    final s = app.settings;
    return GestureDetector(
      onSecondaryTapUp: (d) => _headerMenu(context, d.globalPosition),
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            for (final c in cols)
              DragTarget<String>(
                onWillAcceptWithDetails: (d) => d.data != c,
                onAcceptWithDetails: (d) {
                  final order = s.columnOrder;
                  order.remove(d.data);
                  order.insert(order.indexOf(c), d.data);
                  app.saveSettings();
                  setState(() {});
                },
                builder: (context, cand, _) => Container(
                  width: _width(c),
                  decoration: cand.isNotEmpty
                      ? BoxDecoration(
                          border: Border(left: BorderSide(color: cs.primary, width: 2)),
                        )
                      : null,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Draggable<String>(
                          data: c,
                          axis: Axis.horizontal,
                          feedback: Material(
                            color: cs.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(padding: const EdgeInsets.all(8), child: Text(allColumns[c]!)),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => app.sortBy(c),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      allColumns[c]!,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.labelLarge
                                          ?.copyWith(color: cs.onSurfaceVariant),
                                    ),
                                  ),
                                  if (s.sortColumn == c)
                                    Icon(
                                      s.sortAscending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                                      size: 16,
                                      color: cs.primary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 8,
                        bottom: 8,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (d) {
                              setState(() => s.columnWidths[c] = math.max(40, _width(c) + d.delta.dx));
                            },
                            onHorizontalDragEnd: (_) => app.saveSettings(),
                            onDoubleTap: () {
                              setState(() => s.columnWidths.remove(c));
                              app.saveSettings();
                            },
                            child: SizedBox(
                              width: 8,
                              child: Center(child: Container(width: 1, color: cs.outlineVariant)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _headerMenu(BuildContext context, Offset pos) {
    final s = app.settings;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, 0),
      items: [
        for (final e in allColumns.entries)
          CheckedPopupMenuItem(
            checked: !s.hiddenColumns.contains(e.key),
            onTap: () {
              if (!s.hiddenColumns.remove(e.key)) {
                if (_cols.length > 1) s.hiddenColumns.add(e.key);
              }
              app.saveSettings();
              setState(() {});
            },
            child: Text(e.value),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(onTap: app.clearSort, enabled: s.sortColumn != null, child: const Text('Restore list order')),
        PopupMenuItem(
          onTap: () {
            s.columnWidths.clear();
            app.saveSettings();
            setState(() {});
          },
          child: const Text('Reset column widths'),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ rows
  Widget _row(BuildContext context, List<Sound> view, int i, List<String> cols) {
    final cs = Theme.of(context).colorScheme;
    final s = view[i];
    final selected = app.selection.contains(s.id);
    final playing = app.currentSoundId == s.id;
    final hit = app.searchHits.contains(s.id);
    final focused = app.focusId == s.id;
    final missing = s.size == 0 && s.duration == 0;

    Color? bg;
    if (selected) {
      bg = cs.secondaryContainer;
    } else if (hit) {
      bg = cs.tertiaryContainer.withValues(alpha: 0.5);
    }
    final fg = selected ? cs.onSecondaryContainer : (playing ? cs.primary : cs.onSurface);
    final style = TextStyle(color: missing ? cs.error : fg, fontWeight: playing ? FontWeight.w600 : null);

    final row = Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: focused && !selected ? cs.outline.withValues(alpha: 0.6) : Colors.transparent),
      ),
      child: Row(
        children: [
          for (final c in cols)
            SizedBox(
              width: _width(c) - (c == cols.first ? 6 : 0),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _cell(c, s, style, playing)),
            ),
        ],
      ),
    );

    final dragIds = selected ? app.selectedSounds.map((x) => x.id).toList() : [s.id];
    return DragTarget<SoundDragData>(
      onWillAcceptWithDetails: (d) => !d.data.ids.contains(s.id),
      onMove: (d) {
        if (_dropIndex != i) setState(() => _dropIndex = i);
      },
      onLeave: (_) => setState(() => _dropIndex = null),
      onAcceptWithDetails: (d) {
        setState(() => _dropIndex = null);
        final base = app.selectedCategory == null
            ? app.list.sounds.map((x) => x.id).toList()
            : app.selectedCategory!.soundIds;
        final ids = d.data.ids.where(base.contains).toList();
        if (ids.length == d.data.ids.length) {
          app.reorder(ids, base.indexOf(s.id));
        } else if (app.selectedCategory != null) {
          app.addToCategory(app.selectedCategory!, d.data.ids);
        }
      },
      builder: (context, cand, _) => Container(
        decoration: _dropIndex == i && cand.isNotEmpty
            ? BoxDecoration(
                border: Border(top: BorderSide(color: cs.primary, width: 2)),
              )
            : null,
        child: Draggable<SoundDragData>(
          data: SoundDragData(dragIds),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            elevation: 3,
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.music_note_rounded, size: 18, color: cs.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    dragIds.length == 1 ? s.tag : '${dragIds.length} sounds',
                    style: TextStyle(color: cs.onPrimaryContainer),
                  ),
                ],
              ),
            ),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) {
              final k = HardwareKeyboard.instance;
              app.click(s, ctrl: k.isControlPressed, shift: k.isShiftPressed);
            },
            onDoubleTap: () => app.play(s),
            onSecondaryTapUp: (d) {
              if (!app.selection.contains(s.id)) app.selectOnly(s);
              showSoundContextMenu(context, d.globalPosition, s);
            },
            child: row,
          ),
        ),
      ),
    );
  }

  Widget _cell(String c, Sound s, TextStyle style, bool playing) {
    String text;
    switch (c) {
      case 'index':
        return Row(
          children: [
            if (playing)
              Icon(app.isPaused ? Icons.pause_rounded : Icons.graphic_eq_rounded, size: 16, color: style.color)
            else
              Text('${app.indexOf(s)}', style: style),
          ],
        );
      case 'tag':
        text = s.tag;
      case 'title':
        text = s.title;
      case 'artist':
        text = s.artist;
      case 'file':
        text = s.fileName;
      case 'duration':
        text = formatDuration(s.duration);
      case 'hotkey':
        text = app.hotkeyOf(s)?.label(sided: app.settings.sidedModifiers) ?? '';
      case 'format':
        text = s.format;
      case 'size':
        text = s.size > 0 ? formatSize(s.size) : '';
      case 'playCount':
        text = '${s.playCount}';
      case 'added':
        text = _date(s.added);
      case 'lastPlayed':
        text = s.lastPlayed == null ? '' : _date(s.lastPlayed!);
      case 'path':
        text = s.path;
      default:
        text = '';
    }
    return Text(text, style: style, overflow: TextOverflow.ellipsis, maxLines: 1);
  }

  String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// Context menu for sound entries (also used by the hotbar).
Future<void> showSoundContextMenu(BuildContext context, Offset pos, Sound s, {bool fromHotbar = false}) async {
  final multi = app.selection.length > 1 && !fromHotbar;
  await showMenu<void>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, 0),
    items: [
      PopupMenuItem(onTap: () => app.play(s), child: const _MI(Icons.play_arrow_rounded, 'Play', 'Enter')),
      PopupMenuItem(
        onTap: () => app.play(s, mode: PlayMode.speakers),
        child: const _MI(Icons.volume_up_rounded, 'Play on speakers'),
      ),
      PopupMenuItem(
        onTap: () => app.play(s, mode: PlayMode.mic),
        child: const _MI(Icons.mic_rounded, 'Play on microphone'),
      ),
      const PopupMenuDivider(),
      if (!fromHotbar) ...[
        PopupMenuItem(
          onTap: () => showHotkeyDialogForSound(context, s),
          child: const _MI(Icons.keyboard_rounded, 'Set hotkey…'),
        ),
        if (app.hotkeyOf(s) != null)
          PopupMenuItem(
            onTap: () => app.setSoundHotkey(s, null),
            child: const _MI(Icons.keyboard_hide_rounded, 'Remove hotkey'),
          ),
        const PopupMenuDivider(),
      ],
      PopupMenuItem(
        enabled: !multi,
        onTap: () => showEditorDialog(context, s),
        child: const _MI(Icons.content_cut_rounded, 'Edit file…'),
      ),
      PopupMenuItem(
        enabled: !multi,
        onTap: () => showRenameDialog(context, s),
        child: const _MI(Icons.drive_file_rename_outline_rounded, 'Rename file', 'F2'),
      ),
      PopupMenuItem(
        onTap: () => showInFileManager(s.path),
        child: const _MI(Icons.folder_open_rounded, 'Select in file manager'),
      ),
      if (!fromHotbar) ...[
        PopupMenuItem(
          enabled: app.list.allCategories.isNotEmpty,
          onTap: () => showAddToCategoryDialog(context),
          child: const _MI(Icons.drive_file_move_outline, 'Add to category…'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(onTap: () => app.copy(), child: const _MI(Icons.copy_rounded, 'Copy', 'Ctrl+C')),
        PopupMenuItem(onTap: () => app.copy(cut: true), child: const _MI(Icons.cut_rounded, 'Cut', 'Ctrl+X')),
        PopupMenuItem(onTap: app.paste, child: const _MI(Icons.paste_rounded, 'Paste', 'Ctrl+V')),
        const PopupMenuDivider(),
        PopupMenuItem(
          onTap: () => app.removeSelected(),
          child: _MI(
            Icons.remove_circle_outline_rounded,
            app.selectedCategory == null ? 'Remove from list' : 'Remove from category',
            'Del',
          ),
        ),
        PopupMenuItem(
          onTap: () => confirmTrash(context),
          child: const _MI(Icons.delete_outline_rounded, 'Move file to trash', 'Shift+Del'),
        ),
      ],
    ],
  );
}

class _MI extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? shortcut;
  const _MI(this.icon, this.label, [this.shortcut]);
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: cs.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        if (shortcut != null) Text(shortcut!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
      ],
    );
  }
}
