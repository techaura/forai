import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../core/vault/vault_repository.dart';
import '../services/file_service.dart';
import '../services/language_service.dart';
import 'language_scope.dart';
import 'unlock_page.dart';
import 'wallet_page.dart';



/// Application shell.
///
/// Important: the stateful controller lives *below* MaterialApp. Dialogs and
/// snackbars therefore always receive MaterialLocalizations/ScaffoldMessenger.
class WalletWalleyApp extends StatelessWidget {
  final LanguageService languageService;

  const WalletWalleyApp({
    super.key,
    required this.languageService,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: languageService,
      builder: (context, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,

          title: languageService.productName,

          locale: _localeFromTag(
            languageService.currentLanguage.locale,
          ),

          supportedLocales: [
            for (final language in languageService.languages)
              _localeFromTag(language.locale),
          ],

          localizationsDelegates:
          GlobalMaterialLocalizations.delegates,

          themeMode: ThemeMode.dark,

          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xff4d8dff),
            useMaterial3: true,
          ),

          builder: (context, child) {
            return LanguageScope(
              service: languageService,
              child: child ?? const SizedBox.shrink(),
            );
          },

          home: const _WalletWalleyController(),
        );
      },
    );
  }

  Locale _localeFromTag(String tag) {
    final parts = tag.replaceAll('_', '-').split('-');

    final languageCode = parts.first;

    String? scriptCode;
    String? countryCode;

    if (parts.length >= 2) {
      if (parts[1].length == 4) {
        scriptCode = parts[1];
      } else {
        countryCode = parts[1];
      }
    }

    if (parts.length >= 3) {
      countryCode = parts[2];
    }

    return Locale.fromSubtags(
      languageCode: languageCode,
      scriptCode: scriptCode,
      countryCode: countryCode,
    );
  }
}

class _WalletWalleyController extends StatefulWidget {
  const _WalletWalleyController();

  @override
  State<_WalletWalleyController> createState() => _WalletWalleyControllerState();
}

class _WalletWalleyControllerState
    extends State<_WalletWalleyController> {
  final VaultRepository _repository = VaultRepository();

  bool _loading = true;
  bool _busy = false;
  bool _hasVault = false;
  String? _error;
  String? _sessionPassword;
  OpenedVault? _opened;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    try {
      final exists = await _repository.exists();
      if (!mounted) return;
      setState(() {
        _hasVault = exists;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _run(
    Future<OpenedVault> Function() action, {
    String? sessionPassword,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await action();
      if (!mounted) return;
      setState(() {
        _opened = opened;
        _hasVault = true;
        if (sessionPassword != null) _sessionPassword = sessionPassword;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('Wrong password')) {
      return 'Wrong password or damaged vault.';
    }
    return text;
  }

  Future<void> _unlock(String password) {
    return _run(
      () => _repository.unlock(password),
      sessionPassword: password,
    );
  }

  Future<void> _create(String password) {
    return _run(
      () => _repository.create(password),
      sessionPassword: password,
    );
  }

  Future<void> _import(String password) async {
    if (password.isEmpty) {
      setState(() => _error = 'Enter the password of the .kwvault first.');
      return;
    }
    final picked = await FileService.pickVault();
    if (picked == null) return;
    await _run(
      () => _repository.importPortable(picked.bytes, password),
      sessionPassword: password,
    );
  }

  Future<void> _export() async {
    try {
      final Uint8List raw = await _repository.readRaw();
      await FileService.saveVault(raw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Encrypted vault exported')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $error')),
      );
    }
  }

  Future<void> _importFromWorkspace() async {
    final picked = await FileService.pickVault();
    if (picked == null || !mounted) return;
    await _importPickedVault(picked);
  }

  Future<void> _importPickedVault(PickedVaultFile picked) async {
    if (!mounted) return;
    final password = await _askPassword(
      title: 'Import ${picked.name}',
      message: 'This replaces the local vault only after the imported file is successfully decrypted and validated.',
    );
    if (password == null || password.isEmpty) return;

    await _run(
      () => _repository.importPortable(picked.bytes, password),
      sessionPassword: password,
    );
  }

  Future<String?> _askPassword({
    required String title,
    required String message,
  }) async {
    // Do not create/dispose a TextEditingController around showDialog().
    // showDialog's Future completes when Navigator.pop() is called, while the
    // dialog route may still be rebuilding during its exit animation. Disposing
    // the controller immediately can therefore leave the fading TextField with
    // a disposed controller. Keep only the current text value here instead.
    var password = '';
    var obscure = true;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                const SizedBox(height: 16),
                TextFormField(
                  autofocus: true,
                  obscureText: obscure,
                  onChanged: (value) => password = value,
                  decoration: InputDecoration(
                    labelText: 'Master password of imported vault',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(() => obscure = !obscure),
                      icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                    ),
                  ),
                  onFieldSubmitted: (_) => Navigator.of(dialogContext).pop(password),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(password),
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _persistOpenedVault() async {
    final opened = _opened;
    final password = _sessionPassword;
    if (opened == null || password == null) {
      throw StateError('Vault is not unlocked');
    }

    final saved = await _repository.save(
      vault: opened.vault,
      password: password,
      previousRevision: opened.revision,
    );
    if (!mounted) return;
    setState(() => _opened = saved);
  }

  Future<void> _lock() async {
    setState(() {
      _opened = null;
      _sessionPassword = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_opened == null) {
      return UnlockPage(
        hasVault: _hasVault,
        busy: _busy,
        error: _error,
        onUnlock: _unlock,
        onCreate: _create,
        onImport: _import,
      );
    }

    return WalletPage(
      vault: _opened!.vault,
      revision: _opened!.revision,
      iterations: _opened!.iterations,
      onLock: _lock,
      onExportVault: _export,
      onImportVault: _importFromWorkspace,
      onImportPickedVault: _importPickedVault,
      onPersist: _persistOpenedVault,
    );
  }
}
