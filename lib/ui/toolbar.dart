// SPDX-License-Identifier: GPL-3.0-or-later
// Panels read the global app state, so they are deliberately not const:
// const widgets would be skipped when the page rebuilds.
// ignore_for_file: prefer_const_constructors
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../models/settings.dart';
import '../native/bindings.dart';
import '../services/dsp.dart';
import 'common.dart';
import 'dialogs.dart';

class PlayerToolbar extends StatelessWidget {
  const PlayerToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(20)),
      child: ValueListenableBuilder<PlaybackStatus>(
        valueListenable: app.status,
        builder: (context, st, _) {
          final paused = st.state == 2, playing = st.state == 1;
          return Row(
            children: [
              IconButton.filled(
                tooltip: paused ? 'Resume' : 'Play (speakers and microphone)',
                icon: Icon(paused ? Icons.play_arrow_rounded : Icons.play_arrow_rounded),
                onPressed: () => app.playOrResume(mode: PlayMode.both),
              ),
              IconButton.filledTonal(
                tooltip: 'Play on speakers',
                icon: const Icon(Icons.volume_up_rounded),
                onPressed: () => app.playOrResume(mode: PlayMode.speakers),
              ),
              IconButton.filledTonal(
                tooltip: 'Play on microphone',
                icon: const Icon(Icons.mic_rounded),
                onPressed: () => app.playOrResume(mode: PlayMode.mic),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: paused ? 'Resume' : 'Pause',
                isSelected: paused,
                icon: const Icon(Icons.pause_rounded),
                selectedIcon: const Icon(Icons.play_arrow_rounded),
                onPressed: st.state == 0 ? null : app.pauseResume,
              ),
              IconButton(
                tooltip: 'Stop',
                icon: const Icon(Icons.stop_rounded),
                onPressed: st.state == 0 ? null : app.stop,
              ),
              IconButton(
                tooltip: 'Play previous file',
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: () => app.playPrevious(),
              ),
              IconButton(
                tooltip: 'Play next file',
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: () => app.playNext(),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Double-click to select the playing file',
                child: GestureDetector(
                  onDoubleTap: app.selectPlaying,
                  child: Text(
                    formatDuration(st.state == 0 ? 0 : st.position),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: playing ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              Expanded(child: _SeekBar(st)),
              Text(
                formatDuration(st.duration > 0 ? st.duration : 0),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              _VolumeControl(),
              if (app.settings.showMicLevel) ...[const SizedBox(width: 8), _MicLevel(st.micPeak)],
            ],
          );
        },
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  final PlaybackStatus st;
  const _SeekBar(this.st);
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final cs = Theme.of(context).colorScheme;
    final dur = st.duration > 0 ? st.duration : 1.0;
    final value = (_drag ?? (st.state == 0 ? 0 : st.position)).clamp(0.0, dur);
    // Red: others hear it (microphone). Blue: speakers only.
    final color = st.state == 0 ? cs.primary : (st.toMic ? const Color(0xFFE53935) : const Color(0xFF1E88E5));
    return GestureDetector(
      onSecondaryTapUp: (d) => showMenu(
        context: context,
        position: RelativeRect.fromLTRB(d.globalPosition.dx, d.globalPosition.dy, d.globalPosition.dx, 0),
        items: [PopupMenuItem(onTap: app.selectPlaying, child: const Text('Select file'))],
      ),
      child: Tooltip(
        message: st.state == 0
            ? ''
            : st.toMic
            ? 'Others can hear this sound'
            : 'Only you can hear this sound',
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(activeTrackColor: color, thumbColor: color),
          child: Slider(
            value: value.toDouble(),
            max: dur,
            onChanged: st.state == 0 ? null : (v) => setState(() => _drag = v),
            onChangeEnd: (v) {
              app.seek(v);
              setState(() => _drag = null);
            },
          ),
        ),
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl();
  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final muted = s.speakerMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: muted ? 'Unmute speakers' : 'Mute speakers',
          icon: Icon(
            muted
                ? Icons.volume_off_rounded
                : s.speakerVolume < 0.4
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
          ),
          onPressed: app.toggleSpeakerMute,
        ),
        SizedBox(
          width: 120,
          child: Tooltip(
            message: 'Speakers volume ${(s.speakerVolume * 100).round()}%',
            child: Slider(value: muted ? 0 : s.speakerVolume, onChanged: app.setSpeakerVolume),
          ),
        ),
      ],
    );
  }
}

class _MicLevel extends StatefulWidget {
  final double peak;
  const _MicLevel(this.peak);
  @override
  State<_MicLevel> createState() => _MicLevelState();
}

class _MicLevelState extends State<_MicLevel> {
  double _shown = 0;

  @override
  Widget build(BuildContext context) {
    // Peak hold with decay so the meter is readable.
    final v = peakToMeter(widget.peak);
    _shown = v > _shown ? v : (_shown - 0.04).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Microphone level – click to measure your voice volume',
          icon: const Icon(Icons.mic_none_rounded),
          onPressed: () => showVoiceMeasureDialog(context),
        ),
        LevelMeter(level: _shown, width: 64),
      ],
    );
  }
}
