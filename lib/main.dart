import 'package:flutter/material.dart';

import 'services/language_service.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final languageService = LanguageService();
  await languageService.load();

  runApp(
    WalletWalleyApp(
      languageService: languageService,
    ),
  );
}
