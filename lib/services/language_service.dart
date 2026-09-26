import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLanguage {
  final String code;
  final String name;
  final String locale;
  final Map<String, dynamic> strings;

  const AppLanguage({
    required this.code,
    required this.name,
    required this.locale,
    required this.strings,
  });
}

class LanguageService extends ChangeNotifier {
  static const String _assetPath = 'assets/i18n/languages.json';
  static const String _preferenceKey = 'language_code';

  late String productName;
  late String defaultLanguage;
  late String fallbackLanguage;

  final Map<String, AppLanguage> _languages = {};

  String? _currentLanguageCode;

  bool get isLoaded => _currentLanguageCode != null;

  String get currentLanguageCode {
    final code = _currentLanguageCode;
    if (code == null) {
      throw StateError('LanguageService is not loaded');
    }
    return code;
  }

  AppLanguage get currentLanguage => _languages[currentLanguageCode]!;

  List<AppLanguage> get languages => List.unmodifiable(_languages.values);

  Future<void> load() async {
    final raw = await rootBundle.loadString(_assetPath);
    final json = jsonDecode(raw);

    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid language file root');
    }

    final product = json['product'];
    if (product is! Map<String, dynamic>) {
      throw const FormatException('Missing product section');
    }

    productName = product['name']?.toString() ?? 'WalletWalley';

    defaultLanguage = json['defaultLanguage']?.toString() ?? 'ua';
    fallbackLanguage = json['fallbackLanguage']?.toString() ?? 'en';

    final languagesJson = json['languages'];
    if (languagesJson is! Map<String, dynamic>) {
      throw const FormatException('Missing languages section');
    }

    _languages.clear();

    for (final entry in languagesJson.entries) {
      final code = entry.key;
      final value = entry.value;

      if (value is! Map<String, dynamic>) {
        continue;
      }

      final strings = value['strings'];

      if (strings is! Map<String, dynamic>) {
        continue;
      }

      _languages[code] = AppLanguage(
        code: code,
        name: value['name']?.toString() ?? code,
        locale: value['locale']?.toString() ?? code,
        strings: strings,
      );
    }

    if (_languages.isEmpty) {
      throw const FormatException('No languages found');
    }

    if (!_languages.containsKey(defaultLanguage)) {
      throw FormatException(
        'Default language "$defaultLanguage" does not exist',
      );
    }

    if (!_languages.containsKey(fallbackLanguage)) {
      throw FormatException(
        'Fallback language "$fallbackLanguage" does not exist',
      );
    }

    _validateLanguageSchemas();

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_preferenceKey);

    if (saved != null && _languages.containsKey(saved)) {
      _currentLanguageCode = saved;
    } else {
      _currentLanguageCode = defaultLanguage;
    }

    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    if (!_languages.containsKey(code)) {
      throw ArgumentError.value(code, 'code', 'Unknown language');
    }

    if (_currentLanguageCode == code) {
      return;
    }

    _currentLanguageCode = code;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferenceKey, code);

    notifyListeners();
  }

  String text(
      String key, {
        Map<String, Object?> parameters = const {},
      }) {
    var value = _lookup(
      _languages[currentLanguageCode]!.strings,
      key,
    );

    value ??= _lookup(
      _languages[fallbackLanguage]!.strings,
      key,
    );

    if (value == null) {
      return '[$key]';
    }

    var result = value;

    for (final entry in parameters.entries) {
      result = result.replaceAll(
        '{${entry.key}}',
        entry.value?.toString() ?? '',
      );
    }

    result = result.replaceAll('{appName}', productName);

    return result;
  }

  String? _lookup(
      Map<String, dynamic> root,
      String key,
      ) {
    dynamic current = root;

    for (final part in key.split('.')) {
      if (current is! Map<String, dynamic>) {
        return null;
      }

      current = current[part];

      if (current == null) {
        return null;
      }
    }

    return current is String ? current : null;
  }

  void _validateLanguageSchemas() {
    final reference =
    _flattenKeys(_languages[fallbackLanguage]!.strings).toSet();

    for (final language in _languages.values) {
      final keys = _flattenKeys(language.strings).toSet();

      final missing = reference.difference(keys);
      final extra = keys.difference(reference);

      if (missing.isNotEmpty || extra.isNotEmpty) {
        throw FormatException(
          'Language "${language.code}" has incompatible schema. '
              'Missing: ${missing.join(', ')}; '
              'Extra: ${extra.join(', ')}',
        );
      }
    }
  }

  List<String> _flattenKeys(
      Map<String, dynamic> root, [
        String prefix = '',
      ]) {
    final result = <String>[];

    for (final entry in root.entries) {
      final key = prefix.isEmpty
          ? entry.key
          : '$prefix.${entry.key}';

      if (entry.value is Map<String, dynamic>) {
        result.addAll(
          _flattenKeys(
            entry.value as Map<String, dynamic>,
            key,
          ),
        );
      } else if (entry.value is String) {
        result.add(key);
      }
    }

    return result;
  }
}