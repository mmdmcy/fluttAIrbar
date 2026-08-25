import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/usage_store.dart';

class TrayController with TrayListener, WindowListener {
  TrayController(this.store);

  final UsageStore store;
  bool _initialized = false;
  bool _trayReady = false;

  Future<void> init({bool startHidden = false}) async {
    if (_initialized) return;
    _initialized = true;

    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(400, 420),
      minimumSize: Size(360, 380),
      maximumSize: Size(520, 520),
      center: true,
      title: 'fluttAIrbar',
      titleBarStyle: TitleBarStyle.normal,
      skipTaskbar: true,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setPreventClose(true);
      if (startHidden) {
        await windowManager.hide();
        return;
      }
      await windowManager.show();
      await windowManager.focus();
    });

    windowManager.addListener(this);
    store.addListener(_onStoreChanged);

    try {
      trayManager.addListener(this);
      final iconPath = await _resolveTrayIcon();
      await trayManager.setIcon(iconPath);
      // setToolTip is not implemented on Linux tray_manager — ignore failures.
      await _safeTray(() => trayManager.setToolTip('fluttAIrbar'));
      await _rebuildMenu();
      _trayReady = true;
    } catch (e) {
      stderr.writeln('fluttAIrbar: tray unavailable: $e');
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    }
  }

  Future<void> _safeTray(Future<void> Function() action) async {
    try {
      await action();
    } on MissingPluginException {
      // Platform stub (e.g. Linux setToolTip).
    } catch (_) {}
  }

  Future<String> _resolveTrayIcon() async {
    final data = await rootBundle.load('assets/tray_icon.png');
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'fluttairbar_tray.png'));
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  void _onStoreChanged() {
    if (!_trayReady) return;
    unawaited(_updateTrayLabel());
    unawaited(_rebuildMenu());
  }

  Future<void> _updateTrayLabel() async {
    await _safeTray(() => trayManager.setToolTip(store.snapshot.trayTooltip));
    await _safeTray(() => trayManager.setTitle(store.snapshot.trayTitle));
  }

  Future<void> _rebuildMenu() async {
    if (!_trayReady && !_initialized) return;
    final snap = store.snapshot;
    final cursorPct = snap.cursor?.usedPercent;
    final resets = snap.codex?.availableResetCount ?? 0;

    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open fluttAIrbar'),
            MenuItem.separator(),
            MenuItem(
              key: 'codex',
              label: () {
                final w = snap.codex?.secondary ?? snap.codex?.primary;
                if (w == null) return 'Codex · —';
                final label = w.label ?? 'Codex';
                final left = (100 - w.usedPercent).clamp(0, 100).round();
                return '$label · $left% left';
              }(),
              disabled: true,
            ),
            MenuItem(
              key: 'resets',
              label: 'Resets · $resets available',
              disabled: true,
            ),
            MenuItem(
              key: 'cursor',
              label: cursorPct != null
                  ? 'Cursor · ${(100 - cursorPct).clamp(0, 100).round()}% left'
                  : 'Cursor · —',
              disabled: true,
            ),
            MenuItem.separator(),
            MenuItem(key: 'refresh', label: 'Refresh'),
            MenuItem(key: 'quit', label: 'Quit'),
          ],
        ),
      );
    } catch (_) {}
  }

  Future<void> showPanel() async {
    // Cinnamon can leave a hidden GTK window behind the active application
    // when this method is called from the AppIndicator D-Bus menu. Temporarily
    // raise it above other windows so the tray action behaves like a launcher.
    final shouldRaise = Platform.isLinux;
    try {
      await windowManager.show();
      if (shouldRaise) {
        await windowManager.setAlwaysOnTop(true);
      }
      await windowManager.focus();
      if (shouldRaise) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      if (shouldRaise) {
        await windowManager.setAlwaysOnTop(false);
      }
    }
  }

  Future<void> hidePanel() async {
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showPanel());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == 'show') {
      unawaited(showPanel());
    } else if (key == 'refresh') {
      unawaited(store.refresh());
    } else if (key == 'quit') {
      unawaited(_quit());
    }
  }

  @override
  void onWindowClose() {
    if (_trayReady) {
      unawaited(hidePanel());
    } else {
      exit(0);
    }
  }

  Future<void> _quit() async {
    store.removeListener(_onStoreChanged);
    if (_trayReady) {
      trayManager.removeListener(this);
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
    windowManager.removeListener(this);
    await windowManager.destroy();
    exit(0);
  }

  void dispose() {
    store.removeListener(_onStoreChanged);
    if (_trayReady) trayManager.removeListener(this);
    windowManager.removeListener(this);
  }
}
