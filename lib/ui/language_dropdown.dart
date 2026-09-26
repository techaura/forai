import 'package:flutter/material.dart';

import 'language_scope.dart';

class LanguageDropdown extends StatelessWidget {
  const LanguageDropdown({super.key});

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(languageService.text('language.label')),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: languageService.currentLanguageCode,
          isDense: true,
          items: [
            for (final language in languageService.languages)
              DropdownMenuItem<String>(
                value: language.code,
                child: Text(language.name),
              ),
          ],
          onChanged: (code) async {
            if (code == null) return;
            await languageService.setLanguage(code);
          },
        ),
      ],
    );
  }
}
