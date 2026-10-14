// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';

import 'package:path/path.dart' as p;

import 'hotkey.dart';

final _rng = Random();
String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36) + _rng.nextInt(1 << 30).toRadixString(36);

class Sound {
  final String id;
  String path;
  String title;
  String artist;
  double duration;
  String format;
  int size;
  Hotkey? hotkey;
  int playCount;
  DateTime added;
  DateTime? lastPlayed;
  double? lufs;

  Sound({
    String? id,
    required this.path,
    this.title = '',
    this.artist = '',
    this.duration = 0,
    this.format = '',
    this.size = 0,
    this.hotkey,
    this.playCount = 0,
    DateTime? added,
    this.lastPlayed,
    this.lufs,
  }) : id = id ?? newId(),
       added = added ?? DateTime.now();

  String get fileName => p.basename(path);
  String get baseName => p.basenameWithoutExtension(path);

  /// "Artist - Title", "Artist", "Title" or the file name without extension.
  String get tag {
    final a = artist.trim(), t = title.trim();
    if (a.isNotEmpty && t.isNotEmpty) return '$a - $t';
    if (a.isNotEmpty) return a;
    if (t.isNotEmpty) return t;
    return baseName;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    if (title.isNotEmpty) 'title': title,
    if (artist.isNotEmpty) 'artist': artist,
    'duration': duration,
    'format': format,
    'size': size,
    if (hotkey != null) 'hotkey': hotkey!.toJson(),
    'playCount': playCount,
    'added': added.toIso8601String(),
    if (lastPlayed != null) 'lastPlayed': lastPlayed!.toIso8601String(),
    if (lufs != null && lufs!.isFinite) 'lufs': lufs,
  };

  factory Sound.fromJson(Map<String, dynamic> j) => Sound(
    id: j['id'] as String?,
    path: j['path'] as String,
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    duration: (j['duration'] as num?)?.toDouble() ?? 0,
    format: j['format'] as String? ?? '',
    size: j['size'] as int? ?? 0,
    hotkey: Hotkey.fromJson(j['hotkey']),
    playCount: j['playCount'] as int? ?? 0,
    added: DateTime.tryParse(j['added'] as String? ?? ''),
    lastPlayed: DateTime.tryParse(j['lastPlayed'] as String? ?? ''),
    lufs: (j['lufs'] as num?)?.toDouble(),
  );
}

class SoundCategory {
  final String id;
  String name;
  String? icon; // image path, or null for the default icon
  String description;
  List<String> soundIds;
  List<SoundCategory> children;
  Hotkey? randomHotkey;
  bool expanded;
  SoundCategory? parent;

  SoundCategory({
    String? id,
    required this.name,
    this.icon,
    this.description = '',
    List<String>? soundIds,
    List<SoundCategory>? children,
    this.randomHotkey,
    this.expanded = true,
  }) : id = id ?? newId(),
       soundIds = soundIds ?? [],
       children = children ?? [] {
    for (final c in this.children) {
      c.parent = this;
    }
  }

  Iterable<SoundCategory> get descendants sync* {
    for (final c in children) {
      yield c;
      yield* c.descendants;
    }
  }

  bool isAncestorOf(SoundCategory other) {
    for (var c = other.parent; c != null; c = c.parent) {
      if (c == this) return true;
    }
    return false;
  }

  int get depth {
    var d = 0;
    for (var c = parent; c != null; c = c.parent) {
      d++;
    }
    return d;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (icon != null) 'icon': icon,
    if (description.isNotEmpty) 'description': description,
    'sounds': soundIds,
    if (children.isNotEmpty) 'children': children.map((c) => c.toJson()).toList(),
    if (randomHotkey != null) 'randomHotkey': randomHotkey!.toJson(),
    'expanded': expanded,
  };

  factory SoundCategory.fromJson(Map<String, dynamic> j) => SoundCategory(
    id: j['id'] as String?,
    name: j['name'] as String? ?? 'SoundCategory',
    icon: j['icon'] as String?,
    description: j['description'] as String? ?? '',
    soundIds: (j['sounds'] as List?)?.cast<String>().toList(),
    children: (j['children'] as List?)?.map((c) => SoundCategory.fromJson(c as Map<String, dynamic>)).toList(),
    randomHotkey: Hotkey.fromJson(j['randomHotkey']),
    expanded: j['expanded'] as bool? ?? true,
  );
}

class HotbarEntry {
  String soundId;
  int? color; // ARGB
  HotbarEntry(this.soundId, {this.color});

  Map<String, dynamic> toJson() => {'sound': soundId, if (color != null) 'color': color};
  factory HotbarEntry.fromJson(Map<String, dynamic> j) => HotbarEntry(j['sound'] as String, color: j['color'] as int?);
}

class Hotbar {
  int rows;
  int cols;
  bool sameColorsOnAllPages;
  List<List<HotbarEntry?>> pages;
  int page = 0;

  /// Hotkeys belong to cell positions and are shared by all pages: a hotkey
  /// plays the entry of its cell on the current page.
  Map<int, Hotkey> cellHotkeys;

  Hotbar({
    this.rows = 2,
    this.cols = 8,
    this.sameColorsOnAllPages = false,
    List<List<HotbarEntry?>>? pages,
    Map<int, Hotkey>? cellHotkeys,
  }) : pages = pages ?? [List.filled(16, null, growable: true)],
       cellHotkeys = cellHotkeys ?? {} {
    for (final pg in this.pages) {
      _fit(pg);
    }
  }

  int get cells => rows * cols;

  void _fit(List<HotbarEntry?> pg) {
    while (pg.length < cells) {
      pg.add(null);
    }
    if (pg.length > cells) pg.removeRange(cells, pg.length);
  }

  void resize(int r, int c) {
    rows = r;
    cols = c;
    for (final pg in pages) {
      _fit(pg);
    }
    cellHotkeys.removeWhere((k, _) => k >= cells);
  }

  void addPage() => pages.add(List.filled(cells, null, growable: true));

  Map<String, dynamic> toJson() => {
    'rows': rows,
    'cols': cols,
    'sameColors': sameColorsOnAllPages,
    'pages': pages.map((pg) => pg.map((e) => e?.toJson()).toList()).toList(),
    if (cellHotkeys.isNotEmpty) 'hotkeys': {for (final e in cellHotkeys.entries) '${e.key}': e.value.toJson()},
  };

  factory Hotbar.fromJson(Map<String, dynamic> j) => Hotbar(
    rows: j['rows'] as int? ?? 2,
    cols: j['cols'] as int? ?? 8,
    sameColorsOnAllPages: j['sameColors'] as bool? ?? false,
    pages: (j['pages'] as List?)
        ?.map(
          (pg) => (pg as List)
              .map((e) => e == null ? null : HotbarEntry.fromJson(e as Map<String, dynamic>))
              .toList(growable: true),
        )
        .toList(),
    cellHotkeys: (j['hotkeys'] as Map?)?.map((k, v) => MapEntry(int.parse(k as String), Hotkey.fromJson(v)!)),
  );
}

/// A complete sound list (what Soundpad calls a .spl file). Stored as JSON
/// with the .fbl extension.
class SoundList {
  static const fileExtension = 'fbl';
  static const formatVersion = 1;

  List<Sound> sounds; // "All sounds", in list order
  List<SoundCategory> categories; // top level categories
  Hotbar hotbar;

  /// Row hotkeys for "Same hotkeys in all categories" (row index -> hotkey).
  Map<int, Hotkey> rowHotkeys;

  SoundList({List<Sound>? sounds, List<SoundCategory>? categories, Hotbar? hotbar, Map<int, Hotkey>? rowHotkeys})
    : sounds = sounds ?? [],
      categories = categories ?? [],
      hotbar = hotbar ?? Hotbar(),
      rowHotkeys = rowHotkeys ?? {};

  Iterable<SoundCategory> get allCategories sync* {
    for (final c in categories) {
      yield c;
      yield* c.descendants;
    }
  }

  Sound? byId(String id) => sounds.firstWhereOrNullById(id);

  SoundCategory? categoryById(String id) {
    for (final c in allCategories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Sounds of a category (or all sounds when null), in order.
  List<Sound> soundsOf(SoundCategory? c) {
    if (c == null) return sounds;
    final map = {for (final s in sounds) s.id: s};
    return [
      for (final id in c.soundIds)
        if (map[id] != null) map[id]!,
    ];
  }

  void removeSounds(Set<String> ids) {
    sounds.removeWhere((s) => ids.contains(s.id));
    for (final c in allCategories) {
      c.soundIds.removeWhere(ids.contains);
    }
    for (final pg in hotbar.pages) {
      for (var i = 0; i < pg.length; i++) {
        if (pg[i] != null && ids.contains(pg[i]!.soundId)) pg[i] = null;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'fboard': formatVersion,
    'sounds': sounds.map((s) => s.toJson()).toList(),
    'categories': categories.map((c) => c.toJson()).toList(),
    'hotbar': hotbar.toJson(),
    if (rowHotkeys.isNotEmpty) 'rowHotkeys': {for (final e in rowHotkeys.entries) '${e.key}': e.value.toJson()},
  };

  factory SoundList.fromJson(Map<String, dynamic> j) => SoundList(
    sounds: (j['sounds'] as List?)?.map((s) => Sound.fromJson(s as Map<String, dynamic>)).toList(),
    categories: (j['categories'] as List?)?.map((c) => SoundCategory.fromJson(c as Map<String, dynamic>)).toList(),
    hotbar: j['hotbar'] is Map ? Hotbar.fromJson(j['hotbar'] as Map<String, dynamic>) : null,
    rowHotkeys: (j['rowHotkeys'] as Map?)?.map((k, v) => MapEntry(int.parse(k as String), Hotkey.fromJson(v)!)),
  );
}

extension on List<Sound> {
  Sound? firstWhereOrNullById(String id) {
    for (final s in this) {
      if (s.id == id) return s;
    }
    return null;
  }
}
