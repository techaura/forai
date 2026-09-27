import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../core/vault/vault_repository.dart';
import '../services/external_ui_guard.dart';
import '../services/file_service.dart';
import '../services/language_service.dart';
import '../services/settings_service.dart';
import 'language_scope.dart';
import 'settings_scope.dart';
import 'unlock_page.dart';
import 'wallet_page.dart';

/// Application shell.
///
/// Important: the stateful controller lives *below* MaterialApp. Dialogs and
/// snackbars therefore always receive MaterialLocalizations/ScaffoldMessenger.
class WalletWalleyApp extends StatelessWidget {
  final GlobalKey<_WalletWalleyControllerState> _controllerKey =
      GlobalKey<_WalletWalleyControllerState>();

  final LanguageService languageService;
  final SettingsService settingsService;

  WalletWalleyApp({
    super.key,
    required this.languageService,
    required this.settingsService,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: languageService,
      builder: (context, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,

          title: languageService.productName,

          locale: _localeFromTag(languageService.currentLanguage.locale),

          supportedLocales: [
            for (final language in languageService.languages)
              _localeFromTag(language.locale),
          ],

          localizationsDelegates: GlobalMaterialLocalizations.delegates,

          themeMode: ThemeMode.dark,

          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xff4d8dff),
            useMaterial3: true,
          ),

          builder: (context, child) {
            return _UserActivityBoundary(
              onActivity: () =>
                  _controllerKey.currentState?._registerUserActivity(),
              child: SettingsScope(
                service: settingsService,
                child: LanguageScope(
                  service: languageService,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
          },

          home: _WalletWalleyController(
            key: _controllerKey,
            settingsService: settingsService,
          ),
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

class _UserActivityBoundary extends StatelessWidget {
  final VoidCallback onActivity;
  final Widget child;

  const _UserActivityBoundary({
    required this.onActivity,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) onActivity();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => onActivity(),
        onPointerSignal: (_) => onActivity(),
        child: child,
      ),
    );
  }
}

class _WalletWalleyController extends StatefulWidget {
  final SettingsService settingsService;

  const _WalletWalleyController({
    super.key,
    required this.settingsService,
  });

  @override
  State<_WalletWalleyController> createState() =>
      _WalletWalleyControllerState();
}

class _WalletWalleyControllerState extends State<_WalletWalleyController> {
  final VaultRepository _repository = VaultRepository();

  Timer? _autoLockTimer;
  late final AppLifecycleListener _appLifecycleListener;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  int _sessionGeneration = 0;

  bool _loading = true;
  bool _busy = false;
  bool _hasVault = false;
  String? _error;
  String? _sessionPassword;
  OpenedVault? _opened;

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    widget.settingsService.addListener(_handleSettingsChanged);
    ExternalUiGuard.addListener(_handleExternalUiActivityChanged);
    _appLifecycleListener = AppLifecycleListener(
      onStateChange: _handleAppLifecycleState,
    );
    _probe();
  }

  @override
  void didUpdateWidget(covariant _WalletWalleyController oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settingsService, widget.settingsService)) {
      oldWidget.settingsService.removeListener(_handleSettingsChanged);
      widget.settingsService.addListener(_handleSettingsChanged);
      _restartAutoLockTimer();
    }
  }

  @override
  void dispose() {
    _cancelAutoLockTimer();
    widget.settingsService.removeListener(_handleSettingsChanged);
    ExternalUiGuard.removeListener(_handleExternalUiActivityChanged);
    _appLifecycleListener.dispose();
    super.dispose();
  }

  void _handleSettingsChanged() {
    _restartAutoLockTimer();
  }

  void _handleExternalUiActivityChanged(bool isActive) {
    if (isActive) {
      _cancelAutoLockTimer();
    } else {
      _restartAutoLockTimer();
    }
  }

  void _handleAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;

    switch (state) {
      case AppLifecycleState.resumed:
        _restartAutoLockTimer();
        return;
      case AppLifecycleState.inactive:
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (ExternalUiGuard.isActive) {
          _cancelAutoLockTimer();
          return;
        }
        if (_opened != null || _busy) {
          unawaited(_lock());
        }
        return;
      case AppLifecycleState.detached:
        unawaited(_lock());
        return;
    }
  }

  void _registerUserActivity() {
    if (_opened == null || ExternalUiGuard.isActive) return;
    _restartAutoLockTimer();
  }

  void _cancelAutoLockTimer() {
    _autoLockTimer?.cancel();
    _autoLockTimer = null;
  }

  void _restartAutoLockTimer() {
    _cancelAutoLockTimer();

    if (_opened == null || ExternalUiGuard.isActive) return;
    if (_lifecycleState == AppLifecycleState.hidden ||
        _lifecycleState == AppLifecycleState.paused ||
        _lifecycleState == AppLifecycleState.detached) {
      return;
    }

    final seconds = widget.settingsService.autoLockSeconds;
    if (seconds <= 0) return;

    _autoLockTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || _opened == null || ExternalUiGuard.isActive) return;
      unawaited(_lock());
    });
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
    final operationGeneration = _sessionGeneration;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await action();
      if (!mounted || operationGeneration != _sessionGeneration) return;

      _sessionGeneration++;
      setState(() {
        _opened = opened;
        _hasVault = true;
        if (sessionPassword != null) _sessionPassword = sessionPassword;
      });
      _restartAutoLockTimer();
    } catch (error) {
      if (!mounted || operationGeneration != _sessionGeneration) return;
      setState(() => _error = _friendlyError(error));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyError(error))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final languageService = LanguageScope.of(context);
    final text = error.toString();

    if (text.contains('Wrong password')) {
      return languageService.text('vault.wrongPasswordOrDamaged');
    }
    if (text.contains('Master password must not be empty')) {
      return languageService.text('vault.masterPasswordEmpty');
    }
    if (text.contains('Local KeyWallet vault does not exist')) {
      return languageService.text('vault.localVaultMissing');
    }
    if (text.contains('Vault is not unlocked')) {
      return languageService.text('vault.notUnlocked');
    }

    return text;
  }

  Future<void> _unlock(String password) {
    return _run(() => _repository.unlock(password), sessionPassword: password);
  }

  Future<void> _create(String password) {
    return _run(() => _repository.create(password), sessionPassword: password);
  }

  Future<void> _import(String password) async {
    final languageService = LanguageScope.of(context);

    if (password.isEmpty) {
      setState(
        () => _error = languageService.text('vault.passwordBeforeImport'),
      );
      return;
    }

    final picked = await FileService.pickVault(
      dialogTitle: languageService.text('fileDialogs.importVault'),
    );
    if (picked == null) return;
    await _run(
      () => _repository.importPortable(picked.bytes, password),
      sessionPassword: password,
    );
  }

  Future<void> _export() async {
    final languageService = LanguageScope.of(context);

    try {
      final Uint8List raw = await _repository.readRaw();
      await FileService.saveVault(
        raw,
        dialogTitle: languageService.text('fileDialogs.exportVault'),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(languageService.text('vault.exported'))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            languageService.text(
              'vault.exportFailed',
              parameters: {'error': error},
            ),
          ),
        ),
      );
    }
  }

  Future<void> _importFromWorkspace() async {
    final languageService = LanguageScope.of(context);
    final picked = await FileService.pickVault(
      dialogTitle: languageService.text('fileDialogs.importVault'),
    );
    if (picked == null || !mounted) return;
    await _importPickedVault(picked);
  }

  Future<void> _importPickedVault(PickedVaultFile picked) async {
    if (!mounted) return;

    final languageService = LanguageScope.of(context);
    final password = await _askPassword(
      title: languageService.text(
        'vault.importTitle',
        parameters: {'fileName': picked.name},
      ),
      message: languageService.text('vault.importReplaceWarning'),
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
    final languageService = LanguageScope.of(context);
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
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
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
                            labelText: languageService.text(
                              'vault.importPassword',
                            ),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              onPressed:
                                  () =>
                                      setDialogState(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                            ),
                          ),
                          onFieldSubmitted:
                              (_) => Navigator.of(dialogContext).pop(password),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(languageService.text('common.cancel')),
                    ),
                    FilledButton(
                      onPressed:
                          () => Navigator.of(dialogContext).pop(password),
                      child: Text(languageService.text('common.import')),
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

    final sessionGeneration = _sessionGeneration;
    final saved = await _repository.save(
      vault: opened.vault,
      password: password,
      previousRevision: opened.revision,
    );
    if (!mounted ||
        sessionGeneration != _sessionGeneration ||
        !identical(_opened, opened)) {
      return;
    }

    setState(() => _opened = saved);
    _restartAutoLockTimer();
  }

  Future<void> _lock() async {
    if (!mounted) return;

    _cancelAutoLockTimer();
    _sessionGeneration++;

    if (_opened == null && _sessionPassword == null) return;

    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    if (!mounted) return;

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
