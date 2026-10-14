// SPDX-License-Identifier: GPL-3.0-or-later
// Client for org.freedesktop.portal.GlobalShortcuts.
import 'dart:async';

import 'package:dbus/dbus.dart';

class PortalShortcut {
  final String id;
  final String description;
  final String? preferredTrigger;
  PortalShortcut(this.id, this.description, this.preferredTrigger);
}

class PortalShortcuts {
  static const _iface = 'org.freedesktop.portal.GlobalShortcuts';
  static const appId = 'io.github.proshiv85_byte.fboard';
  final void Function(String id) onActivated;
  final void Function(String error) onError;

  final DBusClient _bus = DBusClient.session();
  late final DBusRemoteObject _portal = DBusRemoteObject(
    _bus,
    name: 'org.freedesktop.portal.Desktop',
    path: DBusObjectPath('/org/freedesktop/portal/desktop'),
  );
  StreamSubscription<DBusSignal>? _responses;
  StreamSubscription<DBusSignal>? _activated;
  final Map<String, DBusSignal> _pendingResponses = {};
  final Map<String, Completer<DBusSignal>> _waiting = {};
  DBusObjectPath? _session;
  int _token = 0;
  bool _busy = false;
  List<PortalShortcut>? _queued;

  PortalShortcuts({required this.onActivated, required this.onError}) {
    _responses = DBusSignalStream(_bus, interface: 'org.freedesktop.portal.Request', name: 'Response').listen((s) {
      final key = s.path.value;
      final c = _waiting.remove(key);
      if (c != null) {
        c.complete(s);
      } else {
        _pendingResponses[key] = s;
      }
    });
    _activated = DBusSignalStream(_bus, interface: _iface, name: 'Activated').listen((s) {
      if (_session == null || s.values.isEmpty || s.values[0] != _session) return;
      onActivated((s.values[1] as DBusString).value);
    });
  }

  Future<DBusSignal> _awaitResponse(DBusObjectPath request) {
    final key = request.value;
    final early = _pendingResponses.remove(key);
    if (early != null) return Future.value(early);
    final c = Completer<DBusSignal>();
    _waiting[key] = c;
    return c.future.timeout(const Duration(minutes: 2));
  }

  String _nextToken() => 'fboard${_token++}';

  bool _registered = false;

  /// Unsandboxed apps must tell xdg-desktop-portal (1.19+) their app id
  /// before using portals that need one. Older portals don't have the
  /// registry; that's fine.
  Future<void> _register() async {
    if (_registered) return;
    _registered = true;
    try {
      await _portal.callMethod('org.freedesktop.host.portal.Registry', 'Register', [
        const DBusString(appId),
        DBusDict.stringVariant({}),
      ], replySignature: DBusSignature(''));
    } catch (e) {
      registerError = e.toString();
    }
  }

  String? registerError;

  Future<void> _closeSession() async {
    final s = _session;
    _session = null;
    if (s == null) return;
    try {
      await DBusRemoteObject(
        _bus,
        name: 'org.freedesktop.portal.Desktop',
        path: s,
      ).callMethod('org.freedesktop.portal.Session', 'Close', [], replySignature: DBusSignature(''));
    } catch (_) {}
  }

  /// Binds the given shortcuts. Each call creates a new session because the
  /// portal only allows binding once per session.
  Future<void> bind(List<PortalShortcut> shortcuts) async {
    if (_busy) {
      _queued = shortcuts;
      return;
    }
    _busy = true;
    try {
      await _register();
      await _closeSession();
      if (shortcuts.isEmpty) return;
      final create = await _portal.callMethod(_iface, 'CreateSession', [
        DBusDict.stringVariant({
          'handle_token': DBusString(_nextToken()),
          'session_handle_token': DBusString(_nextToken()),
        }),
      ], replySignature: DBusSignature('o'));
      final resp = await _awaitResponse(create.values[0] as DBusObjectPath);
      if ((resp.values[0] as DBusUint32).value != 0) {
        onError('the desktop refused to create a shortcuts session');
        return;
      }
      final results = (resp.values[1] as DBusDict).mapStringVariant();
      final handle = results['session_handle'];
      _session = handle is DBusObjectPath ? handle : DBusObjectPath((handle as DBusString).value);

      final list = DBusArray(DBusSignature('(sa{sv})'), [
        for (final s in shortcuts)
          DBusStruct([
            DBusString(s.id),
            DBusDict.stringVariant({
              'description': DBusString(s.description),
              if (s.preferredTrigger != null) 'preferred_trigger': DBusString(s.preferredTrigger!),
            }),
          ]),
      ]);
      final bindReq = await _portal.callMethod(_iface, 'BindShortcuts', [
        _session!,
        list,
        const DBusString(''),
        DBusDict.stringVariant({'handle_token': DBusString(_nextToken())}),
      ], replySignature: DBusSignature('o'));
      final bindResp = await _awaitResponse(bindReq.values[0] as DBusObjectPath);
      if ((bindResp.values[0] as DBusUint32).value != 0) {
        onError('shortcut binding was cancelled');
      }
    } on DBusMethodResponseException catch (e) {
      onError(
        e.errorName == 'org.freedesktop.DBus.Error.UnknownMethod' ||
                e.errorName == 'org.freedesktop.DBus.Error.UnknownInterface'
            ? 'not supported by this desktop. Use the evdev backend (Preferences > Hotkeys).'
            : e.toString(),
      );
    } catch (e) {
      onError(e.toString());
    } finally {
      _busy = false;
      final q = _queued;
      _queued = null;
      if (q != null) unawaited(bind(q));
    }
  }

  Future<void> close() async {
    await _closeSession();
    await _responses?.cancel();
    await _activated?.cancel();
    await _bus.close();
  }
}
