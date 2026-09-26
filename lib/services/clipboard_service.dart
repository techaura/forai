import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'settings_service.dart';

class ClipboardService {
  static const _androidClipboardChannel = MethodChannel(
    'com.steppefort.keywallet_multios/clipboard',
  );

  static final _sha256 = Sha256();
  static final _lifecycleObserver = _ClipboardLifecycleObserver();

  static SettingsService? _settingsService;
  static Timer? _clearTimer;
  static String? _ownedFingerprint;
  static bool _observingLifecycle = false;
  static bool _isResumed = true;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
    final trackForClear = timeoutSeconds > 0;
    final fingerprint =
        !_isAndroid && trackForClear ? await _fingerprint(value) : null;

    final copied = await _writeClipboardText(
      value,
      sensitive: _isAndroid,
      trackForClear: trackForClear,
    );

    _clearTimer?.cancel();
    _clearTimer = null;
    _ownedFingerprint = _isAndroid ? null : (copied ? fingerprint : null);

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

      if (_isAndroid) {
        unawaited(_disableAndroidOwnedClear());
      }
      return;
    }

    if (!_isResumed && _ownedFingerprint != null) {
      _scheduleClear();
    }
  }

  static void _handleLifecycleState(AppLifecycleState state) {
    final nowResumed = state == AppLifecycleState.resumed;

    if (_isAndroid) {
      _isResumed = nowResumed;

      if (!nowResumed) {
        _clearTimer?.cancel();
        _clearTimer = null;
      }

      return;
    }

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

    if (_isAndroid) {
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

    final current = await _readClipboardText();
    if (!current.success) {
      return;
    }

    final currentText = current.text;

    if (_ownedFingerprint != expectedFingerprint) {
      return;
    }

    if (currentText == null ||
        await _fingerprint(currentText) != expectedFingerprint) {
      _ownedFingerprint = null;
      return;
    }

    final latest = await _readClipboardText();
    if (!latest.success) {
      return;
    }

    final latestText = latest.text;

    if (_ownedFingerprint != expectedFingerprint) {
      return;
    }

    if (latestText == null ||
        await _fingerprint(latestText) != expectedFingerprint) {
      _ownedFingerprint = null;
      return;
    }

    final cleared = await _writeClipboardText('', sensitive: false);

    if (cleared && _ownedFingerprint == expectedFingerprint) {
      _ownedFingerprint = null;
    }
  }

  static Future<_ClipboardReadResult> _readClipboardText() async {
    try {
      final data = await Clipboard.getData('text/plain');
      return _ClipboardReadResult(success: true, text: data?.text);
    } on PlatformException catch (error) {
      debugPrint('Clipboard read failed: ${error.code}: ${error.message}');
      return const _ClipboardReadResult(success: false);
    } on MissingPluginException catch (error) {
      debugPrint('Clipboard read plugin missing: $error');
      return const _ClipboardReadResult(success: false);
    }
  }

  static Future<bool> _writeClipboardText(
    String value, {
    required bool sensitive,
    bool trackForClear = false,
  }) async {
    if (_isAndroid && sensitive) {
      try {
        await _androidClipboardChannel.invokeMethod<void>(
          'setSensitiveText',
          <String, Object?>{'text': value, 'trackForClear': trackForClear},
        );
        return true;
      } on PlatformException catch (error) {
        debugPrint(
          'Sensitive Android clipboard write failed: '
          '${error.code}: ${error.message}',
        );
      } on MissingPluginException catch (error) {
        debugPrint('Sensitive Android clipboard plugin missing: $error');
      }
    }

    try {
      await Clipboard.setData(ClipboardData(text: value));
      return true;
    } on PlatformException catch (error) {
      debugPrint('Clipboard write failed: ${error.code}: ${error.message}');
      return false;
    } on MissingPluginException catch (error) {
      debugPrint('Clipboard write plugin missing: $error');
      return false;
    }
  }

  static Future<void> _disableAndroidOwnedClear() async {
    try {
      await _androidClipboardChannel.invokeMethod<void>('disableOwnedClear');
    } on PlatformException catch (error) {
      debugPrint(
        'Android clipboard clear tracking disable failed: '
        '${error.code}: ${error.message}',
      );
    } on MissingPluginException catch (error) {
      debugPrint('Android clipboard plugin missing: $error');
    }
  }

  static Future<String> _fingerprint(String value) async {
    final hash = await _sha256.hash(utf8.encode(value));
    return base64Encode(hash.bytes);
  }
}

class _ClipboardReadResult {
  final bool success;
  final String? text;

  const _ClipboardReadResult({required this.success, this.text});
}

class _ClipboardLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ClipboardService._handleLifecycleState(state);
  }
}
