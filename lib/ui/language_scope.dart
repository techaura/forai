import 'package:flutter/widgets.dart';

import '../services/language_service.dart';

class LanguageScope extends InheritedNotifier<LanguageService> {
  const LanguageScope({
    super.key,
    required LanguageService service,
    required super.child,
  }) : super(notifier: service);

  static LanguageService of(BuildContext context) {
    final scope =
    context.dependOnInheritedWidgetOfExactType<LanguageScope>();

    if (scope == null || scope.notifier == null) {
      throw StateError('LanguageScope is not available');
    }

    return scope.notifier!;
  }
}
