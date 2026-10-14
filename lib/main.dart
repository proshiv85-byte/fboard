// SPDX-License-Identifier: GPL-3.0-or-later
// fboard – a free and open-source soundboard for Linux.
import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app/controller.dart';
import 'app/single_instance.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';
import 'ui/tray.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final instance = await SingleInstance.acquire(onActivate: _showWindow);
  if (!instance) exit(0);

  await windowManager.ensureInitialized();
  app = AppController();
  await app.init();
  for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint, ProcessSignal.sighup]) {
    sig.watch().listen((_) => quitApp());
  }

  final startHidden = args.contains('--minimized') || (app.settings.startMinimized && app.settings.showTray);
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(title: 'fboard', size: Size(1100, 720), minimumSize: Size(720, 480), center: true),
    () async {
      await windowManager.setPreventClose(true);
      if (!startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
  Color? accent;
  try {
    // Some desktops never answer; don't block startup on it.
    accent = await DynamicColorPlugin.getAccentColor().timeout(const Duration(milliseconds: 800));
  } catch (_) {}
  runApp(FboardApp(systemAccent: accent));
}

Future<void> _showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

Future<void> quitApp() async {
  await app.shutdown();
  await SingleInstance.release();
  await windowManager.setPreventClose(false);
  exit(0);
}

class FboardApp extends StatefulWidget {
  final Color? systemAccent;
  const FboardApp({super.key, this.systemAccent});

  @override
  State<FboardApp> createState() => _FboardAppState();
}

class _FboardAppState extends State<FboardApp> with WindowListener {
  late final Tray _tray = Tray(onShow: _showWindow, onQuit: quitApp);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    app.addListener(_onApp);
    _tray.sync();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    app.removeListener(_onApp);
    super.dispose();
  }

  String? _lastTitle;
  void _onApp() {
    final name = app.listPath ?? 'Untitled sound list';
    final title = 'fboard – $name${app.dirty ? ' *' : ''}';
    if (title != _lastTitle) {
      _lastTitle = title;
      windowManager.setTitle(title);
    }
    _tray.sync();
    setState(() {});
  }

  @override
  Future<void> onWindowClose() async {
    if (app.settings.closeToTray && _tray.visible) {
      await windowManager.hide();
    } else {
      await quitApp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final seed = s.dynamicColor && widget.systemAccent != null ? widget.systemAccent! : Color(s.seedColor);
    return MaterialApp(
      title: 'fboard',
      debugShowCheckedModeBanner: false,
      themeMode: switch (s.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: buildTheme(seed, Brightness.light),
      darkTheme: buildTheme(seed, Brightness.dark),
      home: const HomePage(),
    );
  }
}
