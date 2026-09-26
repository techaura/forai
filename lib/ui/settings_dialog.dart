import 'package:flutter/material.dart';

import '../services/language_service.dart';
import '../services/settings_service.dart';
import 'language_dropdown.dart';
import 'language_scope.dart';
import 'settings_scope.dart';

Future<void> showSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);
    final settingsService = SettingsScope.of(context);

    return AlertDialog(
      title: Text(languageService.text('settings.title')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LanguageDropdown(),
            const SizedBox(height: 24),
            Text(
              languageService.text('settings.clipboard'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: settingsService.clipboardClearSeconds,
              decoration: InputDecoration(
                labelText: languageService.text(
                  'settings.clipboardClearPolicy',
                ),
                helperText: languageService.text('settings.clipboardHelp'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final seconds
                    in SettingsService.clipboardClearOptionsSeconds)
                  DropdownMenuItem<int>(
                    value: seconds,
                    child: Text(
                      _clipboardTimeoutLabel(languageService, seconds),
                    ),
                  ),
              ],
              onChanged: (seconds) async {
                if (seconds == null) return;
                await settingsService.setClipboardClearSeconds(seconds);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(languageService.text('common.ok')),
        ),
      ],
    );
  }

  String _clipboardTimeoutLabel(LanguageService languageService, int seconds) {
    return switch (seconds) {
      0 => languageService.text('settings.clipboardNever'),
      15 => languageService.text('settings.clipboard15Seconds'),
      30 => languageService.text('settings.clipboard30Seconds'),
      60 => languageService.text('settings.clipboard1Minute'),
      300 => languageService.text('settings.clipboard5Minutes'),
      _ => seconds.toString(),
    };
  }
}
