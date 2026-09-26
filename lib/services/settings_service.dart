import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const String _clipboardClearSecondsKey = 'clipboard_clear_seconds';

  static const List<int> clipboardClearOptionsSeconds = <int>[
    0,
    15,
    30,
    60,
    300,
  ];

  int _clipboardClearSeconds = 0;

  int get clipboardClearSeconds => _clipboardClearSeconds;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_clipboardClearSecondsKey);

    _clipboardClearSeconds =
        saved != null && clipboardClearOptionsSeconds.contains(saved)
            ? saved
            : 0;
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
}
