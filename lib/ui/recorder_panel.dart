// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../services/dsp.dart';
import '../services/recorder_service.dart';
import 'common.dart';
import 'preferences_dialog.dart';

class RecorderPanel extends StatelessWidget {
  const RecorderPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 8, 0),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
      child: ValueListenableBuilder<RecorderState>(
        valueListenable: app.recorder.state,
        builder: (context, st, _) => Row(
          children: [
            Text('Sound recorder', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 16),
            IconButton.filled(
              tooltip: st.active ? 'Stop recording' : 'Start recording',
              style: IconButton.styleFrom(
                backgroundColor: st.active ? const Color(0xFFE53935) : cs.primary,
                foregroundColor: Colors.white,
              ),
              icon: Icon(st.active ? Icons.stop_rounded : Icons.fiber_manual_record_rounded),
              onPressed: st.encoding ? null : () => st.active ? app.recorder.stop() : app.recorder.start(),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 90,
              child: Text(
                st.encoding ? 'Encoding…' : formatDuration(st.seconds, millis: true),
                style: TextStyle(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: st.active ? const Color(0xFFE53935) : null,
                ),
              ),
            ),
            if (st.encoding) const SizedBox(width: 120, child: LinearProgressIndicator()) else _Peak(st.peak),
            const SizedBox(width: 16),
            Tooltip(
              message: 'Recording volume – best left unchanged while recording',
              child: Icon(Icons.graphic_eq_rounded, size: 20, color: cs.onSurfaceVariant),
            ),
            SizedBox(
              width: 140,
              child: Slider(
                value: app.settings.recordGain.clamp(0.0, 2.0),
                max: 2,
                onChanged: (v) {
                  app.settings.recordGain = v;
                  app.native.recSetGain(v);
                  app.refresh();
                },
                onChangeEnd: (_) => app.saveSettings(),
              ),
            ),
            const Spacer(),
            Text(_sourceLabel(), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            IconButton(
              tooltip: 'Recorder preferences',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => showPreferences(context, page: PrefsPage.recorder),
            ),
            IconButton(
              tooltip: 'Close recorder',
              icon: const Icon(Icons.close_rounded),
              onPressed: () {
                app.settings.showRecorder = false;
                app.settingsChanged();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _sourceLabel() {
    final s = app.settings.recordSource;
    if (s == null) return 'Recording what you hear · ${app.settings.recordFormat.toUpperCase()}';
    final d = app.sources.where((x) => x.name == s).firstOrNull;
    return 'Recording ${d?.desc ?? s} · ${app.settings.recordFormat.toUpperCase()}';
  }
}

class _Peak extends StatefulWidget {
  final double peak;
  const _Peak(this.peak);
  @override
  State<_Peak> createState() => _PeakState();
}

class _PeakState extends State<_Peak> {
  double _v = 0;
  @override
  Widget build(BuildContext context) {
    final v = peakToMeter(widget.peak);
    _v = v > _v ? v : (_v - 0.03).clamp(0.0, 1.0);
    return LevelMeter(level: _v, width: 120, height: 8);
  }
}
