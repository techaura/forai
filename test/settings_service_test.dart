import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:keywallet_multios/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('clipboard clear policy defaults to Never', () async {
    final service = SettingsService();

    await service.load();

    expect(service.clipboardClearSeconds, 0);
  });

  test('clipboard clear policy persists a supported timeout', () async {
    final first = SettingsService();
    await first.load();
    await first.setClipboardClearSeconds(30);

    final second = SettingsService();
    await second.load();

    expect(second.clipboardClearSeconds, 30);
  });

  test('clipboard clear policy rejects unsupported timeout', () async {
    final service = SettingsService();
    await service.load();

    await expectLater(
      service.setClipboardClearSeconds(17),
      throwsArgumentError,
    );
  });
}
