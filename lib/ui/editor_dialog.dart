// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../models/sound_list.dart';
import '../native/bindings.dart';
import '../services/dsp.dart';
import '../services/media_jobs.dart';
import 'common.dart';

Future<void> showEditorDialog(BuildContext context, Sound s) async {
  if (!File(s.path).existsSync()) {
    app.notify('File not found: ${s.path}', NoticeLevel.warning);
    return;
  }
  if (s.duration > 600 &&
      !await confirm(
        context,
        title: 'Long file',
        message:
            'This file is longer than 10 minutes. Editing it needs a lot of memory '
            '(about ${(s.duration * sampleRate * 8 / 1e6).round()} MB). A dedicated audio editor may be better. Continue?',
        confirm: 'Edit anyway',
      )) {
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _Editor(s)));
}

class _Editor extends StatefulWidget {
  final Sound sound;
  const _Editor(this.sound);
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  Float32List? _data;
  int _ch = 2;
  MediaInfo? _info;
  double? _origLufs;
  final List<Float32List> _undo = [];
  final List<Float32List> _redo = [];
  int _selA = 0, _selB = 0; // frames; equal = cursor only
  double _framesPerPx = 0; // 0 = fit
  double _scroll = 0; // first visible frame
  bool _more = false;
  bool _saving = false;
  int _previewOffset = 0;
  _PeakCache? _peaks;
  final _focus = FocusNode();

  int get _frames => _data == null ? 0 : _data!.length ~/ _ch;
  int get _selStart => math.min(_selA, _selB);
  int get _selEnd => math.max(_selA, _selB);
  bool get _hasSel => _selEnd > _selStart;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (app.previewing != null) {
      app.native.stop();
      app.previewing = null;
    }
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final info = await probeFile(widget.sound.path);
    final d = await decodeFile(widget.sound.path);
    if (!mounted) return;
    if (d == null) {
      app.notify('Could not decode ${widget.sound.fileName}', NoticeLevel.error);
      Navigator.pop(context);
      return;
    }
    final l = await loudnessOf(d.samples, d.channels);
    setState(() {
      _info = info;
      _data = d.samples;
      _ch = d.channels;
      _origLufs = l;
      _peaks = _PeakCache(_data!, _ch);
    });
  }

  void _apply(Float32List next, {int? selA, int? selB}) {
    _undo.add(_data!);
    if (_undo.length > 30) _undo.removeAt(0);
    _redo.clear();
    setState(() {
      _data = next;
      _peaks = _PeakCache(next, _ch);
      _selA = (selA ?? _selA).clamp(0, _frames);
      _selB = (selB ?? _selA).clamp(0, _frames);
      _scroll = _scroll.clamp(0, _frames.toDouble());
    });
  }

  void _undoAct() {
    if (_undo.isEmpty) return;
    _redo.add(_data!);
    setState(() {
      _data = _undo.removeLast();
      _peaks = _PeakCache(_data!, _ch);
      _selA = _selB = _selA.clamp(0, _frames);
    });
  }

  void _redoAct() {
    if (_redo.isEmpty) return;
    _undo.add(_data!);
    setState(() {
      _data = _redo.removeLast();
      _peaks = _PeakCache(_data!, _ch);
      _selA = _selB = _selA.clamp(0, _frames);
    });
  }

  // ------------------------------------------------------------ edits
  void _cut() {
    if (!_hasSel) return;
    final d = _data!;
    final out = Float32List(d.length - (_selEnd - _selStart) * _ch)
      ..setRange(0, _selStart * _ch, d)
      ..setRange(_selStart * _ch, d.length - (_selEnd - _selStart) * _ch, d, _selEnd * _ch);
    _apply(out, selA: _selStart, selB: _selStart);
  }

  void _crop() {
    if (!_hasSel) return;
    _apply(Float32List.fromList(_data!.sublist(_selStart * _ch, _selEnd * _ch)), selA: 0, selB: 0);
  }

  (int, int) get _range => _hasSel ? (_selStart, _selEnd) : (0, _frames);

  void _fade(bool fadeIn) {
    final (a, b) = _range;
    _apply(
      fade(_data!, _ch, a, b, fadeIn: fadeIn),
      selA: _selA,
      selB: _selB,
    );
  }

  void _silence() {
    if (!_hasSel) return;
    final out = Float32List.fromList(_data!);
    out.fillRange(_selStart * _ch, _selEnd * _ch, 0);
    _apply(out, selA: _selA, selB: _selB);
  }

  void _gainDb(double db) {
    final (a, b) = _range;
    final g = math.pow(10, db / 20).toDouble();
    final out = Float32List.fromList(_data!);
    for (var i = a * _ch; i < b * _ch; i++) {
      out[i] = (out[i] * g).clamp(-1.0, 1.0);
    }
    _apply(out, selA: _selA, selB: _selB);
  }

  Future<void> _normalize() async {
    final target = app.settings.recordNormalizeTarget;
    final l = await loudnessOf(_data!, _ch);
    final g = normalizationGain(l, target, peakOf(_data!));
    _apply(applyGain(_data!, g), selA: _selA, selB: _selB);
    app.showStatus(
      'Normalized to ${target.toStringAsFixed(0)} LUFS (${(20 * math.log(g) / math.ln10).toStringAsFixed(1)} dB)',
    );
  }

  Future<void> _volumeDialog() async {
    var db = 0.0;
    final r = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(_hasSel ? 'Change volume of selection' : 'Change volume'),
          content: SizedBox(
            width: 360,
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    value: db,
                    min: -24,
                    max: 24,
                    onChanged: (v) => setState(() => db = (v * 2).roundToDouble() / 2),
                  ),
                ),
                SizedBox(width: 64, child: Text('${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, db), child: const Text('Apply')),
          ],
        ),
      ),
    );
    if (r != null && r != 0) _gainDb(r);
  }

  // ------------------------------------------------------------ playback
  void _play({bool selectionOnly = false}) {
    final (a, b) = selectionOnly ? _range : (0, _frames);
    _previewOffset = a;
    app.playPreview(DecodedPreview(Float32List.sublistView(_data!, a * _ch, b * _ch), _ch));
  }

  void _stop() {
    app.native.stop();
    app.previewing = null;
  }

  // ------------------------------------------------------------ save
  static const _encodable = {'wav', 'mp3', 'm4a', 'ogg', 'opus', 'flac'};

  Future<void> _save({bool asNew = false}) async {
    final s = widget.sound;
    final ext = p.extension(s.path).replaceFirst('.', '').toLowerCase();
    final fmt = !asNew && _encodable.contains(ext) ? ext : app.settings.recordFormat;
    var target = p.setExtension(s.path, '.$fmt');
    if (asNew || target != s.path) {
      var i = 1;
      final base = p.withoutExtension(s.path);
      target = '$base (edited).$fmt';
      while (File(target).existsSync()) {
        target = '$base (edited $i).$fmt';
        i++;
      }
    } else if (!await confirm(
      context,
      title: 'Overwrite file',
      message: 'Overwrite ${s.fileName} with the edited sound? This cannot be undone.',
      confirm: 'Overwrite',
    )) {
      return;
    }
    setState(() => _saving = true);
    _stop();
    final tmp = '$target.part.$fmt';
    final ok = await encodeFile(tmp, fmt, _data!, _ch);
    if (ok) await File(tmp).rename(target);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      app.notify('Could not save as ${fmt.toUpperCase()}.', NoticeLevel.error);
      return;
    }
    final info = await probeFile(target);
    if (target != s.path) {
      app.edit(() => s.path = target, hotkeyTable: false);
    }
    app.updateSoundInfo(s, duration: info?.duration, size: info?.size, format: info?.format, lufs: null);
    _undo.clear();
    _redo.clear();
    app.notify('Saved ${p.basename(target)}');
    if (mounted) Navigator.pop(context);
  }

  // ------------------------------------------------------------ keyboard
  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    final step = math.max(1, (_framesPerPx <= 0 ? _fitFpp : _framesPerPx) * 4).round();
    void move(int to) {
      setState(() {
        if (k.isShiftPressed) {
          _selB = to.clamp(0, _frames);
        } else {
          _selA = _selB = to.clamp(0, _frames);
        }
      });
    }

    switch (e.logicalKey) {
      case LogicalKeyboardKey.escape:
        Navigator.pop(context);
      case LogicalKeyboardKey.delete:
        _cut();
      case LogicalKeyboardKey.arrowLeft:
        move(_selB - step);
      case LogicalKeyboardKey.arrowRight:
        move(_selB + step);
      case LogicalKeyboardKey.home:
        move(0);
      case LogicalKeyboardKey.end:
        move(_frames);
      case LogicalKeyboardKey.space:
        app.status.value.state == 0 ? _play(selectionOnly: true) : _stop();
      default:
        if (k.isControlPressed) {
          switch (e.logicalKey) {
            case LogicalKeyboardKey.keyA:
              setState(() {
                _selA = 0;
                _selB = _frames;
              });
            case LogicalKeyboardKey.keyD:
              setState(() => _selB = _selA);
            case LogicalKeyboardKey.keyZ:
              k.isShiftPressed ? _redoAct() : _undoAct();
            case LogicalKeyboardKey.keyY:
              _redoAct();
            case LogicalKeyboardKey.keyS:
              _save();
            default:
              return KeyEventResult.ignored;
          }
        } else {
          return KeyEventResult.ignored;
        }
    }
    return KeyEventResult.handled;
  }

  double _fitFpp = 1;
  double _width = 1;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.sound;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Edit – ${s.tag}'),
          actions: [
            if (_saving)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            TextButton(
              onPressed: _data == null || _saving ? null : () => _save(asNew: true),
              child: const Text('Save as new file'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _data == null || _saving || _undo.isEmpty ? null : _save,
              child: const Text('Save'),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: _data == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _toolbar(cs),
                  if (_more) _moreBar(),
                  Expanded(
                    child: Padding(padding: const EdgeInsets.all(16), child: _waveform(cs)),
                  ),
                  _zoomBar(),
                  _attributes(cs),
                ],
              ),
      ),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    Widget b(IconData i, String tip, VoidCallback? fn) => IconButton(tooltip: tip, icon: Icon(i), onPressed: fn);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          IconButton.filled(
            tooltip: 'Play from the beginning',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: _play,
          ),
          b(Icons.play_circle_outline_rounded, 'Play selection on speakers (Space)', () => _play(selectionOnly: true)),
          b(Icons.stop_rounded, 'Stop', _stop),
          const VerticalDivider(),
          b(Icons.content_cut_rounded, 'Cut selection (Del)', _hasSel ? _cut : null),
          b(Icons.crop_rounded, 'Crop to selection', _hasSel ? _crop : null),
          const VerticalDivider(),
          b(Icons.undo_rounded, 'Undo (Ctrl+Z)', _undo.isEmpty ? null : _undoAct),
          b(Icons.redo_rounded, 'Redo (Ctrl+Y)', _redo.isEmpty ? null : _redoAct),
          const VerticalDivider(),
          b(Icons.zoom_in_rounded, 'Zoom in', () => _zoom(0.5)),
          b(Icons.zoom_out_rounded, 'Zoom out', () => _zoom(2)),
          const Spacer(),
          FilterChip(label: const Text('More options'), selected: _more, onSelected: (v) => setState(() => _more = v)),
        ],
      ),
    );
  }

  Widget _moreBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.trending_up_rounded),
            label: const Text('Fade in'),
            onPressed: () => _fade(true),
          ),
          ActionChip(
            avatar: const Icon(Icons.trending_down_rounded),
            label: const Text('Fade out'),
            onPressed: () => _fade(false),
          ),
          ActionChip(avatar: const Icon(Icons.tune_rounded), label: const Text('Volume…'), onPressed: _volumeDialog),
          ActionChip(
            avatar: const Icon(Icons.equalizer_rounded),
            label: const Text('Normalize'),
            onPressed: _normalize,
          ),
          ActionChip(
            avatar: const Icon(Icons.volume_mute_rounded),
            label: const Text('Silence selection'),
            onPressed: _hasSel ? _silence : null,
          ),
          ActionChip(
            avatar: const Icon(Icons.content_cut_rounded),
            label: const Text('Trim silence'),
            onPressed: () => _apply(Float32List.fromList(trimSilence(_data!, _ch)), selA: 0, selB: 0),
          ),
        ],
      ),
    );
  }

  void _zoom(double f) {
    setState(() {
      final cur = _framesPerPx <= 0 ? _fitFpp : _framesPerPx;
      final center = _hasSel ? (_selStart + _selEnd) / 2 : _selA.toDouble();
      _framesPerPx = (cur * f).clamp(1.0, _fitFpp);
      if (_framesPerPx >= _fitFpp) _framesPerPx = 0;
      final fpp = _framesPerPx <= 0 ? _fitFpp : _framesPerPx;
      _scroll = (center - fpp * _width / 2).clamp(0, math.max(0, _frames - fpp * _width)).toDouble();
    });
  }

  Widget _zoomBar() {
    if (_framesPerPx <= 0) return const SizedBox(height: 8);
    final visible = _framesPerPx * _width;
    if (visible >= _frames) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Slider(
        value: _scroll.clamp(0, (_frames - visible).toDouble()),
        max: math.max(1, _frames - visible),
        onChanged: (v) => setState(() => _scroll = v),
      ),
    );
  }

  int _frameAt(double x) {
    final fpp = _framesPerPx <= 0 ? _fitFpp : _framesPerPx;
    return (_scroll + x * fpp).round().clamp(0, _frames);
  }

  Widget _waveform(ColorScheme cs) {
    return LayoutBuilder(
      builder: (context, bc) {
        _width = bc.maxWidth;
        _fitFpp = math.max(1, _frames / bc.maxWidth);
        if (_framesPerPx > 0 && _framesPerPx > _fitFpp) _framesPerPx = 0;
        final fpp = _framesPerPx <= 0 ? _fitFpp : _framesPerPx;
        if (_framesPerPx <= 0) _scroll = 0;
        return Container(
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                if (HardwareKeyboard.instance.isControlPressed) {
                  _zoom(e.scrollDelta.dy > 0 ? 1.25 : 0.8);
                } else {
                  setState(
                    () => _scroll = (_scroll + e.scrollDelta.dy * fpp)
                        .clamp(0, math.max(0, _frames - fpp * _width))
                        .toDouble(),
                  );
                }
              }
            },
            child: GestureDetector(
              onTapDown: (d) {
                _focus.requestFocus();
                final f = _frameAt(d.localPosition.dx);
                setState(() {
                  if (HardwareKeyboard.instance.isShiftPressed) {
                    _selB = f;
                  } else {
                    _selA = _selB = f;
                  }
                });
              },
              onHorizontalDragStart: (d) => setState(() => _selA = _selB = _frameAt(d.localPosition.dx)),
              onHorizontalDragUpdate: (d) => setState(() => _selB = _frameAt(d.localPosition.dx)),
              child: ValueListenableBuilder(
                valueListenable: app.status,
                builder: (context, st, _) {
                  final playPos = app.previewing != null && st.state != 0
                      ? _previewOffset + (st.position * sampleRate).round()
                      : null;
                  return CustomPaint(
                    size: Size.infinite,
                    painter: _WavePainter(
                      peaks: _peaks!,
                      scroll: _scroll,
                      fpp: fpp,
                      selStart: _selStart,
                      selEnd: _selEnd,
                      play: playPos,
                      wave: cs.primary,
                      sel: cs.primaryContainer,
                      cursor: cs.tertiary,
                      grid: cs.outlineVariant,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _attributes(ColorScheme cs) {
    final i = _info;
    String ch(int n) => n == 1 ? 'Mono' : (n == 2 ? 'Stereo' : '$n channels');
    final items = <(String, String)>[
      ('Size', formatSize(i?.size ?? 0)),
      ('Format', i?.format ?? ''),
      ('Sample rate', '${i?.sampleRate ?? 0} Hz'),
      ('Duration', formatDuration(i?.duration ?? 0, millis: true)),
      ('Channels', ch(i?.channels ?? _ch)),
      ('Volume', _origLufs != null && _origLufs!.isFinite ? '${_origLufs!.toStringAsFixed(1)} LUFS' : '–'),
      (
        'Selection',
        _hasSel
            ? '${formatDuration(_selStart / sampleRate, millis: true)} – ${formatDuration(_selEnd / sampleRate, millis: true)}'
            : formatDuration(_selA / sampleRate, millis: true),
      ),
      ('Edited length', formatDuration(_frames / sampleRate, millis: true)),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: Wrap(
        spacing: 32,
        runSpacing: 8,
        children: [
          for (final (k, v) in items)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(k, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                Text(v, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
        ],
      ),
    );
  }
}

/// Min/max of the first channel per block of 256 frames, for fast drawing
/// when zoomed out.
class _PeakCache {
  static const block = 256;
  final Float32List data;
  final int ch;
  late final Float32List mins;
  late final Float32List maxs;

  _PeakCache(this.data, this.ch) {
    final frames = data.length ~/ ch;
    final n = (frames + block - 1) ~/ block;
    mins = Float32List(n);
    maxs = Float32List(n);
    for (var b = 0; b < n; b++) {
      var lo = 0.0, hi = 0.0;
      final end = math.min(frames, (b + 1) * block);
      for (var f = b * block; f < end; f++) {
        final v = data[f * ch];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      mins[b] = lo;
      maxs[b] = hi;
    }
  }

  (double, double) range(int a, int b) {
    final frames = data.length ~/ ch;
    a = a.clamp(0, frames);
    b = b.clamp(0, frames);
    var lo = 0.0, hi = 0.0;
    if (b - a >= block * 2) {
      for (var i = a ~/ block; i < b ~/ block; i++) {
        if (mins[i] < lo) lo = mins[i];
        if (maxs[i] > hi) hi = maxs[i];
      }
    } else {
      for (var f = a; f < b; f++) {
        final v = data[f * ch];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    return (lo, hi);
  }
}

class _WavePainter extends CustomPainter {
  final _PeakCache peaks;
  final double scroll, fpp;
  final int selStart, selEnd;
  final int? play;
  final Color wave, sel, cursor, grid;

  _WavePainter({
    required this.peaks,
    required this.scroll,
    required this.fpp,
    required this.selStart,
    required this.selEnd,
    required this.play,
    required this.wave,
    required this.sel,
    required this.cursor,
    required this.grid,
  });

  double _x(int frame) => (frame - scroll) / fpp;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final h = size.height / 2 - 8;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = grid);
    if (selEnd > selStart) {
      canvas.drawRect(Rect.fromLTRB(_x(selStart), 0, _x(selEnd), size.height), Paint()..color = sel);
    }
    final p = Paint()
      ..color = wave
      ..strokeWidth = 1;
    for (var x = 0; x < size.width; x++) {
      final a = (scroll + x * fpp).floor();
      final b = math.max(a + 1, (scroll + (x + 1) * fpp).floor());
      final (lo, hi) = peaks.range(a, b);
      canvas.drawLine(Offset(x + 0.5, mid - hi * h), Offset(x + 0.5, mid - lo * h + 0.5), p);
    }
    final cp = Paint()
      ..color = cursor
      ..strokeWidth = 2;
    final cx = _x(selEnd == selStart ? selStart : selEnd);
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), cp);
    if (play != null) {
      final px = _x(play!);
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = wave
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) =>
      o.peaks != peaks ||
      o.scroll != scroll ||
      o.fpp != fpp ||
      o.selStart != selStart ||
      o.selEnd != selEnd ||
      o.play != play;
}
