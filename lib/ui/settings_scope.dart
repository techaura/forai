import 'package:flutter/widgets.dart';

import '../services/settings_service.dart';

class SettingsScope extends InheritedNotifier<SettingsService> {
  const SettingsScope({
    super.key,
    required SettingsService service,
    required super.child,
  }) : super(notifier: service);

  static SettingsService of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'SettingsScope is missing');
    return scope!.notifier!;
  }
}
