// SPDX-License-Identifier: GPL-3.0-or-later
import 'hotkey.dart';

enum PlayMode {
  both('Speakers and microphone'),
  speakers('Speakers only'),
  mic('Microphone only');

  final String label;
  const PlayMode(this.label);
  bool get toSpeakers => this != PlayMode.mic;
  bool get toMic => this != PlayMode.speakers;
}

enum HotkeyBackend {
  auto('Automatic'),
  evdev('evdev (any desktop, needs input group)'),
  x11('X11 key grabs'),
  portal('XDG GlobalShortcuts portal');

  final String label;
  const HotkeyBackend(this.label);
}

/// Special hotkey actions (File > Preferences > Hotkeys > Special hotkeys).
enum SpecialAction {
  stop('Stop playback'),
  play('Start playback'),
  pauseResume('Pause/resume playback'),
  playPrevious('Play previous file'),
  playNext('Play next file'),
  selectPrevious('Select previous file'),
  selectNext('Select next file'),
  playSelected('Play selected file'),
  playSelectedSpeakers('Play selected file on speakers'),
  playSelectedMic('Play selected file on microphone'),
  playRandom('Play random file'),
  playRandomAll('Play random file from all categories'),
  playRandomSpeakers('Play random file on speakers'),
  playRandomMic('Play random file on microphone'),
  selectPreviousCategory('Select previous category'),
  selectNextCategory('Select next category'),
  startRecording('Start recording'),
  stopRecording('Stop recording'),
  toggleRecording('Start/stop recording'),
  jumpBack('Jump back'),
  jumpForward('Jump forward'),
  volumeDown('Lower speakers volume'),
  volumeUp('Raise speakers volume'),
  volumeSet('Set speakers volume'),
  muteSpeakers('Mute/unmute speakers'),
  modeDefault('Set play mode: speakers and microphone'),
  modeSpeakers('Set play mode: speakers'),
  modeMic('Set play mode: microphone'),
  modeNext('Switch to next play mode'),
  autoKeysEnable('Enable Auto Keys'),
  autoKeysDisable('Disable Auto Keys'),
  autoKeysToggle('Toggle Auto Keys'),
  hotkeysEnable('Enable hotkeys'),
  hotkeysDisable('Disable hotkeys'),
  hotkeysToggle('Toggle hotkeys'),
  toggleRepeat('Toggle repeat current file'),
  toggleContinue('Toggle continue playback'),
  toggleHearMyself('Toggle hear myself'),
  toggleBlockVoice('Toggle block voice'),
  showWindow('Show/hide fboard window');

  final String label;
  const SpecialAction(this.label);

  /// These work even while hotkeys are disabled.
  bool get alwaysActive => this == hotkeysEnable || this == hotkeysToggle;
}

enum AutoKeyPress { hold, beforeAndAfter }

enum AutoKeyWhen {
  always('Always'),
  fullscreen('Foreground application is fullscreen'),
  running('Certain application is running'),
  foreground('Certain application is in foreground');

  final String label;
  const AutoKeyWhen(this.label);
}

class AutoKey {
  String name;
  bool enabled;
  int code; // evdev key or button code
  bool onlyHotkey;
  AutoKeyPress press;
  AutoKeyWhen when;
  List<String> apps; // process names / window classes

  AutoKey({
    this.name = '',
    this.enabled = true,
    required this.code,
    this.onlyHotkey = true,
    this.press = AutoKeyPress.hold,
    this.when = AutoKeyWhen.always,
    List<String>? apps,
  }) : apps = apps ?? [];

  Map<String, dynamic> toJson() => {
    'name': name,
    'enabled': enabled,
    'code': code,
    'onlyHotkey': onlyHotkey,
    'press': press.name,
    'when': when.name,
    'apps': apps,
  };

  factory AutoKey.fromJson(Map<String, dynamic> j) => AutoKey(
    name: j['name'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
    code: j['code'] as int? ?? 37,
    onlyHotkey: j['onlyHotkey'] as bool? ?? true,
    press: AutoKeyPress.values.byName(j['press'] as String? ?? 'hold'),
    when: AutoKeyWhen.values.byName(j['when'] as String? ?? 'always'),
    apps: (j['apps'] as List?)?.cast<String>().toList(),
  );
}

const allColumns = <String, String>{
  'index': '#',
  'tag': 'Tag',
  'title': 'Title',
  'artist': 'Artist',
  'file': 'File name',
  'duration': 'Duration',
  'hotkey': 'Hotkey',
  'format': 'Format',
  'size': 'Size',
  'playCount': 'Play count',
  'added': 'Added on',
  'lastPlayed': 'Last played on',
  'path': 'Path',
};

class NotificationPref {
  bool enabled;
  String? path;
  NotificationPref({this.enabled = true, this.path});
  Map<String, dynamic> toJson() => {'enabled': enabled, if (path != null) 'path': path};
  factory NotificationPref.fromJson(dynamic j) => j is Map
      ? NotificationPref(enabled: j['enabled'] as bool? ?? true, path: j['path'] as String?)
      : NotificationPref();
}

class Settings {
  // ------------------------------------------------------------- interface
  String themeMode = 'system'; // system | light | dark
  bool dynamicColor = true;
  int seedColor = 0xFF6750A4;
  bool typingBeginsSearch = true;
  bool allowResumeInOtherMode = true;
  bool showMicLevel = true;
  List<PlayMode> playModeCycle = [PlayMode.both, PlayMode.speakers, PlayMode.mic];
  bool closeToTray = true;
  bool startMinimized = false;
  bool showTray = true;
  bool showCategories = true;
  bool showCategoryInfo = false;
  int categoryIconSize = 1; // 0 smaller, 1 small, 2 medium, 3 large
  bool showHotbar = true;
  bool showRecorder = false;
  double categoriesWidth = 240;
  List<String> columnOrder = ['index', 'tag', 'duration', 'hotkey', 'playCount', 'added', 'lastPlayed', 'path'];
  Map<String, double> columnWidths = {};
  Set<String> hiddenColumns = {'title', 'artist', 'file', 'format', 'size'};
  String? sortColumn;
  bool sortAscending = true;

  // ------------------------------------------------------------- playback
  PlayMode playMode = PlayMode.both;
  bool repeatCurrent = false;
  bool continuePlayback = false;
  bool repeatList = false;
  double speakerVolume = 0.8;
  bool speakerMuted = false;

  // ------------------------------------------------------------- audio
  bool normalize = true;
  double normalizeTarget = -23; // LUFS (= 89 dB in Soundpad terms)
  bool dynamicNormalization = false;
  double micVolume = 1.0; // used when normalization is off
  bool blockVoice = false;
  bool activationSound = false;
  String? activationSoundPath;
  bool hearMyself = false;

  // ------------------------------------------------------------- devices
  String? micSource; // null = system default
  String? outputSink; // null = system default
  bool setDefaultMic = true;

  // ------------------------------------------------------------- hotkeys
  HotkeyBackend hotkeyBackend = HotkeyBackend.auto;
  bool hotkeysEnabled = true;
  bool passHotkeys = true;
  bool autoStop = true;
  bool sidedModifiers = false;
  bool sameHotkeysInAllCategories = false;
  Map<SpecialAction, Hotkey> specialHotkeys = {};
  double jumpSeconds = 5;
  double volumeStep = 0.1;
  double volumeSetValue = 0.5;
  bool numcodeEnabled = false;
  int numcodeMods = Mod.alt;
  bool indexHotkeysEnabled = false;
  int indexHotkeyMods = Mod.ctrl | Mod.alt;

  // ------------------------------------------------------------- auto keys
  bool autoKeysEnabled = true;
  List<AutoKey> autoKeys = [];

  // ------------------------------------------------------------- recorder
  String recordFormat = 'm4a';
  bool recordInsertAtEnd = true;
  bool recordNormalize = true;
  double recordNormalizeTarget = -23;
  bool recordTrimSilence = false;
  double recordMaxSeconds = 300;
  String? recordSource; // null = what you hear
  double recordGain = 1.0;
  String? recordDirectory;

  // ------------------------------------------------------------- notifications
  NotificationPref notifyPlayMode = NotificationPref();
  NotificationPref notifyRecorder = NotificationPref();
  NotificationPref notifyHotkeysToggle = NotificationPref();
  NotificationPref notifyAutoKeysToggle = NotificationPref();
  bool notifyFirstSound = true;

  // ------------------------------------------------------------- lists
  String? listPath;
  List<String> recentLists = [];

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode,
    'dynamicColor': dynamicColor,
    'seedColor': seedColor,
    'typingBeginsSearch': typingBeginsSearch,
    'allowResumeInOtherMode': allowResumeInOtherMode,
    'showMicLevel': showMicLevel,
    'playModeCycle': playModeCycle.map((m) => m.name).toList(),
    'closeToTray': closeToTray,
    'startMinimized': startMinimized,
    'showTray': showTray,
    'showCategories': showCategories,
    'showCategoryInfo': showCategoryInfo,
    'categoryIconSize': categoryIconSize,
    'showHotbar': showHotbar,
    'showRecorder': showRecorder,
    'categoriesWidth': categoriesWidth,
    'columnOrder': columnOrder,
    'columnWidths': columnWidths,
    'hiddenColumns': hiddenColumns.toList(),
    'sortColumn': sortColumn,
    'sortAscending': sortAscending,
    'playMode': playMode.name,
    'repeatCurrent': repeatCurrent,
    'continuePlayback': continuePlayback,
    'repeatList': repeatList,
    'speakerVolume': speakerVolume,
    'speakerMuted': speakerMuted,
    'normalize': normalize,
    'normalizeTarget': normalizeTarget,
    'dynamicNormalization': dynamicNormalization,
    'micVolume': micVolume,
    'blockVoice': blockVoice,
    'activationSound': activationSound,
    'activationSoundPath': activationSoundPath,
    'hearMyself': hearMyself,
    'micSource': micSource,
    'outputSink': outputSink,
    'setDefaultMic': setDefaultMic,
    'hotkeyBackend': hotkeyBackend.name,
    'hotkeysEnabled': hotkeysEnabled,
    'passHotkeys': passHotkeys,
    'autoStop': autoStop,
    'sidedModifiers': sidedModifiers,
    'sameHotkeysInAllCategories': sameHotkeysInAllCategories,
    'specialHotkeys': {for (final e in specialHotkeys.entries) e.key.name: e.value.toJson()},
    'jumpSeconds': jumpSeconds,
    'volumeStep': volumeStep,
    'volumeSetValue': volumeSetValue,
    'numcodeEnabled': numcodeEnabled,
    'numcodeMods': numcodeMods,
    'indexHotkeysEnabled': indexHotkeysEnabled,
    'indexHotkeyMods': indexHotkeyMods,
    'autoKeysEnabled': autoKeysEnabled,
    'autoKeys': autoKeys.map((a) => a.toJson()).toList(),
    'recordFormat': recordFormat,
    'recordInsertAtEnd': recordInsertAtEnd,
    'recordNormalize': recordNormalize,
    'recordNormalizeTarget': recordNormalizeTarget,
    'recordTrimSilence': recordTrimSilence,
    'recordMaxSeconds': recordMaxSeconds,
    'recordSource': recordSource,
    'recordGain': recordGain,
    'recordDirectory': recordDirectory,
    'notifyPlayMode': notifyPlayMode.toJson(),
    'notifyRecorder': notifyRecorder.toJson(),
    'notifyHotkeysToggle': notifyHotkeysToggle.toJson(),
    'notifyAutoKeysToggle': notifyAutoKeysToggle.toJson(),
    'notifyFirstSound': notifyFirstSound,
    'listPath': listPath,
    'recentLists': recentLists,
  };

  static Settings fromJson(Map<String, dynamic> j) {
    final s = Settings();
    T v<T>(String k, T def) {
      final x = j[k];
      if (x is T) return x;
      if (T == double && x is num) return x.toDouble() as T;
      return def;
    }

    s.themeMode = v('themeMode', s.themeMode);
    s.dynamicColor = v('dynamicColor', s.dynamicColor);
    s.seedColor = v('seedColor', s.seedColor);
    s.typingBeginsSearch = v('typingBeginsSearch', s.typingBeginsSearch);
    s.allowResumeInOtherMode = v('allowResumeInOtherMode', s.allowResumeInOtherMode);
    s.showMicLevel = v('showMicLevel', s.showMicLevel);
    final cyc = (j['playModeCycle'] as List?)
        ?.map((e) => PlayMode.values.asNameMap()[e])
        .whereType<PlayMode>()
        .toList();
    if (cyc != null && cyc.length >= 2) s.playModeCycle = cyc;
    s.closeToTray = v('closeToTray', s.closeToTray);
    s.startMinimized = v('startMinimized', s.startMinimized);
    s.showTray = v('showTray', s.showTray);
    s.showCategories = v('showCategories', s.showCategories);
    s.showCategoryInfo = v('showCategoryInfo', s.showCategoryInfo);
    s.categoryIconSize = v('categoryIconSize', s.categoryIconSize);
    s.showHotbar = v('showHotbar', s.showHotbar);
    s.showRecorder = v('showRecorder', s.showRecorder);
    s.categoriesWidth = v('categoriesWidth', s.categoriesWidth);
    final order = (j['columnOrder'] as List?)?.cast<String>().where(allColumns.containsKey).toList();
    if (order != null) {
      s.columnOrder = [...order, ...allColumns.keys.where((c) => !order.contains(c))];
    } else {
      s.columnOrder = [...s.columnOrder, ...allColumns.keys.where((c) => !s.columnOrder.contains(c))];
    }
    s.columnWidths = (j['columnWidths'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toDouble())) ?? {};
    final hidden = (j['hiddenColumns'] as List?)?.cast<String>();
    if (hidden != null) s.hiddenColumns = hidden.toSet();
    s.sortColumn = j['sortColumn'] as String?;
    s.sortAscending = v('sortAscending', s.sortAscending);
    s.playMode = PlayMode.values.asNameMap()[j['playMode']] ?? s.playMode;
    s.repeatCurrent = v('repeatCurrent', s.repeatCurrent);
    s.continuePlayback = v('continuePlayback', s.continuePlayback);
    s.repeatList = v('repeatList', s.repeatList);
    s.speakerVolume = v('speakerVolume', s.speakerVolume);
    s.speakerMuted = v('speakerMuted', s.speakerMuted);
    s.normalize = v('normalize', s.normalize);
    s.normalizeTarget = v('normalizeTarget', s.normalizeTarget);
    s.dynamicNormalization = v('dynamicNormalization', s.dynamicNormalization);
    s.micVolume = v('micVolume', s.micVolume);
    s.blockVoice = v('blockVoice', s.blockVoice);
    s.activationSound = v('activationSound', s.activationSound);
    s.activationSoundPath = j['activationSoundPath'] as String?;
    s.hearMyself = v('hearMyself', s.hearMyself);
    s.micSource = j['micSource'] as String?;
    s.outputSink = j['outputSink'] as String?;
    s.setDefaultMic = v('setDefaultMic', s.setDefaultMic);
    s.hotkeyBackend = HotkeyBackend.values.asNameMap()[j['hotkeyBackend']] ?? s.hotkeyBackend;
    s.hotkeysEnabled = v('hotkeysEnabled', s.hotkeysEnabled);
    s.passHotkeys = v('passHotkeys', s.passHotkeys);
    s.autoStop = v('autoStop', s.autoStop);
    s.sidedModifiers = v('sidedModifiers', s.sidedModifiers);
    s.sameHotkeysInAllCategories = v('sameHotkeysInAllCategories', s.sameHotkeysInAllCategories);
    final sh = j['specialHotkeys'] as Map?;
    if (sh != null) {
      for (final e in sh.entries) {
        final a = SpecialAction.values.asNameMap()[e.key];
        final h = Hotkey.fromJson(e.value);
        if (a != null && h != null) s.specialHotkeys[a] = h;
      }
    }
    s.jumpSeconds = v('jumpSeconds', s.jumpSeconds);
    s.volumeStep = v('volumeStep', s.volumeStep);
    s.volumeSetValue = v('volumeSetValue', s.volumeSetValue);
    s.numcodeEnabled = v('numcodeEnabled', s.numcodeEnabled);
    s.numcodeMods = v('numcodeMods', s.numcodeMods);
    s.indexHotkeysEnabled = v('indexHotkeysEnabled', s.indexHotkeysEnabled);
    s.indexHotkeyMods = v('indexHotkeyMods', s.indexHotkeyMods);
    s.autoKeysEnabled = v('autoKeysEnabled', s.autoKeysEnabled);
    s.autoKeys = (j['autoKeys'] as List?)?.map((a) => AutoKey.fromJson(a as Map<String, dynamic>)).toList() ?? [];
    s.recordFormat = v('recordFormat', s.recordFormat);
    s.recordInsertAtEnd = v('recordInsertAtEnd', s.recordInsertAtEnd);
    s.recordNormalize = v('recordNormalize', s.recordNormalize);
    s.recordNormalizeTarget = v('recordNormalizeTarget', s.recordNormalizeTarget);
    s.recordTrimSilence = v('recordTrimSilence', s.recordTrimSilence);
    s.recordMaxSeconds = v('recordMaxSeconds', s.recordMaxSeconds);
    s.recordSource = j['recordSource'] as String?;
    s.recordGain = v('recordGain', s.recordGain);
    s.recordDirectory = j['recordDirectory'] as String?;
    s.notifyPlayMode = NotificationPref.fromJson(j['notifyPlayMode']);
    s.notifyRecorder = NotificationPref.fromJson(j['notifyRecorder']);
    s.notifyHotkeysToggle = NotificationPref.fromJson(j['notifyHotkeysToggle']);
    s.notifyAutoKeysToggle = NotificationPref.fromJson(j['notifyAutoKeysToggle']);
    s.notifyFirstSound = v('notifyFirstSound', s.notifyFirstSound);
    s.listPath = j['listPath'] as String?;
    s.recentLists = (j['recentLists'] as List?)?.cast<String>().toList() ?? [];
    return s;
  }
}
