import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'settings_service.dart';

class ClipboardService {
  static final _sha256 = Sha256();
  static final _lifecycleObserver = _ClipboardLifecycleObserver();

  static SettingsService? _settingsService;
  static Timer? _clearTimer;
  static String? _ownedFingerprint;
  static bool _observingLifecycle = false;
  static bool _isResumed = true;

  static void initialize(SettingsService settingsService) {
    if (!identical(_settingsService, settingsService)) {
      _settingsService?.removeListener(_onSettingsChanged);
      _settingsService = settingsService;
      settingsService.addListener(_onSettingsChanged);
    }

    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(_lifecycleObserver);
      _observingLifecycle = true;
    }

    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isResumed =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;

    _onSettingsChanged();
  }

  static Future<void> copyText(String value) async {
    final timeoutSeconds = _settingsService?.clipboardClearSeconds ?? 0;
    final fingerprint = timeoutSeconds > 0 ? await _fingerprint(value) : null;

    await Clipboard.setData(ClipboardData(text: value));

    _clearTimer?.cancel();
    _clearTimer = null;
    _ownedFingerprint = fingerprint;

    if (!_isResumed && fingerprint != null) {
      _scheduleClear();
    }
  }

  static void _onSettingsChanged() {
    final timeoutSeconds = _settingsService?.clipboardClearSeconds ?? 0;

    if (timeoutSeconds <= 0) {
      _clearTimer?.cancel();
      _clearTimer = null;
      _ownedFingerprint = null;
      return;
    }

    if (!_isResumed && _ownedFingerprint != null) {
      _scheduleClear();
    }
  }

  static void _handleLifecycleState(AppLifecycleState state) {
    final nowResumed = state == AppLifecycleState.resumed;

    if (nowResumed == _isResumed) {
      return;
    }

    final wasResumed = _isResumed;
    _isResumed = nowResumed;

    if (wasResumed && !nowResumed) {
      _scheduleClear();
      return;
    }

    if (!wasResumed && nowResumed) {
      _clearTimer?.cancel();
      _clearTimer = null;

      if ((_settingsService?.clipboardClearSeconds ?? 0) > 0 &&
          _ownedFingerprint != null) {
        unawaited(_clearIfOwned());
      }
    }
  }

  static void _scheduleClear() {
    _clearTimer?.cancel();
    _clearTimer = null;

    final timeoutSeconds = _settingsService?.clipboardClearSeconds ?? 0;

    if (timeoutSeconds <= 0 || _ownedFingerprint == null) {
      return;
    }

    _clearTimer = Timer(
      Duration(seconds: timeoutSeconds),
      () => unawaited(_clearIfOwned()),
    );
  }

  static Future<void> _clearIfOwned() async {
    _clearTimer?.cancel();
    _clearTimer = null;

    final expectedFingerprint = _ownedFingerprint;
    if (expectedFingerprint == null) {
      return;
    }

    final current = await Clipboard.getData('text/plain');
    final currentText = current?.text;

    // A newer WalletWalley copy happened while the clipboard was being read.
    if (_ownedFingerprint != expectedFingerprint) {
      return;
    }

    if (currentText == null ||
        await _fingerprint(currentText) != expectedFingerprint) {
      // Clipboard no longer contains the value WalletWalley copied.
      _ownedFingerprint = null;
      return;
    }

    // Re-read immediately before clearing to reduce the chance of overwriting
    // a clipboard value that another application placed there meanwhile.
    final latest = await Clipboard.getData('text/plain');
    final latestText = latest?.text;

    if (_ownedFingerprint != expectedFingerprint) {
      return;
    }

    if (latestText == null ||
        await _fingerprint(latestText) != expectedFingerprint) {
      _ownedFingerprint = null;
      return;
    }

    await Clipboard.setData(const ClipboardData(text: ''));

    if (_ownedFingerprint == expectedFingerprint) {
      _ownedFingerprint = null;
    }
  }

  static Future<String> _fingerprint(String value) async {
    final hash = await _sha256.hash(utf8.encode(value));
    return base64Encode(hash.bytes);
  }
}

class _ClipboardLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ClipboardService._handleLifecycleState(state);
  }
}
