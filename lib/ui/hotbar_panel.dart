// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../models/settings.dart';
import 'hotkey_dialog.dart';
import 'sound_table.dart';
import 'theme.dart';

class _CellDrag {
  final int cell;
  _CellDrag(this.cell);
}

class HotbarPanel extends StatelessWidget {
  const HotbarPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hb = app.list.hotbar;
    final page = hb.page.clamp(0, hb.pages.length - 1);
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 8, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 10),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('Hotbar', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < hb.pages.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ChoiceChip(
                            label: Text('${i + 1}'),
                            selected: i == page,
                            showCheckmark: false,
                            onSelected: (_) => app.hotbarSetPage(i),
                          ),
                        ),
                      IconButton(
                        tooltip: 'Add page',
                        icon: const Icon(Icons.add_rounded, size: 20),
                        onPressed: app.hotbarAddPage,
                      ),
                    ],
                  ),
                ),
              ),
              MenuAnchor(
                builder: (context, ctl, _) => IconButton(
                  tooltip: 'Hotbar options',
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
                ),
                menuChildren: [
                  MenuItemButton(
                    onPressed: () => showHotbarFormatDialog(context),
                    child: const Text('Set hotbar format…'),
                  ),
                  CheckboxMenuButton(
                    value: hb.sameColorsOnAllPages,
                    onChanged: (v) => app.hotbarSetSameColors(v ?? false),
                    child: const Text('Same colors on all pages'),
                  ),
                  MenuItemButton(
                    onPressed: hb.pages.length > 1 ? () => app.hotbarRemovePage(page) : null,
                    child: Text('Remove page ${page + 1}'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (var r = 0; r < hb.rows; r++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  for (var c = 0; c < hb.cols; c++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _HotbarButton(page, r * hb.cols + c),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HotbarButton extends StatelessWidget {
  final int page;
  final int cell;
  const _HotbarButton(this.page, this.cell);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hb = app.list.hotbar;
    final entry = hb.pages[page][cell];
    final sound = entry == null ? null : app.list.byId(entry.soundId);
    final hotkey = hb.cellHotkeys[cell];
    final playing = sound != null && app.currentSoundId == sound.id;
    final base = entry?.color != null ? Color(entry!.color!) : null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = base != null
        ? Color.alphaBlend(base.withValues(alpha: dark ? 0.35 : 0.45), cs.surfaceContainerHigh)
        : (sound != null ? cs.secondaryContainer : Colors.transparent);
    final fg = sound != null ? (base != null ? cs.onSurface : cs.onSecondaryContainer) : cs.onSurfaceVariant;

    final button = SizedBox(
      height: 52,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: playing
              ? BorderSide(color: cs.primary, width: 2)
              : sound == null
              ? BorderSide(color: cs.outlineVariant)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: sound == null ? null : () => app.play(sound),
          onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  sound?.tag ?? (entry != null ? 'Missing sound' : ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: fg, fontWeight: playing ? FontWeight.w600 : FontWeight.w500),
                ),
                if (hotkey != null)
                  Text(
                    hotkey.label(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: fg.withValues(alpha: 0.75)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) =>
          (d.data is SoundDragData && (d.data as SoundDragData).ids.isNotEmpty) ||
          (d.data is _CellDrag && (d.data as _CellDrag).cell != cell),
      onAcceptWithDetails: (d) {
        final data = d.data;
        if (data is SoundDragData) {
          app.hotbarAssign(page, cell, data.ids.first);
        } else if (data is _CellDrag) {
          app.hotbarMove(page, data.cell, cell, withAttributes: HardwareKeyboard.instance.isControlPressed);
        }
      },
      builder: (context, cand, _) {
        final child = cand.isNotEmpty
            ? DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: cs.primary, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: button,
              )
            : button;
        if (entry == null) return child;
        return Draggable<Object>(
          data: _CellDrag(cell),
          feedback: SizedBox(width: 140, child: Opacity(opacity: 0.85, child: button)),
          childWhenDragging: Opacity(opacity: 0.4, child: child),
          child: child,
        );
      },
    );
  }

  void _menu(BuildContext context, Offset pos) {
    final hb = app.list.hotbar;
    final entry = hb.pages[page][cell];
    final sound = entry == null ? null : app.list.byId(entry.soundId);
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, 0),
      items: [
        if (sound != null) ...[
          PopupMenuItem(onTap: () => app.play(sound), child: const Text('Play')),
          PopupMenuItem(
            onTap: () => app.play(sound, mode: PlayMode.speakers),
            child: const Text('Play on speakers'),
          ),
          PopupMenuItem(
            onTap: () => app.play(sound, mode: PlayMode.mic),
            child: const Text('Play on microphone'),
          ),
          PopupMenuItem(onTap: () => app.selectOnly(sound), child: const Text('Select in list')),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(onTap: () => showHotkeyDialogForHotbar(context, cell), child: const Text('Set hotkey…')),
        if (hb.cellHotkeys[cell] != null)
          PopupMenuItem(onTap: () => app.setHotbarHotkey(cell, null), child: const Text('Remove hotkey')),
        if (entry != null) ...[
          PopupMenuItem(onTap: () => _colorDialog(context), child: const Text('Color…')),
          const PopupMenuDivider(),
          PopupMenuItem(onTap: () => app.hotbarClear(page, cell), child: const Text('Remove from hotbar')),
        ],
      ],
    );
  }

  Future<void> _colorDialog(BuildContext context) async {
    final current = app.list.hotbar.pages[page][cell]?.color;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Button color'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in [null, ...hotbarColors])
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  app.hotbarSetColor(page, cell, c);
                  Navigator.pop(ctx);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c == null ? Theme.of(ctx).colorScheme.secondaryContainer : Color(c),
                    border: current == c ? Border.all(color: Theme.of(ctx).colorScheme.onSurface, width: 3) : null,
                  ),
                  child: c == null ? const Icon(Icons.format_color_reset_outlined, size: 18) : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showHotbarFormatDialog(BuildContext context) async {
  final hb = app.list.hotbar;
  var rows = hb.rows, cols = hb.cols;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Hotbar format'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 80, child: Text('Rows')),
                  Expanded(
                    child: Slider(
                      value: rows.toDouble(),
                      min: 1,
                      max: 6,
                      divisions: 5,
                      label: '$rows',
                      onChanged: (v) => setState(() => rows = v.round()),
                    ),
                  ),
                  Text('$rows'),
                ],
              ),
              Row(
                children: [
                  const SizedBox(width: 80, child: Text('Columns')),
                  Expanded(
                    child: Slider(
                      value: cols.toDouble(),
                      min: 1,
                      max: 12,
                      divisions: 11,
                      label: '$cols',
                      onChanged: (v) => setState(() => cols = v.round()),
                    ),
                  ),
                  Text('$cols'),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              app.hotbarResize(rows, cols);
              Navigator.pop(ctx);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );
}
