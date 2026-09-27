import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const int defaultClipboardClearSeconds = 0;
  static const int defaultAutoLockSeconds = 60;

  static const String _clipboardClearSecondsKey = 'clipboard_clear_seconds';
  static const String _autoLockSecondsKey = 'auto_lock_seconds';

  static const List<int> clipboardClearOptionsSeconds = <int>[
    0,
    15,
    30,
    60,
    300,
  ];

  static const List<int> autoLockOptionsSeconds = <int>[
    0,
    60,
    300,
    900,
    1800,
    3600,
  ];

  int _clipboardClearSeconds = defaultClipboardClearSeconds;
  int _autoLockSeconds = defaultAutoLockSeconds;

  int get clipboardClearSeconds => _clipboardClearSeconds;
  int get autoLockSeconds => _autoLockSeconds;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedClipboardClearSeconds = prefs.getInt(_clipboardClearSecondsKey);
    final savedAutoLockSeconds = prefs.getInt(_autoLockSecondsKey);

    _clipboardClearSeconds =
        savedClipboardClearSeconds != null &&
                clipboardClearOptionsSeconds.contains(savedClipboardClearSeconds)
            ? savedClipboardClearSeconds
            : defaultClipboardClearSeconds;

    _autoLockSeconds =
        savedAutoLockSeconds != null &&
                autoLockOptionsSeconds.contains(savedAutoLockSeconds)
            ? savedAutoLockSeconds
            : defaultAutoLockSeconds;
  }

  Future<void> setClipboardClearSeconds(int seconds) async {
    if (!clipboardClearOptionsSeconds.contains(seconds)) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        'Unsupported clipboard clear timeout',
      );
    }

    if (_clipboardClearSeconds == seconds) {
      return;
    }

    _clipboardClearSeconds = seconds;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_clipboardClearSecondsKey, seconds);

    notifyListeners();
  }

  Future<void> setAutoLockSeconds(int seconds) async {
    if (!autoLockOptionsSeconds.contains(seconds)) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        'Unsupported auto-lock timeout',
      );
    }

    if (_autoLockSeconds == seconds) {
      return;
    }

    _autoLockSeconds = seconds;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoLockSecondsKey, seconds);

    notifyListeners();
  }
}
