typedef ExternalUiActivityChanged = void Function(bool isActive);

class ExternalUiGuard {
  static int _depth = 0;
  static final Set<ExternalUiActivityChanged> _listeners =
      <ExternalUiActivityChanged>{};

  static bool get isActive => _depth > 0;

  static void addListener(ExternalUiActivityChanged listener) {
    _listeners.add(listener);
  }

  static void removeListener(ExternalUiActivityChanged listener) {
    _listeners.remove(listener);
  }

  static Future<T> run<T>(Future<T> Function() action) async {
    _depth++;
    if (_depth == 1) _notify();
    try {
      return await action();
    } finally {
      if (_depth > 0) _depth--;
      if (_depth == 0) _notify();
    }
  }

  static void _notify() {
    final active = isActive;
    for (final listener in List<ExternalUiActivityChanged>.of(_listeners)) {
      listener(active);
    }
  }
}
