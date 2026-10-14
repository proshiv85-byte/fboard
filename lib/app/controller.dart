// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/hotkey.dart';
import '../models/settings.dart';
import '../models/sound_list.dart';
import '../native/bindings.dart';
import '../services/auto_keys.dart';
import '../services/file_ops.dart';
import '../services/hotkey_service.dart';
import '../services/media_jobs.dart';
import '../services/recorder_service.dart';
import 'paths.dart';

late AppController app;

enum NoticeLevel { info, warning, error }

class Notice {
  final String text;
  final NoticeLevel level;
  final DateTime time = DateTime.now();
  bool confirmed = false;
  Notice(this.text, this.level);
}

class AudioDevice {
  final String name;
  final String desc;
  final bool monitor;
  AudioDevice(this.name, this.desc, {this.monitor = false});
}

class AppController extends ChangeNotifier {
  final Native native = Native.I;
  Settings settings = Settings();
  SoundList list = SoundList();

  // ------------------------------------------------------------ list state
  String? get listPath => settings.listPath;
  bool dirty = false; // working copy differs from the loaded list file
  bool _workingChanged = false; // working copy not yet written to disk
  SoundCategory? selectedCategory; // null = All sounds
  final Set<String> selection = {};
  String? focusId;
  String? _anchorId;
  final List<String> _undo = [];
  final List<String> _redo = [];
  List<String> _clipboard = [];
  bool _clipboardCut = false;

  // ------------------------------------------------------------ search
  String searchQuery = '';
  bool searchOpen = false;
  List<String> searchHits = [];
  int searchHitIndex = -1;

  // ------------------------------------------------------------ playback
  final status = ValueNotifier<PlaybackStatus>(PlaybackStatus.stopped);
  String? currentSoundId; // playing or paused
  String? lastPlayedId;
  int _playId = 0;
  bool _playedByHotkey = false;
  PlayMode _activeMode = PlayMode.both;
  List<String> _playContext = []; // ids of the list the sound was played from
  bool _firstSoundPlayed = false;
  Timer? _statusTimer;
  DecodedPreview? previewing;

  // ------------------------------------------------------------ audio state
  bool audioConnected = false;
  String? audioError;
  List<AudioDevice> sources = [];
  List<AudioDevice> sinks = [];
  String defaultSource = '';
  String defaultSink = '';

  // ------------------------------------------------------------ services
  late final HotkeyService hotkeys = HotkeyService(this);
  late final AutoKeysService autoKeys = AutoKeysService(this);
  late final RecorderService recorder = RecorderService(this);

  // ------------------------------------------------------------ notices
  final List<Notice> notices = [];
  final statusMessage = ValueNotifier<String>('');
  Timer? _statusMessageTimer;

  Timer? _autosave;
  Timer? _devicesDebounce;
  bool _analyzing = false;

  // ================================================================ init
  Future<void> init() async {
    _loadSettings();
    _loadWorkingCopy();
    _dailyBackup();
    native.setEventListener(_onNativeEvent);
    _connectAudio();
    hotkeys.start();
    _autosave = Timer.periodic(const Duration(minutes: 5), (_) => saveWorkingCopy());
    _statusTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => _pollStatus());
    _analyzeMissing();
  }

  Future<void> shutdown() async {
    _autosave?.cancel();
    _statusTimer?.cancel();
    saveWorkingCopy();
    saveSettings();
    autoKeys.releaseAll();
    hotkeys.stop();
    recorder.cancel();
    native.stop();
    native.audioShutdown();
    native.uinputClose();
  }

  void _connectAudio() {
    final r = native.audioInit();
    audioConnected = r == 0;
    if (!audioConnected) {
      audioError = 'Could not connect to the sound server (PulseAudio/PipeWire).';
      notify(audioError!, NoticeLevel.error);
      return;
    }
    refreshDevices();
    applyAudioSettings(rebuildVmic: true);
  }

  void refreshDevices() {
    final d = native.listDevices();
    if (d == null) return;
    sources = [
      for (final s in (d['sources'] as List))
        AudioDevice(s['name'] as String, s['desc'] as String, monitor: s['monitor'] as bool),
    ];
    sinks = [for (final s in (d['sinks'] as List)) AudioDevice(s['name'] as String, s['desc'] as String)];
    defaultSource = d['default_source'] as String? ?? '';
    defaultSink = d['default_sink'] as String? ?? '';
    notifyListeners();
  }

  /// Pushes audio settings to the engine. Rebuilding the virtual microphone
  /// is only needed when the input device changes.
  void applyAudioSettings({bool rebuildVmic = false}) {
    if (!audioConnected) return;
    final s = settings;
    native.setOutputSink(s.outputSink);
    native.setSpeakerVolume(s.speakerMuted ? 0 : s.speakerVolume);
    native.setMicVolume(s.micVolume);
    native.setNormalization(s.normalize, s.normalizeTarget, s.dynamicNormalization);
    native.setActivationSound(s.activationSound, s.activationSoundPath);
    native.setBlockVoice(s.blockVoice);
    if (rebuildVmic) {
      _recoverDefaultSource();
      final r = native.vmicSetup(s.micSource, s.setDefaultMic);
      if (r != 0) {
        audioError = 'Could not create the fboard virtual microphone (error $r).';
        notify(audioError!, NoticeLevel.error);
      } else {
        audioError = null;
        // Remember the real default microphone so it can be restored even if
        // fboard is killed.
        final file = File(p.join(Paths.data, 'default-source'));
        if (s.setDefaultMic && defaultSource.isNotEmpty && defaultSource != 'fboard_mic') {
          file.writeAsStringSync(defaultSource);
        }
      }
    }
    native.setHearMyself(s.hearMyself);
  }

  /// After a crash the system default input may still point to the (now
  /// removed) fboard microphone; put the real one back.
  void _recoverDefaultSource() {
    final file = File(p.join(Paths.data, 'default-source'));
    if (!file.existsSync()) return;
    final saved = file.readAsStringSync().trim();
    refreshDevices();
    final current = defaultSource;
    final exists = sources.any((d) => d.name == current);
    if (saved.isNotEmpty && (current == 'fboard_mic' || !exists) && sources.any((d) => d.name == saved)) {
      native.setDefaultSource(saved);
      refreshDevices();
    }
  }

  void _onNativeEvent(int type, int a, int b, int c) {
    switch (type) {
      case evPlaybackFinished:
        _onPlaybackFinished(a, b == 1);
      case evPlaybackError:
        if (a == _playId) {
          final s = currentSoundId != null ? list.byId(currentSoundId!) : null;
          notify('Could not play ${s?.fileName ?? 'file'}', NoticeLevel.warning);
        }
      case evKey:
        hotkeys.onKey(a, b, c);
      case evDevicesChanged:
        _devicesDebounce?.cancel();
        _devicesDebounce = Timer(const Duration(milliseconds: 300), refreshDevices);
      case evRecorderLimit:
        recorder.onLimitReached();
      case evAudioState:
        if (a == 0 && audioConnected) {
          audioConnected = false;
          notify('Lost connection to the sound server.', NoticeLevel.error);
          notifyListeners();
        }
    }
  }

  void refresh() => notifyListeners();

  // ================================================================ notices
  void notify(String text, [NoticeLevel level = NoticeLevel.info]) {
    if (level != NoticeLevel.info) {
      notices.insert(0, Notice(text, level));
      if (notices.length > 100) notices.removeLast();
    }
    showStatus(text);
    notifyListeners();
  }

  void showStatus(String text) {
    statusMessage.value = text;
    _statusMessageTimer?.cancel();
    _statusMessageTimer = Timer(const Duration(seconds: 8), () => statusMessage.value = '');
  }

  int get unconfirmedNotices => notices.where((n) => !n.confirmed).length;

  void confirmNotices() {
    for (final n in notices) {
      n.confirmed = true;
    }
    notifyListeners();
  }

  // ================================================================ settings
  void _loadSettings() {
    try {
      final f = File(Paths.settingsFile);
      if (f.existsSync()) settings = Settings.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (e) {
      notify('Preferences could not be read and were reset: $e', NoticeLevel.warning);
    }
  }

  void saveSettings() {
    try {
      final f = File(Paths.settingsFile);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settings.toJson()));
      tmp.renameSync(f.path);
    } catch (e) {
      notify('Could not save preferences: $e', NoticeLevel.error);
    }
  }

  /// Call after changing settings from the UI.
  void settingsChanged({bool audio = false, bool vmic = false, bool hotkeyTable = false, bool backend = false}) {
    saveSettings();
    if (audio || vmic) applyAudioSettings(rebuildVmic: vmic);
    if (backend) {
      hotkeys.restart();
    } else if (hotkeyTable) {
      hotkeys.rebuild();
    }
    notifyListeners();
  }

  void exportPreferences(String path) {
    File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settings.toJson()));
    notify('Preferences exported to $path');
  }

  void importPreferences(String path) {
    try {
      final listPath = settings.listPath, recent = settings.recentLists;
      settings = Settings.fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);
      settings.listPath = listPath;
      settings.recentLists = recent;
      settingsChanged(vmic: true, backend: true);
      notify('Preferences imported from $path');
    } catch (e) {
      notify('Could not import preferences: $e', NoticeLevel.error);
    }
  }

  // ================================================================ list persistence
  void _loadWorkingCopy() {
    final f = File(Paths.workingCopy);
    if (f.existsSync()) {
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        list = SoundList.fromJson(j);
        dirty = j['_dirty'] as bool? ?? false;
      } catch (e) {
        notify(
          'The working copy of the sound list was damaged. Restore a backup via File > Restore sound list.',
          NoticeLevel.error,
        );
      }
    } else if (settings.listPath != null && File(settings.listPath!).existsSync()) {
      _readListFile(settings.listPath!);
    }
  }

  void saveWorkingCopy() {
    if (!_workingChanged && File(Paths.workingCopy).existsSync()) return;
    try {
      final j = list.toJson()..['_dirty'] = dirty;
      final tmp = File('${Paths.workingCopy}.tmp');
      tmp.writeAsStringSync(jsonEncode(j));
      tmp.renameSync(Paths.workingCopy);
      _workingChanged = false;
    } catch (e) {
      notify('Could not save the working copy: $e', NoticeLevel.error);
    }
  }

  void _dailyBackup() {
    final d = DateTime.now();
    final name = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.fbl';
    final f = File(p.join(Paths.backups, name));
    if (!f.existsSync() && list.sounds.isNotEmpty) {
      f.writeAsStringSync(jsonEncode(list.toJson()));
    }
    final all = backups();
    for (final old in all.skip(30)) {
      try {
        old.deleteSync();
      } catch (_) {}
    }
  }

  List<File> backups() {
    final d = Directory(Paths.backups);
    final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.fbl')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  void restoreBackup(File f) {
    _pushUndo();
    try {
      list = SoundList.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
      _afterListReplaced();
      _changed();
      notify('Restored backup ${p.basenameWithoutExtension(f.path)}');
    } catch (e) {
      notify('Could not restore backup: $e', NoticeLevel.error);
    }
  }

  bool _readListFile(String path) {
    try {
      final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final l = SoundList.fromJson(j);
      // Resolve paths relative to the list file (exported lists).
      final dir = p.dirname(path);
      for (final s in l.sounds) {
        if (!p.isAbsolute(s.path)) s.path = p.normalize(p.join(dir, s.path));
      }
      list = l;
      return true;
    } catch (e) {
      notify('Could not load ${p.basename(path)}: $e', NoticeLevel.error);
      return false;
    }
  }

  void _afterListReplaced() {
    selectedCategory = null;
    selection.clear();
    focusId = null;
    searchHits = [];
    hotkeys.rebuild();
    _analyzeMissing();
  }

  void newList() {
    _pushUndo();
    list = SoundList();
    settings.listPath = null;
    dirty = false;
    _afterListReplaced();
    _workingChanged = true;
    saveWorkingCopy();
    saveSettings();
    notifyListeners();
  }

  bool loadList(String path) {
    if (!_readListFile(path)) return false;
    settings.listPath = path;
    _addRecent(path);
    dirty = false;
    _workingChanged = true;
    _afterListReplaced();
    saveWorkingCopy();
    saveSettings();
    notify('Loaded ${list.sounds.length} sounds from ${p.basename(path)}');
    return true;
  }

  bool saveList([String? path]) {
    path ??= settings.listPath;
    if (path == null) return false;
    if (!path.endsWith('.${SoundList.fileExtension}')) path = '$path.${SoundList.fileExtension}';
    try {
      File(path).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(list.toJson()));
      settings.listPath = path;
      _addRecent(path);
      dirty = false;
      _workingChanged = true;
      saveWorkingCopy();
      saveSettings();
      showStatus('Saved ${p.basename(path)}');
      notifyListeners();
      return true;
    } catch (e) {
      notify('Could not save the sound list: $e', NoticeLevel.error);
      return false;
    }
  }

  void _addRecent(String path) {
    settings.recentLists.remove(path);
    settings.recentLists.insert(0, path);
    if (settings.recentLists.length > 10) settings.recentLists.removeLast();
  }

  /// Copies all sound files plus a list file into [dir].
  Future<void> exportSoundFiles(String dir) async {
    final used = <String>{};
    final exported = SoundList.fromJson(jsonDecode(jsonEncode(list.toJson())) as Map<String, dynamic>);
    var copied = 0;
    for (final s in exported.sounds) {
      var name = p.basename(s.path);
      var i = 1;
      while (used.contains(name)) {
        name = '${p.basenameWithoutExtension(s.path)} ($i)${p.extension(s.path)}';
        i++;
      }
      used.add(name);
      try {
        await File(s.path).copy(p.join(dir, name));
        s.path = name;
        copied++;
      } catch (_) {}
    }
    final listName = settings.listPath != null ? p.basename(settings.listPath!) : 'soundlist.fbl';
    await File(p.join(dir, listName)).writeAsString(const JsonEncoder.withIndent(' ').convert(exported.toJson()));
    notify('Exported $copied sound files and $listName to $dir');
  }

  // ================================================================ undo
  String _snapshot() => jsonEncode(list.toJson());

  void _pushUndo() {
    _undo.add(_snapshot());
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_snapshot());
    _restoreSnapshot(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_snapshot());
    _restoreSnapshot(_redo.removeLast());
  }

  void _restoreSnapshot(String s) {
    final catId = selectedCategory?.id;
    list = SoundList.fromJson(jsonDecode(s) as Map<String, dynamic>);
    selectedCategory = catId == null ? null : list.categoryById(catId);
    selection.removeWhere((id) => list.byId(id) == null);
    _changed();
  }

  /// Marks the list as modified.
  void _changed({bool hotkeyTable = true}) {
    dirty = true;
    _workingChanged = true;
    if (hotkeyTable) hotkeys.rebuild();
    _updateSearchHits();
    notifyListeners();
  }

  /// Wraps a mutation with undo support.
  void edit(void Function() fn, {bool hotkeyTable = true}) {
    _pushUndo();
    fn();
    _changed(hotkeyTable: hotkeyTable);
  }

  // ================================================================ view
  /// Sounds shown in the main list (selected category, sorted).
  List<Sound> get view {
    final base = list.soundsOf(selectedCategory);
    final col = settings.sortColumn;
    if (col == null || col == 'index') {
      return settings.sortAscending || col == null ? base : base.reversed.toList();
    }
    final sorted = [...base];
    int cmp(Sound a, Sound b) {
      switch (col) {
        case 'tag':
          return a.tag.toLowerCase().compareTo(b.tag.toLowerCase());
        case 'title':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'artist':
          return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        case 'file':
          return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
        case 'duration':
          return a.duration.compareTo(b.duration);
        case 'hotkey':
          return (hotkeyOf(a)?.label() ?? '￿').compareTo(hotkeyOf(b)?.label() ?? '￿');
        case 'format':
          return a.format.compareTo(b.format);
        case 'size':
          return a.size.compareTo(b.size);
        case 'playCount':
          return a.playCount.compareTo(b.playCount);
        case 'added':
          return a.added.compareTo(b.added);
        case 'lastPlayed':
          return (a.lastPlayed ?? DateTime(0)).compareTo(b.lastPlayed ?? DateTime(0));
        case 'path':
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      }
      return 0;
    }

    mergeSort(sorted, compare: (a, b) => settings.sortAscending ? cmp(a, b) : cmp(b, a));
    return sorted;
  }

  void sortBy(String column) {
    if (settings.sortColumn == column) {
      settings.sortAscending = !settings.sortAscending;
    } else {
      settings.sortColumn = column;
      settings.sortAscending = true;
    }
    saveSettings();
    notifyListeners();
  }

  void clearSort() {
    settings.sortColumn = null;
    settings.sortAscending = true;
    saveSettings();
    notifyListeners();
  }

  /// Position of a sound in its category (1-based), used for the # column.
  int indexOf(Sound s) {
    if (selectedCategory == null) return list.sounds.indexOf(s) + 1;
    return selectedCategory!.soundIds.indexOf(s.id) + 1;
  }

  /// Effective hotkey shown for a sound in the current view.
  Hotkey? hotkeyOf(Sound s) {
    if (settings.sameHotkeysInAllCategories) {
      final i = list.soundsOf(selectedCategory).indexOf(s);
      return list.rowHotkeys[i];
    }
    return s.hotkey;
  }

  // ================================================================ selection
  void selectCategory(SoundCategory? c) {
    selectedCategory = c;
    selection.clear();
    focusId = null;
    _updateSearchHits();
    notifyListeners();
  }

  /// Flattened list of visible categories, "All sounds" (null) first.
  List<SoundCategory?> get visibleCategories {
    final out = <SoundCategory?>[null];
    void walk(List<SoundCategory> cs) {
      for (final c in cs) {
        out.add(c);
        if (c.expanded) walk(c.children);
      }
    }

    walk(list.categories);
    return out;
  }

  void selectRelativeCategory(int delta) {
    final cats = visibleCategories;
    var i = cats.indexOf(selectedCategory);
    if (i < 0) i = 0;
    i = (i + delta).clamp(0, cats.length - 1);
    selectCategory(cats[i]);
  }

  void click(Sound s, {bool ctrl = false, bool shift = false}) {
    if (shift && _anchorId != null) {
      final v = view;
      final a = v.indexWhere((x) => x.id == _anchorId);
      final b = v.indexOf(s);
      if (a >= 0 && b >= 0) {
        if (!ctrl) selection.clear();
        for (var i = min(a, b); i <= max(a, b); i++) {
          selection.add(v[i].id);
        }
      }
    } else if (ctrl) {
      if (!selection.remove(s.id)) selection.add(s.id);
      _anchorId = s.id;
    } else {
      selection
        ..clear()
        ..add(s.id);
      _anchorId = s.id;
    }
    focusId = s.id;
    notifyListeners();
  }

  void selectOnly(Sound s) {
    selection
      ..clear()
      ..add(s.id);
    focusId = s.id;
    _anchorId = s.id;
    notifyListeners();
  }

  void selectAll() {
    selection.addAll(view.map((s) => s.id));
    notifyListeners();
  }

  void selectNone() {
    selection.clear();
    notifyListeners();
  }

  void invertSelection() {
    final all = view.map((s) => s.id).toSet();
    final inv = all.difference(selection);
    selection
      ..clear()
      ..addAll(inv);
    notifyListeners();
  }

  void moveFocus(int delta, {bool extend = false}) {
    final v = view;
    if (v.isEmpty) return;
    var i = focusId == null ? -1 : v.indexWhere((s) => s.id == focusId);
    i = (i + delta).clamp(0, v.length - 1);
    if (extend) {
      click(v[i], shift: true);
    } else {
      selectOnly(v[i]);
    }
  }

  Sound? get focused => focusId == null ? null : list.byId(focusId!);

  List<Sound> get selectedSounds => view.where((s) => selection.contains(s.id)).toList();

  /// Selects the sound that is playing or was played last.
  void selectPlaying() {
    final id = currentSoundId ?? lastPlayedId;
    if (id == null) return;
    final s = list.byId(id);
    if (s == null) return;
    if (!view.contains(s)) selectedCategory = null;
    selectOnly(s);
  }

  // ================================================================ adding / removing
  Future<int> addFiles(List<String> paths, {SoundCategory? into, int? insertAt}) async {
    final files = expandPaths(paths);
    if (files.isEmpty) return 0;
    showStatus('Adding ${files.length} files…');
    final results = await probeFiles(files);
    final target = into ?? selectedCategory;
    final failed = files.length - results.length;
    edit(() {
      final added = <Sound>[];
      for (final r in results) {
        added.add(
          Sound(path: r.path, title: r.title, artist: r.artist, duration: r.duration, format: r.format, size: r.size),
        );
      }
      if (target == null && insertAt != null) {
        list.sounds.insertAll(insertAt.clamp(0, list.sounds.length), added);
      } else {
        list.sounds.addAll(added);
      }
      if (target != null) {
        final ids = added.map((s) => s.id);
        if (insertAt != null) {
          target.soundIds.insertAll(insertAt.clamp(0, target.soundIds.length), ids);
        } else {
          target.soundIds.addAll(ids);
        }
      }
      selection
        ..clear()
        ..addAll(added.map((s) => s.id));
    });
    notify(
      failed > 0
          ? 'Added ${results.length} sounds. $failed files could not be read.'
          : 'Added ${results.length} sounds.',
      failed > 0 ? NoticeLevel.warning : NoticeLevel.info,
    );
    _analyzeMissing();
    return results.length;
  }

  /// Measures loudness of sounds that don't have it yet (for normalization).
  Future<void> _analyzeMissing() async {
    if (_analyzing) return;
    _analyzing = true;
    try {
      while (true) {
        final todo = list.sounds.where((s) => s.lufs == null && File(s.path).existsSync()).take(8).toList();
        if (todo.isEmpty) break;
        final res = await analyzeFiles(todo.map((s) => s.path).toList());
        for (final s in todo) {
          s.lufs = res[s.path] ?? double.negativeInfinity;
        }
        _workingChanged = true;
      }
    } finally {
      _analyzing = false;
    }
  }

  /// Removes selected entries. In a category only the category entries are
  /// removed; in "All sounds" the sounds are removed from the list.
  /// With [trash] the files are moved to the trash as well.
  Future<void> removeSelected({bool trash = false}) async {
    final ids = selectedSounds.map((s) => s.id).toSet();
    if (ids.isEmpty) return;
    final paths = ids.map((id) => list.byId(id)!.path).toList();
    if (currentSoundId != null && ids.contains(currentSoundId) && (trash || selectedCategory == null)) stop();
    edit(() {
      if (trash || selectedCategory == null) {
        list.removeSounds(ids);
      } else {
        selectedCategory!.soundIds.removeWhere(ids.contains);
      }
      selection.clear();
    });
    if (trash) {
      var failed = 0;
      for (final path in paths) {
        if (!await moveToTrash(path)) failed++;
      }
      notify(
        failed == 0 ? 'Moved ${paths.length} files to the trash.' : '$failed files could not be moved to the trash.',
        failed == 0 ? NoticeLevel.info : NoticeLevel.warning,
      );
    } else {
      showStatus('Removed ${ids.length} entries.');
    }
  }

  /// Renames the file on disk (keeps the extension).
  Future<bool> renameFile(Sound s, String newBase) async {
    newBase = newBase.trim();
    if (newBase.isEmpty || newBase.contains('/')) return false;
    final target = p.join(p.dirname(s.path), '$newBase${p.extension(s.path)}');
    if (target == s.path) return true;
    if (File(target).existsSync()) {
      notify('A file named ${p.basename(target)} already exists.', NoticeLevel.warning);
      return false;
    }
    try {
      await File(s.path).rename(target);
      edit(() => s.path = target, hotkeyTable: false);
      return true;
    } catch (e) {
      notify('Could not rename: $e', NoticeLevel.error);
      return false;
    }
  }

  void updateSoundInfo(Sound s, {double? duration, int? size, String? format, double? lufs}) {
    if (duration != null) s.duration = duration;
    if (size != null) s.size = size;
    if (format != null) s.format = format;
    s.lufs = lufs;
    _workingChanged = true;
    notifyListeners();
    if (lufs == null) _analyzeMissing();
  }

  // ================================================================ clipboard / move
  void copy({bool cut = false}) {
    _clipboard = selectedSounds.map((s) => s.id).toList();
    _clipboardCut = cut;
    final paths = selectedSounds.map((s) => s.path).join('\n');
    Clipboard.setData(ClipboardData(text: paths));
    showStatus('${cut ? 'Cut' : 'Copied'} ${_clipboard.length} entries.');
  }

  Future<void> paste() async {
    final cat = selectedCategory;
    // From our own clipboard (entries)…
    final internal = _clipboard.where((id) => list.byId(id) != null).toList();
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final ownText = internal.map((id) => list.byId(id)!.path).join('\n');
    if (internal.isNotEmpty && text == ownText) {
      final insertAt = _insertIndex();
      edit(() {
        if (cat == null) {
          // Copy within "All sounds" duplicates the entries.
          final copies = internal.map((id) {
            final o = list.byId(id)!;
            return Sound.fromJson(
              o.toJson()
                ..remove('id')
                ..remove('hotkey'),
            );
          }).toList();
          list.sounds.insertAll(insertAt.clamp(0, list.sounds.length), copies);
          if (_clipboardCut) list.removeSounds(internal.toSet());
        } else {
          if (_clipboardCut) {
            for (final c in list.allCategories) {
              if (c != cat) c.soundIds.removeWhere(internal.contains);
            }
          }
          final newIds = internal.where((id) => !cat.soundIds.contains(id)).toList();
          cat.soundIds.insertAll(insertAt.clamp(0, cat.soundIds.length), newIds);
        }
      });
      if (_clipboardCut) _clipboard = [];
      return;
    }
    // …or file paths / URIs from other applications.
    final files = <String>[];
    for (var line in const LineSplitter().convert(text)) {
      line = line.trim();
      if (line.startsWith('file://')) line = Uri.parse(line).toFilePath();
      if (line.isNotEmpty && FileSystemEntity.typeSync(line) != FileSystemEntityType.notFound) files.add(line);
    }
    if (files.isNotEmpty) await addFiles(files, insertAt: _insertIndex());
  }

  int _insertIndex() {
    final base = selectedCategory == null ? list.sounds.map((s) => s.id).toList() : selectedCategory!.soundIds;
    if (focusId == null) return base.length;
    final i = base.indexOf(focusId!);
    return i < 0 ? base.length : i + 1;
  }

  /// Moves selected entries up/down within the current category.
  void moveSelection(int delta) {
    if (selection.isEmpty) return;
    clearSortIfNeeded();
    edit(() {
      if (selectedCategory == null) {
        _moveIn(list.sounds, (s) => selection.contains(s.id), delta);
      } else {
        _moveIn(selectedCategory!.soundIds, selection.contains, delta);
      }
    });
  }

  void _moveIn<T>(List<T> l, bool Function(T) sel, int delta) {
    if (delta < 0) {
      for (var i = 1; i < l.length; i++) {
        if (sel(l[i]) && !sel(l[i - 1])) {
          final t = l[i - 1];
          l[i - 1] = l[i];
          l[i] = t;
        }
      }
    } else {
      for (var i = l.length - 2; i >= 0; i--) {
        if (sel(l[i]) && !sel(l[i + 1])) {
          final t = l[i + 1];
          l[i + 1] = l[i];
          l[i] = t;
        }
      }
    }
  }

  /// Drag & drop reorder within the view.
  void reorder(List<String> ids, int targetIndex) {
    clearSortIfNeeded();
    edit(() {
      if (selectedCategory == null) {
        final moving = list.sounds.where((s) => ids.contains(s.id)).toList();
        final before = list.sounds.take(targetIndex).where((s) => ids.contains(s.id)).length;
        list.sounds.removeWhere((s) => ids.contains(s.id));
        list.sounds.insertAll((targetIndex - before).clamp(0, list.sounds.length), moving);
      } else {
        final l = selectedCategory!.soundIds;
        final moving = l.where(ids.contains).toList();
        final before = l.take(targetIndex).where(ids.contains).length;
        l.removeWhere(ids.contains);
        l.insertAll((targetIndex - before).clamp(0, l.length), moving);
      }
    });
  }

  void clearSortIfNeeded() {
    if (settings.sortColumn != null) clearSort();
  }

  // ================================================================ categories
  SoundCategory addCategory(String name, {SoundCategory? parent}) {
    final c = SoundCategory(name: name);
    edit(() {
      if (parent == null) {
        list.categories.add(c);
      } else {
        c.parent = parent;
        parent.children.add(c);
        parent.expanded = true;
      }
    });
    return c;
  }

  void removeCategory(SoundCategory c) {
    edit(() {
      (c.parent?.children ?? list.categories).remove(c);
      if (selectedCategory == c || (selectedCategory != null && c.isAncestorOf(selectedCategory!))) {
        selectedCategory = null;
      }
    });
  }

  void updateCategory(SoundCategory c, {String? name, String? icon, bool clearIcon = false, String? description}) {
    edit(() {
      if (name != null) c.name = name;
      if (icon != null) c.icon = icon;
      if (clearIcon) c.icon = null;
      if (description != null) c.description = description;
    }, hotkeyTable: false);
  }

  void toggleExpanded(SoundCategory c) {
    c.expanded = !c.expanded;
    _workingChanged = true;
    notifyListeners();
  }

  /// Moves [c] into [newParent] (null = top level) at [index].
  void moveCategory(SoundCategory c, SoundCategory? newParent, int index) {
    if (newParent == c || (newParent != null && c.isAncestorOf(newParent))) return;
    edit(() {
      final from = c.parent?.children ?? list.categories;
      final oldIndex = from.indexOf(c);
      from.remove(c);
      final to = newParent?.children ?? list.categories;
      if (from == to && oldIndex < index) index--;
      to.insert(index.clamp(0, to.length), c);
      c.parent = newParent;
    });
  }

  /// Adds sounds (by id) to a category, optionally removing them from the
  /// currently shown category (move).
  void addToCategory(SoundCategory target, List<String> ids, {bool move = false}) {
    edit(() {
      for (final id in ids) {
        if (!target.soundIds.contains(id)) target.soundIds.add(id);
      }
      if (move && selectedCategory != null && selectedCategory != target) {
        selectedCategory!.soundIds.removeWhere(ids.contains);
      }
    });
    showStatus('${move ? 'Moved' : 'Added'} ${ids.length} sounds to ${target.name}.');
  }

  // ================================================================ hotkeys
  /// Assigns a hotkey to a sound. Removes it from anything else that uses it.
  void setSoundHotkey(Sound s, Hotkey? h) {
    edit(() {
      if (h != null) _releaseHotkey(h);
      if (settings.sameHotkeysInAllCategories) {
        final row = list.soundsOf(selectedCategory).indexOf(s);
        if (h == null) {
          list.rowHotkeys.remove(row);
        } else {
          list.rowHotkeys[row] = h;
        }
      } else {
        s.hotkey = h;
      }
    });
  }

  void setCategoryHotkey(SoundCategory c, Hotkey? h) {
    edit(() {
      if (h != null) _releaseHotkey(h);
      c.randomHotkey = h;
    });
  }

  void setHotbarHotkey(int cell, Hotkey? h) {
    edit(() {
      if (h != null) _releaseHotkey(h);
      if (h == null) {
        list.hotbar.cellHotkeys.remove(cell);
      } else {
        list.hotbar.cellHotkeys[cell] = h;
      }
    });
  }

  void _releaseHotkey(Hotkey h) {
    final sided = settings.sidedModifiers;
    bool same(Hotkey? x) => x != null && x.normalized(sided) == h.normalized(sided);
    for (final s in list.sounds) {
      if (same(s.hotkey)) s.hotkey = null;
    }
    list.rowHotkeys.removeWhere((_, v) => same(v));
    for (final c in list.allCategories) {
      if (same(c.randomHotkey)) c.randomHotkey = null;
    }
    list.hotbar.cellHotkeys.removeWhere((_, v) => same(v));
  }

  /// Name of whatever currently uses [h] (for the hotkey dialog), or null.
  String? hotkeyOwner(Hotkey h) {
    final sided = settings.sidedModifiers;
    bool same(Hotkey? x) => x != null && x.normalized(sided) == h.normalized(sided);
    for (final e in settings.specialHotkeys.entries) {
      if (same(e.value)) return 'Special hotkey: ${e.key.label}';
    }
    for (final s in list.sounds) {
      if (same(s.hotkey)) return s.tag;
    }
    for (final e in list.rowHotkeys.entries) {
      if (same(e.value)) return 'Row ${e.key + 1}';
    }
    for (final c in list.allCategories) {
      if (same(c.randomHotkey)) return 'Random file from ${c.name}';
    }
    for (final e in list.hotbar.cellHotkeys.entries) {
      if (same(e.value)) return 'Hotbar button ${e.key + 1}';
    }
    return null;
  }

  void toggleHotkeysEnabled([bool? on]) {
    settings.hotkeysEnabled = on ?? !settings.hotkeysEnabled;
    settingsChanged(hotkeyTable: true);
    showStatus(settings.hotkeysEnabled ? 'Hotkeys enabled' : 'Hotkeys disabled');
  }

  void toggleAutoKeys([bool? on]) {
    settings.autoKeysEnabled = on ?? !settings.autoKeysEnabled;
    if (!settings.autoKeysEnabled) autoKeys.releaseAll();
    settingsChanged();
    showStatus(settings.autoKeysEnabled ? 'Auto Keys enabled' : 'Auto Keys disabled');
  }

  // ================================================================ hotbar
  void hotbarAssign(int page, int cell, String soundId) {
    edit(() {
      final pg = list.hotbar.pages[page];
      final old = pg[cell];
      pg[cell] = HotbarEntry(soundId, color: old?.color);
    });
  }

  void hotbarClear(int page, int cell) => edit(() => list.hotbar.pages[page][cell] = null);

  /// Moves an entry. With [withAttributes] (Ctrl held) the hotkey and color
  /// move along with the sound; otherwise they stay at their cells.
  void hotbarMove(int page, int from, int to, {bool withAttributes = false}) {
    if (from == to) return;
    edit(() {
      final hb = list.hotbar;
      final pg = hb.pages[page];
      final a = pg[from], b = pg[to];
      if (withAttributes) {
        pg[to] = a;
        pg[from] = b;
        final ha = hb.cellHotkeys.remove(from), hbk = hb.cellHotkeys.remove(to);
        if (ha != null) hb.cellHotkeys[to] = ha;
        if (hbk != null) hb.cellHotkeys[from] = hbk;
      } else {
        // Hotkey and color stay with the cell.
        HotbarEntry? make(String? id, HotbarEntry? attrs) => id == null ? null : HotbarEntry(id, color: attrs?.color);
        pg[to] = make(a?.soundId, b);
        pg[from] = make(b?.soundId, a);
      }
    });
  }

  void hotbarSetColor(int page, int cell, int? color) {
    edit(() {
      if (list.hotbar.sameColorsOnAllPages) {
        for (final pg in list.hotbar.pages) {
          pg[cell]?.color = color;
        }
      } else {
        list.hotbar.pages[page][cell]?.color = color;
      }
    }, hotkeyTable: false);
  }

  void hotbarResize(int rows, int cols) => edit(() => list.hotbar.resize(rows, cols), hotkeyTable: false);

  void hotbarAddPage() {
    edit(() {
      list.hotbar.addPage();
      list.hotbar.page = list.hotbar.pages.length - 1;
    }, hotkeyTable: false);
  }

  void hotbarRemovePage(int page) {
    if (list.hotbar.pages.length <= 1) return;
    edit(() {
      list.hotbar.pages.removeAt(page);
      list.hotbar.page = list.hotbar.page.clamp(0, list.hotbar.pages.length - 1);
    });
  }

  void hotbarSetPage(int page) {
    list.hotbar.page = page;
    notifyListeners();
  }

  void hotbarSetSameColors(bool v) => edit(() => list.hotbar.sameColorsOnAllPages = v, hotkeyTable: false);

  // ================================================================ search
  void openSearch([String initial = '']) {
    searchOpen = true;
    searchQuery = initial;
    _updateSearchHits();
    if (searchHits.isNotEmpty) _gotoHit(0);
    notifyListeners();
  }

  void setSearch(String q) {
    searchQuery = q;
    _updateSearchHits();
    if (searchHits.isNotEmpty) _gotoHit(0);
    notifyListeners();
  }

  void closeSearch() {
    searchOpen = false;
    searchQuery = '';
    searchHits = [];
    searchHitIndex = -1;
    notifyListeners();
  }

  void _updateSearchHits() {
    final q = searchQuery.trim().toLowerCase();
    if (q.isEmpty) {
      searchHits = [];
      searchHitIndex = -1;
      return;
    }
    final words = q.split(RegExp(r'\s+'));
    searchHits = [
      for (final s in view)
        if (words.every((w) => '${s.tag} ${s.fileName} ${hotkeyOf(s)?.label() ?? ''}'.toLowerCase().contains(w))) s.id,
    ];
    if (searchHitIndex >= searchHits.length) searchHitIndex = searchHits.isEmpty ? -1 : 0;
  }

  void _gotoHit(int i) {
    searchHitIndex = i;
    final s = list.byId(searchHits[i]);
    if (s != null) selectOnly(s);
  }

  void nextHit() {
    if (searchHits.isEmpty) return;
    _gotoHit((searchHitIndex + 1) % searchHits.length);
  }

  void previousHit() {
    if (searchHits.isEmpty) return;
    _gotoHit((searchHitIndex - 1 + searchHits.length) % searchHits.length);
  }

  // ================================================================ playback
  PlayMode get playMode => settings.playMode;

  void setPlayMode(PlayMode m, {bool byHotkey = false}) {
    settings.playMode = m;
    saveSettings();
    if (byHotkey && settings.notifyPlayMode.enabled) {
      native.playNotification(switch (m) {
        PlayMode.both => 0,
        PlayMode.speakers => 3,
        PlayMode.mic => 2,
      }, settings.notifyPlayMode.path);
    }
    showStatus('Play mode: ${m.label}');
    notifyListeners();
  }

  void nextPlayMode({bool byHotkey = false}) {
    final cyc = settings.playModeCycle;
    final i = cyc.indexOf(settings.playMode);
    setPlayMode(cyc[(i + 1) % cyc.length], byHotkey: byHotkey);
  }

  bool get isPlaying => status.value.state == 1;
  bool get isPaused => status.value.state == 2;

  /// Plays a sound. [mode] overrides the play mode for this playback.
  void play(Sound s, {PlayMode? mode, bool byHotkey = false, List<String>? context, double start = 0}) {
    if (!audioConnected) {
      notify('No connection to the sound server.', NoticeLevel.error);
      return;
    }
    if (!File(s.path).existsSync()) {
      notify('File not found: ${s.path}', NoticeLevel.warning);
      return;
    }
    final m = mode ?? settings.playMode;
    if (!_firstSoundPlayed && settings.notifyFirstSound && m != PlayMode.both) {
      native.playNotification(m == PlayMode.speakers ? 3 : 2, settings.notifyPlayMode.path);
    }
    _firstSoundPlayed = true;
    autoKeys.onPlaybackEnd();
    _activeMode = m;
    _playedByHotkey = byHotkey;
    _playContext = context ?? view.map((x) => x.id).toList();
    if (!_playContext.contains(s.id)) _playContext = list.sounds.map((x) => x.id).toList();
    final lufs = (s.lufs != null && s.lufs!.isFinite) ? s.lufs : null;
    void startPlayback() {
      final id = native.play(s.path, speakers: m.toSpeakers, mic: m.toMic, start: start, lufs: lufs);
      if (id <= 0) {
        notify('Could not start playback (error $id).', NoticeLevel.error);
        return;
      }
      _playId = id;
      currentSoundId = s.id;
      lastPlayedId = s.id;
      s.playCount++;
      s.lastPlayed = DateTime.now();
      _workingChanged = true;
      notifyListeners();
    }

    // Auto Keys (push-to-talk) are pressed before the sound starts.
    autoKeys.onPlaybackStart(byHotkey: byHotkey, mode: m).then((_) => startPlayback());
  }

  void playSelected({PlayMode? mode, bool byHotkey = false}) {
    final s = focused ?? (selectedSounds.isNotEmpty ? selectedSounds.first : null);
    if (s != null) play(s, mode: mode, byHotkey: byHotkey);
  }

  /// "Play" button: resumes when paused, otherwise plays the selection.
  void playOrResume({PlayMode? mode, bool byHotkey = false}) {
    if (isPaused && (mode == null || settings.allowResumeInOtherMode)) {
      if (mode != null && mode != _activeMode) {
        _activeMode = mode;
        native.setRouting(mode.toSpeakers, mode.toMic);
      }
      pauseResume();
      return;
    }
    playSelected(mode: mode, byHotkey: byHotkey);
  }

  void pauseResume() {
    final st = status.value.state;
    if (st == 0) return;
    native.pause(st == 1);
    if (st == 1) {
      autoKeys.onPlaybackEnd();
    } else {
      autoKeys.onPlaybackStart(byHotkey: _playedByHotkey, mode: _activeMode);
    }
    _pollStatus();
  }

  void stop() {
    native.stop();
    autoKeys.onPlaybackEnd();
    currentSoundId = null;
    _pollStatus();
    notifyListeners();
  }

  void _onPlaybackFinished(int id, bool natural) {
    if (id != _playId) return;
    final finished = currentSoundId;
    currentSoundId = null;
    autoKeys.onPlaybackEnd();
    if (natural && finished != null && !(settings.autoStop && _playedByHotkey)) {
      final s = list.byId(finished);
      if (settings.repeatCurrent && s != null) {
        play(s, mode: _activeMode, context: _playContext);
        return;
      }
      if (settings.continuePlayback) {
        final next = _relative(finished, 1, wrap: settings.repeatList);
        if (next != null) {
          play(next, mode: _activeMode, context: _playContext);
          return;
        }
      }
    }
    notifyListeners();
  }

  Sound? _relative(String id, int delta, {bool wrap = true}) {
    final ctx = _playContext.where((x) => list.byId(x) != null).toList();
    if (ctx.isEmpty) return null;
    var i = ctx.indexOf(id);
    if (i < 0) return list.byId(ctx.first);
    i += delta;
    if (i < 0 || i >= ctx.length) {
      if (!wrap) return null;
      i = (i + ctx.length) % ctx.length;
    }
    return list.byId(ctx[i]);
  }

  void playPrevious({bool byHotkey = false}) => _playRelative(-1, byHotkey);
  void playNext({bool byHotkey = false}) => _playRelative(1, byHotkey);

  void _playRelative(int delta, bool byHotkey) {
    final ref = currentSoundId ?? lastPlayedId;
    Sound? s;
    if (ref == null) {
      final v = view;
      if (v.isEmpty) return;
      s = delta > 0 ? v.first : v.last;
      _playContext = v.map((x) => x.id).toList();
    } else {
      s = _relative(ref, delta);
    }
    if (s != null) play(s, mode: _activeMode, byHotkey: byHotkey, context: _playContext);
  }

  final _rng = Random();

  void playRandom({SoundCategory? from, bool allCategories = false, PlayMode? mode, bool byHotkey = false}) {
    final pool = allCategories ? list.sounds : list.soundsOf(from ?? selectedCategory);
    if (pool.isEmpty) return;
    var s = pool[_rng.nextInt(pool.length)];
    if (pool.length > 1 && s.id == lastPlayedId) s = pool[_rng.nextInt(pool.length)];
    play(s, mode: mode, byHotkey: byHotkey, context: pool.map((x) => x.id).toList());
  }

  void seek(double sec) {
    native.seek(max(0, sec));
    _pollStatus();
  }

  void jump(double delta) {
    final st = status.value;
    if (st.state == 0) return;
    seek((st.position + delta).clamp(0, st.duration > 0 ? st.duration : double.infinity));
  }

  void setSpeakerVolume(double v) {
    settings.speakerVolume = v.clamp(0.0, 1.0);
    settings.speakerMuted = false;
    native.setSpeakerVolume(settings.speakerVolume);
    notifyListeners();
    _saveSettingsSoon();
  }

  void toggleSpeakerMute() {
    settings.speakerMuted = !settings.speakerMuted;
    native.setSpeakerVolume(settings.speakerMuted ? 0 : settings.speakerVolume);
    saveSettings();
    notifyListeners();
  }

  Timer? _settingsSave;
  void _saveSettingsSoon() {
    _settingsSave?.cancel();
    _settingsSave = Timer(const Duration(milliseconds: 600), saveSettings);
  }

  void toggleRepeat() {
    settings.repeatCurrent = !settings.repeatCurrent;
    saveSettings();
    notifyListeners();
  }

  void toggleContinue() {
    settings.continuePlayback = !settings.continuePlayback;
    saveSettings();
    notifyListeners();
  }

  void toggleRepeatList() {
    settings.repeatList = !settings.repeatList;
    saveSettings();
    notifyListeners();
  }

  void toggleHearMyself() {
    settings.hearMyself = !settings.hearMyself;
    native.setHearMyself(settings.hearMyself);
    saveSettings();
    showStatus(settings.hearMyself ? 'Hear myself on' : 'Hear myself off');
    notifyListeners();
  }

  void toggleBlockVoice() {
    settings.blockVoice = !settings.blockVoice;
    native.setBlockVoice(settings.blockVoice);
    saveSettings();
    showStatus(settings.blockVoice ? 'Block voice on' : 'Block voice off');
    notifyListeners();
  }

  /// Plays raw audio (editor preview) on the speakers.
  void playPreview(DecodedPreview p) {
    previewing = p;
    final id = native.playBuffer(p.samples, p.channels, speakers: true, mic: false);
    if (id > 0) {
      _playId = id;
      currentSoundId = null;
    }
  }

  void _pollStatus() {
    final s = native.status();
    final old = status.value;
    status.value = s;
    if ((old.state == 0) != (s.state == 0) || old.state != s.state) notifyListeners();
    // While something plays, follow it every rendered frame so the seek bar,
    // timer and meters move smoothly; the timer alone only ticks at 20 Hz.
    if (s.state == 1 && !_framePolling) {
      _framePolling = true;
      _pollEachFrame();
    }
  }

  bool _framePolling = false;

  void _pollEachFrame() {
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      final s = native.status();
      final old = status.value;
      status.value = s;
      if (old.state != s.state) notifyListeners();
      if (s.state == 1) {
        _pollEachFrame();
      } else {
        _framePolling = false;
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }
}

/// Audio being previewed from the editor.
class DecodedPreview {
  final Float32List samples;
  final int channels;
  DecodedPreview(this.samples, this.channels);
}
