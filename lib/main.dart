import 'package:flutter/material.dart';

import 'services/language_service.dart';
import 'services/settings_service.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final languageService = LanguageService();
  final settingsService = SettingsService();

  await languageService.load();
  await settingsService.load();

  runApp(
    WalletWalleyApp(
      languageService: languageService,
      settingsService: settingsService,
    ),
  );
}
