// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/sound_list.dart';
import '../services/media_jobs.dart';

// ------------------------------------------------------------ file dialogs
Future<List<String>> pickAudioFiles(BuildContext context) async {
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Add sound files',
    type: FileType.custom,
    allowedExtensions: audioExtensions.toList(),
  );
  return files.map((f) => f.path).whereType<String>().toList();
}

Future<String?> pickAudioFile(BuildContext context, {String title = 'Choose a sound file'}) async {
  final f = await FilePicker.pickFile(
    dialogTitle: title,
    type: FileType.custom,
    allowedExtensions: audioExtensions.toList(),
  );
  return f?.path;
}

Future<String?> pickImageFile(BuildContext context) async {
  final f = await FilePicker.pickFile(dialogTitle: 'Choose an icon', type: FileType.image);
  return f?.path;
}

Future<String?> pickListFile(BuildContext context) async {
  final f = await FilePicker.pickFile(
    dialogTitle: 'Load sound list',
    type: FileType.custom,
    allowedExtensions: [SoundList.fileExtension],
  );
  return f?.path;
}

Future<String?> pickJsonFile(BuildContext context, String title) async {
  final f = await FilePicker.pickFile(dialogTitle: title, type: FileType.custom, allowedExtensions: ['json']);
  return f?.path;
}

Future<String?> pickDirectory(BuildContext context, String title) => FilePicker.getDirectoryPath(dialogTitle: title);

/// Shows a save dialog and returns the chosen path. The file is created with
/// [content] by the picker; callers may overwrite it.
Future<String?> pickSavePath(
  BuildContext context, {
  required String title,
  required String fileName,
  required List<String> extensions,
  String content = '',
}) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: title,
    fileName: fileName,
    bytes: Uint8List.fromList(utf8.encode(content)),
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (uri == null) return null;
  return uri.scheme == 'file' ? uri.toFilePath() : uri.path;
}

// ------------------------------------------------------------ dialogs
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '',
  String confirm = 'OK',
  int maxLines = 1,
}) {
  final ctl = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: maxLines,
          decoration: InputDecoration(labelText: label.isEmpty ? null : label),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: Text(confirm)),
      ],
    ),
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'OK',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Small labeled section header used in panels and preferences.
class SectionHeader extends StatelessWidget {
  final String text;
  const SectionHeader(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Level meter (0..1) drawn as a rounded bar.
class LevelMeter extends StatelessWidget {
  final double level;
  final double width;
  final double height;
  const LevelMeter({super.key, required this.level, this.width = 80, this.height = 6});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = level.clamp(0.0, 1.0);
    final color = v > 0.95 ? cs.error : (v > 0.7 ? cs.tertiary : cs.primary);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(height)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: v,
        child: Container(
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height)),
        ),
      ),
    );
  }
}

/// Converts a linear peak to a meter position (dB scale, -60..0 dB).
double peakToMeter(double peak) {
  if (peak <= 0.001) return 0;
  final db = 20 * math.log(peak) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}
