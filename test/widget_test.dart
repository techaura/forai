// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/services/language_service.dart';
import 'package:keywallet_multios/ui/app.dart';

void main() {
  test('WalletWalleyApp can be constructed', () {
    final app = WalletWalleyApp(
      languageService: LanguageService(),
    );

    expect(app, isNotNull);
  });
}
