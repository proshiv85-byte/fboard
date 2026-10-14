// SPDX-License-Identifier: GPL-3.0-or-later
// Panels read the global app state, so they are deliberately not const:
// const widgets would be skipped when the page rebuilds.
// ignore_for_file: prefer_const_constructors
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../models/sound_list.dart';
import '../services/dsp.dart';
import 'common.dart';
import 'hotkey_dialog.dart';
import 'sound_table.dart';

const _iconSizes = [16.0, 20.0, 28.0, 40.0];

class CategoriesPanel extends StatelessWidget {
  const CategoriesPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = app.settings;
    final cats = app.visibleCategories;
    return Container(
      width: s.categoriesWidth,
      margin: const EdgeInsets.fromLTRB(8, 0, 0, 0),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text('Categories', style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Add category',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () => addCategoryDialog(context, parent: null),
                ),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              onSecondaryTapUp: (d) => _areaMenu(context, d.globalPosition),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemCount: cats.length + 1,
                itemBuilder: (context, i) => i == cats.length ? _EndDropZone() : _CategoryTile(cats[i]),
              ),
            ),
          ),
          if (s.showCategoryInfo) _InfoPanel(),
        ],
      ),
    );
  }

  void _areaMenu(BuildContext context, Offset pos) {
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, 0),
      items: [PopupMenuItem(onTap: () => addCategoryDialog(context, parent: null), child: const Text('Add category'))],
    );
  }
}

Future<void> addCategoryDialog(BuildContext context, {SoundCategory? parent}) async {
  final name = await promptText(
    context,
    title: parent == null ? 'New category' : 'New subcategory in ${parent.name}',
    label: 'Name',
    confirm: 'Add',
  );
  if (name != null && name.trim().isNotEmpty) {
    final c = app.addCategory(name.trim(), parent: parent);
    app.selectCategory(c);
  }
}

/// Drop zone after the last category (moves categories to the top level end).
class _EndDropZone extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DragTarget<SoundCategory>(
      onAcceptWithDetails: (d) => app.moveCategory(d.data, null, app.list.categories.length),
      builder: (context, cand, _) => Container(
        height: 40,
        decoration: cand.isNotEmpty
            ? BoxDecoration(
                border: Border(top: BorderSide(color: cs.primary, width: 2)),
              )
            : null,
      ),
    );
  }
}

class _CategoryTile extends StatefulWidget {
  final SoundCategory? cat; // null = All sounds
  const _CategoryTile(this.cat);
  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  bool _before = false; // drop position for category moves

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = widget.cat;
    final selected = app.selectedCategory == c;
    final iconSize = _iconSizes[app.settings.categoryIconSize.clamp(0, 3)];
    final count = c == null ? app.list.sounds.length : c.soundIds.length;
    final depth = c?.depth ?? 0;

    Widget icon;
    if (c?.icon != null && File(c!.icon!).existsSync()) {
      icon = ClipRRect(
        borderRadius: BorderRadius.circular(iconSize / 4),
        child: Image.file(File(c.icon!), width: iconSize, height: iconSize, fit: BoxFit.cover),
      );
    } else {
      icon = Icon(
        c == null ? Icons.library_music_rounded : Icons.folder_rounded,
        size: iconSize,
        color: selected ? cs.onSecondaryContainer : cs.primary,
      );
    }

    final tile = Container(
      height: iconSize + 20,
      margin: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(100),
        child: InkWell(
          borderRadius: BorderRadius.circular(100),
          onTap: () => app.selectCategory(c),
          onDoubleTap: c == null ? null : () => showCategoryInfoDialog(context, c),
          onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
          child: Padding(
            padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 12),
            child: Row(
              children: [
                if (c != null && c.children.isNotEmpty)
                  InkWell(
                    onTap: () => app.toggleExpanded(c),
                    child: Icon(c.expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 18),
                  )
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 4),
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    c?.name ?? 'All sounds',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : null,
                      color: selected ? cs.onSecondaryContainer : cs.onSurface,
                    ),
                  ),
                ),
                if (c?.randomHotkey != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Tooltip(
                      message: 'Random file hotkey',
                      child: Text(c!.randomHotkey!.label(), style: TextStyle(fontSize: 11, color: cs.tertiary)),
                    ),
                  ),
                Text('$count', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );

    // Accept sounds (add/move into this category) and categories (re-parent).
    final soundTarget = DragTarget<SoundDragData>(
      onWillAcceptWithDetails: (_) => c != null,
      onAcceptWithDetails: (d) {
        final copy = HardwareKeyboard.instance.isControlPressed;
        app.addToCategory(c!, d.data.ids, move: !copy);
      },
      builder: (context, cand, _) => DecoratedBox(
        decoration: cand.isNotEmpty
            ? BoxDecoration(
                border: Border.all(color: cs.primary, width: 2),
                borderRadius: BorderRadius.circular(100),
              )
            : const BoxDecoration(),
        child: tile,
      ),
    );

    if (c == null) return soundTarget;
    final catTarget = DragTarget<SoundCategory>(
      onWillAcceptWithDetails: (d) => d.data != c && !d.data.isAncestorOf(c),
      onMove: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(d.offset);
        final before = local.dy < 8;
        if (before != _before) setState(() => _before = before);
      },
      onAcceptWithDetails: (d) {
        if (_before) {
          final siblings = c.parent?.children ?? app.list.categories;
          app.moveCategory(d.data, c.parent, siblings.indexOf(c));
        } else {
          app.moveCategory(d.data, c, c.children.length);
        }
        _before = false;
      },
      builder: (context, cand, _) => Container(
        decoration: cand.isNotEmpty
            ? BoxDecoration(
                border: _before
                    ? Border(top: BorderSide(color: cs.primary, width: 2))
                    : Border.all(color: cs.tertiary, width: 2),
                borderRadius: _before ? null : BorderRadius.circular(100),
              )
            : null,
        child: soundTarget,
      ),
    );
    return Draggable<SoundCategory>(
      data: c,
      feedback: Material(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(100),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text(c.name)),
      ),
      child: catTarget,
    );
  }

  void _menu(BuildContext context, Offset pos) {
    final c = widget.cat;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, 0),
      items: [
        PopupMenuItem(onTap: () => addCategoryDialog(context, parent: null), child: const Text('Add category')),
        if (c != null) ...[
          PopupMenuItem(
            onTap: () => addCategoryDialog(context, parent: c),
            child: const Text('Add subcategory'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            onTap: () => app.playRandom(from: c),
            child: const Text('Play random file'),
          ),
          PopupMenuItem(
            onTap: () => showHotkeyDialogForCategory(context, c),
            child: const Text('Set random file hotkey…'),
          ),
          if (c.randomHotkey != null)
            PopupMenuItem(onTap: () => app.setCategoryHotkey(c, null), child: const Text('Remove hotkey')),
          const PopupMenuDivider(),
          PopupMenuItem(onTap: () => showCategoryInfoDialog(context, c), child: const Text('Edit…')),
          PopupMenuItem(
            onTap: () async {
              final name = await promptText(context, title: 'Rename category', initial: c.name, confirm: 'Rename');
              if (name != null && name.trim().isNotEmpty) app.updateCategory(c, name: name.trim());
            },
            child: const Text('Rename'),
          ),
          PopupMenuItem(
            onTap: () async {
              final img = await pickImageFile(context);
              if (img != null) app.updateCategory(c, icon: img);
            },
            child: const Text('Set icon…'),
          ),
          if (c.icon != null)
            PopupMenuItem(onTap: () => app.updateCategory(c, clearIcon: true), child: const Text('Remove icon')),
          const PopupMenuDivider(),
          PopupMenuItem(
            onTap: () async {
              if (await confirm(
                context,
                title: 'Remove category',
                message: 'Remove "${c.name}" and its subcategories? The sounds stay in "All sounds".',
                confirm: 'Remove',
                destructive: true,
              )) {
                app.removeCategory(c);
              }
            },
            child: const Text('Remove category'),
          ),
        ] else
          PopupMenuItem(onTap: () => app.playRandom(allCategories: true), child: const Text('Play random file')),
      ],
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = app.selectedCategory;
    final sounds = app.list.soundsOf(c);
    final total = sounds.fold<double>(0, (a, s) => a + s.duration);
    return GestureDetector(
      onDoubleTap: c == null ? null : () => showCategoryInfoDialog(context, c),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (c?.icon != null && File(c!.icon!).existsSync())
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(c.icon!), width: 40, height: 40, fit: BoxFit.cover),
                  )
                else
                  Icon(c == null ? Icons.library_music_rounded : Icons.folder_rounded, size: 40, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    c?.name ?? 'All sounds',
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (c != null && c.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(c.description, style: TextStyle(color: cs.onSurfaceVariant)),
            ],
            const SizedBox(height: 6),
            Text(
              '${sounds.length} sounds · ${formatDuration(total)}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            if (c?.randomHotkey != null)
              Text(
                'Random file: ${c!.randomHotkey!.label()}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showCategoryInfoDialog(BuildContext context, SoundCategory c) async {
  final name = TextEditingController(text: c.name);
  final desc = TextEditingController(text: c.description);
  String? icon = c.icon;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Category'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () async {
                      final img = await pickImageFile(ctx);
                      if (img != null) setState(() => icon = img);
                    },
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: icon != null && File(icon!).existsSync()
                          ? Image.file(File(icon!), fit: BoxFit.cover)
                          : const Icon(Icons.add_photo_alternate_outlined, size: 32),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: name,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                ],
              ),
              if (icon != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => setState(() => icon = null), child: const Text('Remove icon')),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: desc,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              app.updateCategory(
                c,
                name: name.text.trim().isEmpty ? c.name : name.text.trim(),
                description: desc.text,
                icon: icon,
                clearIcon: icon == null,
              );
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
