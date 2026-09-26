import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/crypto/key_generators.dart';
import '../core/crypto/kwvlock.dart';
import '../core/vault/vault.dart';
import '../core/vault/vault_node.dart';
import '../services/clipboard_service.dart';
import '../services/file_service.dart';
import '../services/lock_file_service.dart';
import 'settings_dialog.dart';
import 'language_scope.dart';

class WalletPage extends StatefulWidget {
  final Vault vault;
  final int revision;
  final int iterations;
  final Future<void> Function() onLock;
  final Future<void> Function() onExportVault;
  final Future<void> Function() onImportVault;
  final Future<void> Function(PickedVaultFile picked) onImportPickedVault;
  final Future<void> Function() onPersist;

  const WalletPage({
    super.key,
    required this.vault,
    required this.revision,
    required this.iterations,
    required this.onLock,
    required this.onExportVault,
    required this.onImportVault,
    required this.onImportPickedVault,
    required this.onPersist,
  });

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  VaultNode? _selected;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant WalletPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.vault, widget.vault)) {
      _selected = null;
    }
  }

  VaultNode get _selectedNode => _selected ?? widget.vault.root;

  VaultNode _targetGroup() {
    final selected = _selectedNode;
    if (selected.isGroup) return selected;
    return _findParent(widget.vault.root, selected) ?? widget.vault.root;
  }

  VaultNode? _findParent(VaultNode current, VaultNode target) {
    for (final child in current.children) {
      if (identical(child, target)) return current;
      if (child.isGroup) {
        final found = _findParent(child, target);
        if (found != null) return found;
      }
    }
    return null;
  }

  String _newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await widget.onPersist();
      if (!mounted) return;
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      final languageService = LanguageScope.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            languageService.text(
              'wallet.operationFailed',
              parameters: {'error': error},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askSingleLine({
    required String title,
    required String label,
    String initial = '',
  }) async {
    final languageService = LanguageScope.of(context);
    var value = initial;
    return showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 440,
              child: TextFormField(
                initialValue: initial,
                autofocus: true,
                onChanged: (text) => value = text,
                decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted:
                    (_) => Navigator.of(dialogContext).pop(value.trim()),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(languageService.text('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(value.trim()),
                child: Text(languageService.text('common.ok')),
              ),
            ],
          ),
    );
  }

  Future<void> _addGroup() async {
    final languageService = LanguageScope.of(context);
    final name = await _askSingleLine(
      title: languageService.text('groupEditor.newTitle'),
      label: languageService.text('groupEditor.nameLabel'),
    );
    if (name == null || name.isEmpty) return;
    final group = VaultNode(id: _newId('group'), name: name, type: 'group');
    await _mutate(() async {
      _targetGroup().children.add(group);
      _selected = group;
    });
  }

  Future<void> _addText() async {
    final languageService = LanguageScope.of(context);
    var name = languageService.text('common.text');
    var text = '';
    final result = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(languageService.text('secretEditor.newTitle')),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: name,
                    autofocus: true,
                    onChanged: (value) => name = value,
                    decoration: InputDecoration(
                      labelText: languageService.text('secretEditor.nameLabel'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    minLines: 5,
                    maxLines: 12,
                    onChanged: (value) => text = value,
                    decoration: InputDecoration(
                      labelText: languageService.text('secretEditor.textLabel'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(languageService.text('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(languageService.text('common.save')),
              ),
            ],
          ),
    );

    name = name.trim();
    if (result != true || name.isEmpty) return;

    final entry = VaultNode(
      id: _newId('text'),
      name: name,
      type: 'entry',
      kind: 'text',
      files: [
        VaultArtifact(
          name: 'text.txt',
          data: Uint8List.fromList(utf8.encode(text)),
          contentType: 'text/plain',
        ),
      ],
    );

    await _mutate(() async {
      _targetGroup().children.add(entry);
      _selected = entry;
    });
  }

  Future<void> _addKey() async {
    final request = await showDialog<_KeyGenerationRequest>(
      context: context,
      builder: (dialogContext) => const _KeyGeneratorDialog(),
    );
    if (request == null) return;

    await _mutate(() async {
      final GeneratedKeyEntry generated;
      switch (request.preset) {
        case _KeyPreset.githubSshEd25519:
          generated = await KeyGenerators.githubSshEd25519(
            comment: request.comment,
          );
          break;
        case _KeyPreset.githubSshRsa:
          generated = await KeyGenerators.githubSshRsa(
            comment: request.comment,
            bits: request.rsaBits,
          );
          break;
        case _KeyPreset.sshEd25519:
          generated = await KeyGenerators.sshEd25519(comment: request.comment);
          break;
        case _KeyPreset.sshRsa:
          generated = await KeyGenerators.sshRsa(
            comment: request.comment,
            bits: request.rsaBits,
          );
          break;
        case _KeyPreset.solanaEd25519:
          generated = await KeyGenerators.solanaEd25519();
          break;
        case _KeyPreset.wireGuardX25519:
          generated = await KeyGenerators.wireGuardX25519();
          break;
        case _KeyPreset.fileLockX25519:
          generated = await KeyGenerators.fileLockX25519();
          break;
        case _KeyPreset.ethereumSecp256k1:
          generated = KeyGenerators.ethereumSecp256k1();
          break;
        case _KeyPreset.tronSecp256k1:
          generated = KeyGenerators.tronSecp256k1();
          break;
        case _KeyPreset.bitcoinWif:
          generated = KeyGenerators.bitcoinWif(
            network: request.bitcoinNetwork,
            compressed: request.bitcoinCompressed,
          );
          break;
        case _KeyPreset.randomToken:
          generated = KeyGenerators.randomToken(
            bits: request.tokenBits,
            encoding: request.tokenEncoding,
          );
          break;
        case _KeyPreset.customKey:
          generated = await KeyGenerators.customKeyPair(
            algorithm: request.customAlgorithm,
            encoding: request.customEncoding,
            rsaBits: request.rsaBits,
            ecCompressed: request.customEcCompressed,
          );
          break;
        case _KeyPreset.githubToken:
          generated = KeyGenerators.githubToken(token: request.secret);
          break;
      }

      final entry = VaultNode(
        id: _newId('key'),
        name: request.name,
        type: 'entry',
        kind: generated.kind,
        meta: generated.meta,
        files: generated.files,
      );
      _targetGroup().children.add(entry);
      _selected = entry;
    });
  }

  Future<void> _importFile() async {
    final languageService = LanguageScope.of(context);
    final picked = await FileService.pickAnyFile(
      dialogTitle: languageService.text('fileDialogs.importFile'),
    );
    if (picked == null) return;

    // "Import key" is intentionally separate from "Import vault".
    // Refuse KWV1 backups here instead of treating them as arbitrary binary
    // artifacts or silently changing the meaning of this button.
    if (FileService.isVaultFileName(picked.name)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(languageService.text('importKey.wrongVault'))),
      );
      return;
    }

    final entry = VaultNode(
      id: _newId('file'),
      name: picked.name,
      type: 'entry',
      kind: 'file',
      files: [
        VaultArtifact(
          name: picked.name,
          data: picked.bytes,
          contentType: _guessContentType(picked.name),
        ),
      ],
    );

    await _mutate(() async {
      _targetGroup().children.add(entry);
      _selected = entry;
    });
  }

  Future<void> _lockFile() async {
    final languageService = LanguageScope.of(context);
    final keys =
        LockFileService.findX25519Keys(
          widget.vault.root,
        ).where((key) => key.canEncrypt).toList();
    if (keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(languageService.text('lockFile.noEncryptionKey')),
        ),
      );
      return;
    }

    final request = await showDialog<_LockFileRequest>(
      context: context,
      builder: (dialogContext) => _LockFileDialog(keys: keys),
    );
    if (request == null) return;

    setState(() => _busy = true);
    try {
      final path =
          request.directory
              ? await LockFileService.encryptPickedDirectory(
                recipient: request.key,
                dialogTitle: languageService.text(
                  'fileDialogs.chooseDirectoryEncrypt',
                ),
              )
              : await LockFileService.encryptPickedFile(
                recipient: request.key,
                chooseDialogTitle: languageService.text(
                  'fileDialogs.chooseFileEncrypt',
                ),
                saveDialogTitle: languageService.text(
                  'fileDialogs.saveEncryptedFile',
                ),
              );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            languageService.text(
              'lockFile.encrypted',
              parameters: {'path': path},
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            languageService.text(
              'lockFile.failed',
              parameters: {'error': error},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockFile() async {
    final languageService = LanguageScope.of(context);
    final picked = await LockFileService.pickLockedFile(
      dialogTitle: languageService.text('fileDialogs.openLockedFile'),
    );
    if (picked == null) return;

    final method = KwvLockCrypto.methodFromContainer(picked.bytes);
    final keys =
        LockFileService.findX25519Keys(
          widget.vault.root,
        ).where((key) => key.canDecrypt).toList();
    if (keys.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(languageService.text('unlockFile.noPrivateKey')),
        ),
      );
      return;
    }

    final matches = await LockFileService.matchingPrivateKeys(
      locked: picked.bytes,
      keys: keys,
    );
    final ordered = <LockKeyRef>[
      ...matches,
      ...keys.where((key) => !matches.contains(key)),
    ];
    if (!mounted) return;

    final selected = await showDialog<LockKeyRef>(
      context: context,
      builder:
          (dialogContext) => _UnlockFileDialog(
            fileName: picked.name,
            methodName: KwvLockCrypto.methodName(method),
            keys: ordered,
            matchingKeys: matches,
          ),
    );
    if (selected == null) return;

    setState(() => _busy = true);
    try {
      final output = await LockFileService.unlockToSiblingDirectory(
        picked: picked,
        recipient: selected,
        destinationDialogTitle: languageService.text(
          'fileDialogs.chooseUnlockDestination',
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            languageService.text(
              'unlockFile.unlockedTo',
              parameters: {'path': output},
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            languageService.text(
              'unlockFile.failed',
              parameters: {'error': error},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameSelected() async {
    final selected = _selectedNode;
    if (identical(selected, widget.vault.root)) return;

    final languageService = LanguageScope.of(context);
    final name = await _askSingleLine(
      title: languageService.text('common.rename'),
      label: languageService.text('common.name'),
      initial: selected.name,
    );
    if (name == null || name.isEmpty || name == selected.name) return;

    await _mutate(() async {
      selected.name = name;
    });
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedNode;
    if (identical(selected, widget.vault.root)) return;
    final parent = _findParent(widget.vault.root, selected);
    if (parent == null) return;

    final languageService = LanguageScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(languageService.text('delete.title')),
            content: Text(
              selected.isGroup && selected.children.isNotEmpty
                  ? languageService.text(
                    'delete.withChildren',
                    parameters: {'name': selected.name},
                  )
                  : languageService.text(
                    'delete.single',
                    parameters: {'name': selected.name},
                  ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(languageService.text('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: Text(languageService.text('common.delete')),
              ),
            ],
          ),
    );
    if (confirmed != true) return;

    await _mutate(() async {
      parent.children.removeWhere((node) => identical(node, selected));
      _selected = parent;
    });
  }

  String _guessContentType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.txt') ||
        lower.endsWith('.pub') ||
        lower.endsWith('.pem')) {
      return 'text/plain';
    }
    if (lower.endsWith('.json')) return 'application/json';
    return 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);
    final selected = _selectedNode;
    final showActionLabels = MediaQuery.sizeOf(context).width >= 1180;
    return Scaffold(
      appBar: AppBar(
        title: Text(languageService.productName),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                languageService.text(
                  'wallet.revision',
                  parameters: {'revision': widget.revision},
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: languageService.text('settings.title'),
            onPressed: _busy ? null : () => showSettingsDialog(context),
            icon: const Icon(Icons.settings_outlined),
          ),
          if (showActionLabels) ...[
            TextButton.icon(
              onPressed: _busy ? null : widget.onImportVault,
              icon: const Icon(Icons.file_open, size: 18),
              label: Text(languageService.text('wallet.importVault')),
            ),
            TextButton.icon(
              onPressed: _busy ? null : widget.onExportVault,
              icon: const Icon(Icons.save_alt, size: 18),
              label: Text(languageService.text('wallet.exportVault')),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _lockFile,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text(languageService.text('wallet.lockFile')),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _unlockFile,
              icon: const Icon(Icons.lock_open, size: 18),
              label: Text(languageService.text('wallet.unlockFile')),
            ),
            TextButton.icon(
              onPressed: _busy ? null : widget.onLock,
              icon: const Icon(Icons.lock, size: 18),
              label: Text(languageService.text('wallet.lock')),
            ),
          ] else ...[
            IconButton(
              tooltip: languageService.text(
                'wallet.importEncryptedVaultTooltip',
              ),
              onPressed: _busy ? null : widget.onImportVault,
              icon: const Icon(Icons.file_open),
            ),
            IconButton(
              tooltip: languageService.text(
                'wallet.exportEncryptedVaultTooltip',
              ),
              onPressed: _busy ? null : widget.onExportVault,
              icon: const Icon(Icons.save_alt),
            ),
            IconButton(
              tooltip: languageService.text('wallet.lockFileTooltip'),
              onPressed: _busy ? null : _lockFile,
              icon: const Icon(Icons.lock_outline),
            ),
            IconButton(
              tooltip: languageService.text('wallet.unlockFileTooltip'),
              onPressed: _busy ? null : _unlockFile,
              icon: const Icon(Icons.lock_open),
            ),
            IconButton(
              tooltip: languageService.text('wallet.lock'),
              onPressed: _busy ? null : widget.onLock,
              icon: const Icon(Icons.lock),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 760) {
                  return ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _Toolbox(
                        busy: _busy,
                        onAddGroup: _addGroup,
                        onAddKey: _addKey,
                        onAddText: _addText,
                        onImportFile: _importFile,
                        canEditSelection:
                            !identical(selected, widget.vault.root),
                        onRename: _renameSelected,
                        onDelete: _deleteSelected,
                      ),
                      const SizedBox(height: 8),
                      _TreePanel(
                        root: widget.vault.root,
                        selected: selected,
                        onSelected: (node) => setState(() => _selected = node),
                      ),
                      const SizedBox(height: 12),
                      _DetailsPanel(node: selected),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 335,
                      child: Material(
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: _Toolbox(
                                busy: _busy,
                                onAddGroup: _addGroup,
                                onAddKey: _addKey,
                                onAddText: _addText,
                                onImportFile: _importFile,
                                canEditSelection:
                                    !identical(selected, widget.vault.root),
                                onRename: _renameSelected,
                                onDelete: _deleteSelected,
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(8),
                                child: Align(
                                  alignment: Alignment.topLeft,
                                  child: _TreePanel(
                                    root: widget.vault.root,
                                    selected: selected,
                                    onSelected:
                                        (node) =>
                                            setState(() => _selected = node),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: _DetailsPanel(node: selected),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _KeyPreset {
  githubSshEd25519,
  githubSshRsa,
  sshEd25519,
  sshRsa,
  solanaEd25519,
  wireGuardX25519,
  fileLockX25519,
  ethereumSecp256k1,
  tronSecp256k1,
  bitcoinWif,
  randomToken,
  customKey,
  githubToken,
}

extension _KeyPresetInfo on _KeyPreset {
  String get localizationId => switch (this) {
    _KeyPreset.githubSshEd25519 => 'githubSshEd25519',
    _KeyPreset.githubSshRsa => 'githubSshRsa',
    _KeyPreset.sshEd25519 => 'sshEd25519',
    _KeyPreset.sshRsa => 'sshRsa',
    _KeyPreset.solanaEd25519 => 'solanaEd25519',
    _KeyPreset.wireGuardX25519 => 'wireGuardX25519',
    _KeyPreset.fileLockX25519 => 'fileLockX25519',
    _KeyPreset.ethereumSecp256k1 => 'ethereumSecp256k1',
    _KeyPreset.tronSecp256k1 => 'tronSecp256k1',
    _KeyPreset.bitcoinWif => 'bitcoinWif',
    _KeyPreset.randomToken => 'randomToken',
    _KeyPreset.customKey => 'customKey',
    _KeyPreset.githubToken => 'githubToken',
  };

  String get titleKey => 'keygen.presets.$localizationId.label';
  String get subtitleKey => 'keygen.presets.$localizationId.description';
  String get defaultNameKey => 'keygen.presets.$localizationId.defaultName';

  IconData get icon => switch (this) {
    _KeyPreset.githubSshEd25519 || _KeyPreset.githubSshRsa => Icons.code,
    _KeyPreset.sshEd25519 || _KeyPreset.sshRsa => Icons.key,
    _KeyPreset.solanaEd25519 ||
    _KeyPreset.ethereumSecp256k1 ||
    _KeyPreset.tronSecp256k1 ||
    _KeyPreset.bitcoinWif => Icons.account_balance_wallet_outlined,
    _KeyPreset.wireGuardX25519 => Icons.vpn_key_outlined,
    _KeyPreset.fileLockX25519 => Icons.lock_outline,
    _KeyPreset.randomToken => Icons.password,
    _KeyPreset.customKey => Icons.tune,
    _KeyPreset.githubToken => Icons.token_outlined,
  };

  bool get needsComment =>
      this == _KeyPreset.githubSshEd25519 ||
      this == _KeyPreset.githubSshRsa ||
      this == _KeyPreset.sshEd25519 ||
      this == _KeyPreset.sshRsa;

  bool get needsRsaBits =>
      this == _KeyPreset.githubSshRsa || this == _KeyPreset.sshRsa;
}

class _KeyGenerationRequest {
  final _KeyPreset preset;
  final String name;
  final String comment;
  final String secret;
  final int tokenBits;
  final String tokenEncoding;
  final int rsaBits;
  final String bitcoinNetwork;
  final bool bitcoinCompressed;
  final String customAlgorithm;
  final String customEncoding;
  final bool customEcCompressed;

  const _KeyGenerationRequest({
    required this.preset,
    required this.name,
    this.comment = '',
    this.secret = '',
    this.tokenBits = 256,
    this.tokenEncoding = 'base64url',
    this.rsaBits = 3072,
    this.bitcoinNetwork = 'mainnet',
    this.bitcoinCompressed = true,
    this.customAlgorithm = 'ed25519',
    this.customEncoding = 'hex',
    this.customEcCompressed = true,
  });
}

class _KeyGeneratorDialog extends StatefulWidget {
  const _KeyGeneratorDialog();

  @override
  State<_KeyGeneratorDialog> createState() => _KeyGeneratorDialogState();
}

class _KeyGeneratorDialogState extends State<_KeyGeneratorDialog> {
  _KeyPreset _preset = _KeyPreset.githubSshEd25519;
  String _name = '';
  String _comment = '';
  String _secret = '';
  int _tokenBits = 256;
  String _tokenEncoding = 'base64url';
  int _rsaBits = 3072;
  String _bitcoinNetwork = 'mainnet';
  bool _bitcoinCompressed = true;
  String _customAlgorithm = 'ed25519';
  String _customEncoding = 'hex';
  bool _customEcCompressed = true;
  bool _nameWasEdited = false;
  bool _showSecret = false;
  bool _defaultNameInitialized = false;
  String? _error;

  bool get _customIsEc => const {
    'secp256k1',
    'secp256r1',
    'secp384r1',
    'secp521r1',
  }.contains(_customAlgorithm);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_defaultNameInitialized) {
      final languageService = LanguageScope.of(context);
      _name = languageService.text(_preset.defaultNameKey);
      _defaultNameInitialized = true;
    }
  }

  void _changePreset(_KeyPreset? value) {
    if (value == null) return;
    final languageService = LanguageScope.of(context);
    setState(() {
      _preset = value;
      if (!_nameWasEdited) {
        _name = languageService.text(value.defaultNameKey);
      }
      _error = null;
    });
  }

  void _submit() {
    final languageService = LanguageScope.of(context);
    final name = _name.trim();
    if (name.isEmpty) {
      setState(
        () => _error = languageService.text('keygen.errors.entryNameRequired'),
      );
      return;
    }
    if (_preset == _KeyPreset.githubToken && _secret.trim().isEmpty) {
      setState(
        () => _error = languageService.text('keygen.errors.tokenRequired'),
      );
      return;
    }
    Navigator.of(context).pop(
      _KeyGenerationRequest(
        preset: _preset,
        name: name,
        comment: _comment.trim(),
        secret: _secret.trim(),
        tokenBits: _tokenBits,
        tokenEncoding: _tokenEncoding,
        rsaBits: _rsaBits,
        bitcoinNetwork: _bitcoinNetwork,
        bitcoinCompressed: _bitcoinCompressed,
        customAlgorithm: _customAlgorithm,
        customEncoding: _customEncoding,
        customEcCompressed: _customEcCompressed,
      ),
    );
  }

  Widget _rsaBitsField() {
    final languageService = LanguageScope.of(context);
    return DropdownButtonFormField<int>(
      initialValue: _rsaBits,
      decoration: InputDecoration(
        labelText: languageService.text('keygen.rsaModulusSize'),
        border: const OutlineInputBorder(),
      ),
      items:
          const [2048, 3072, 4096]
              .map(
                (bits) => DropdownMenuItem(
                  value: bits,
                  child: Text(
                    languageService.text(
                      'keygen.bits',
                      parameters: {'bits': bits},
                    ),
                  ),
                ),
              )
              .toList(),
      onChanged: (value) {
        if (value != null) setState(() => _rsaBits = value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    return AlertDialog(
      title: Text(languageService.text('keygen.title')),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<_KeyPreset>(
                initialValue: _preset,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: languageService.text('keygen.preset'),
                  border: const OutlineInputBorder(),
                ),
                items:
                    _KeyPreset.values
                        .map(
                          (preset) => DropdownMenuItem(
                            value: preset,
                            child: Row(
                              children: [
                                Icon(preset.icon, size: 19),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    languageService.text(preset.titleKey),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                onChanged: _changePreset,
              ),
              const SizedBox(height: 10),
              Text(
                languageService.text(_preset.subtitleKey),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: ValueKey('key-name-${_preset.name}-$_nameWasEdited'),
                initialValue: _name,
                decoration: InputDecoration(
                  labelText: languageService.text('keygen.entryName'),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) {
                  _name = value;
                  _nameWasEdited = true;
                },
              ),
              if (_preset.needsComment) ...[
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: _comment,
                  decoration: InputDecoration(
                    labelText: languageService.text('keygen.commentLabel'),
                    hintText: languageService.text('keygen.commentHint'),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) => _comment = value,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (_preset.needsRsaBits) ...[
                const SizedBox(height: 12),
                _rsaBitsField(),
              ],
              if (_preset == _KeyPreset.bitcoinWif) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _bitcoinNetwork,
                  decoration: InputDecoration(
                    labelText: languageService.text('keygen.bitcoinNetwork'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'mainnet',
                      child: Text(languageService.text('keygen.mainnet')),
                    ),
                    DropdownMenuItem(
                      value: 'testnet',
                      child: Text(languageService.text('keygen.testnet')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _bitcoinNetwork = value);
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    languageService.text('keygen.compressedPublicKey'),
                  ),
                  subtitle: Text(
                    languageService.text('keygen.compressedRecommended'),
                  ),
                  value: _bitcoinCompressed,
                  onChanged:
                      (value) => setState(() => _bitcoinCompressed = value),
                ),
              ],
              if (_preset == _KeyPreset.randomToken) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _tokenBits,
                        decoration: InputDecoration(
                          labelText: languageService.text('keygen.entropySize'),
                          border: const OutlineInputBorder(),
                        ),
                        items:
                            const [
                                  64,
                                  80,
                                  92,
                                  96,
                                  112,
                                  128,
                                  192,
                                  256,
                                  384,
                                  512,
                                  1024,
                                ]
                                .map(
                                  (bits) => DropdownMenuItem(
                                    value: bits,
                                    child: Text(
                                      languageService.text(
                                        'keygen.bits',
                                        parameters: {'bits': bits},
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                        onChanged: (value) {
                          if (value != null) setState(() => _tokenBits = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _tokenEncoding,
                        decoration: InputDecoration(
                          labelText: languageService.text('keygen.encoding'),
                          border: const OutlineInputBorder(),
                        ),
                        items:
                            const ['base64url', 'base64', 'hex']
                                .map(
                                  (encoding) => DropdownMenuItem(
                                    value: encoding,
                                    child: Text(
                                      languageService.text(
                                        'keygen.encodings.$encoding',
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _tokenEncoding = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
              if (_preset == _KeyPreset.customKey) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _customAlgorithm,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: languageService.text('keygen.algorithm'),
                    border: const OutlineInputBorder(),
                  ),
                  items:
                      const [
                            'ed25519',
                            'x25519',
                            'secp256k1',
                            'secp256r1',
                            'secp384r1',
                            'secp521r1',
                            'rsa',
                          ]
                          .map(
                            (algorithm) => DropdownMenuItem(
                              value: algorithm,
                              child: Text(
                                languageService.text(
                                  'keygen.algorithms.$algorithm',
                                ),
                              ),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _customAlgorithm = value);
                  },
                ),
                const SizedBox(height: 12),
                if (_customAlgorithm == 'rsa')
                  _rsaBitsField()
                else
                  DropdownButtonFormField<String>(
                    initialValue: _customEncoding,
                    decoration: InputDecoration(
                      labelText: languageService.text('keygen.rawEncoding'),
                      border: const OutlineInputBorder(),
                    ),
                    items:
                        const ['hex', 'base64', 'base64url']
                            .map(
                              (encoding) => DropdownMenuItem(
                                value: encoding,
                                child: Text(
                                  languageService.text(
                                    'keygen.encodings.$encoding',
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _customEncoding = value);
                      }
                    },
                  ),
                if (_customIsEc)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(languageService.text('keygen.compressedSec1')),
                    value: _customEcCompressed,
                    onChanged:
                        (value) => setState(() => _customEcCompressed = value),
                  ),
              ],
              if (_preset == _KeyPreset.githubToken) ...[
                const SizedBox(height: 12),
                TextFormField(
                  obscureText: !_showSecret,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: languageService.text('keygen.githubToken'),
                    helperText: languageService.text('keygen.githubTokenHelp'),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip:
                          _showSecret
                              ? languageService.text('keygen.hideToken')
                              : languageService.text('keygen.showToken'),
                      onPressed:
                          () => setState(() => _showSecret = !_showSecret),
                      icon: Icon(
                        _showSecret ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                  onChanged: (value) => _secret = value,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(languageService.text('common.cancel')),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(
            _preset == _KeyPreset.githubToken ? Icons.save : Icons.auto_awesome,
          ),
          label: Text(
            _preset == _KeyPreset.githubToken
                ? languageService.text('common.store')
                : languageService.text('common.generate'),
          ),
        ),
      ],
    );
  }
}

class _LockFileRequest {
  final LockKeyRef key;
  final bool directory;

  const _LockFileRequest({required this.key, required this.directory});
}

class _LockFileDialog extends StatefulWidget {
  final List<LockKeyRef> keys;

  const _LockFileDialog({required this.keys});

  @override
  State<_LockFileDialog> createState() => _LockFileDialogState();
}

class _LockFileDialogState extends State<_LockFileDialog> {
  late LockKeyRef _key;
  bool _directory = false;

  @override
  void initState() {
    super.initState();
    _key = widget.keys.first;
  }

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    return AlertDialog(
      title: Text(languageService.text('lockFile.title')),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<LockKeyRef>(
              initialValue: _key,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: languageService.text('lockFile.recipientPublicKey'),
                border: const OutlineInputBorder(),
              ),
              items:
                  widget.keys
                      .map(
                        (key) => DropdownMenuItem(
                          value: key,
                          child: Text('${key.label} · X25519'),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _key = value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<bool>(
              initialValue: _directory,
              decoration: InputDecoration(
                labelText: languageService.text('lockFile.source'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: false,
                  child: Text(languageService.text('common.file')),
                ),
                DropdownMenuItem(
                  value: true,
                  child: Text(languageService.text('common.directory')),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _directory = value);
              },
            ),
            const SizedBox(height: 14),
            Text(languageService.text('lockFile.method')),
            const SizedBox(height: 4),
            const SelectableText('X25519 + HKDF-SHA256 + AES-256-GCM'),
            const SizedBox(height: 8),
            Text(
              languageService.text('lockFile.explanation'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(languageService.text('common.cancel')),
        ),
        FilledButton.icon(
          onPressed:
              () => Navigator.of(
                context,
              ).pop(_LockFileRequest(key: _key, directory: _directory)),
          icon: const Icon(Icons.lock_outline),
          label: Text(languageService.text('lockFile.chooseAndEncrypt')),
        ),
      ],
    );
  }
}

class _UnlockFileDialog extends StatefulWidget {
  final String fileName;
  final String methodName;
  final List<LockKeyRef> keys;
  final List<LockKeyRef> matchingKeys;

  const _UnlockFileDialog({
    required this.fileName,
    required this.methodName,
    required this.keys,
    required this.matchingKeys,
  });

  @override
  State<_UnlockFileDialog> createState() => _UnlockFileDialogState();
}

class _UnlockFileDialogState extends State<_UnlockFileDialog> {
  late LockKeyRef _key;

  @override
  void initState() {
    super.initState();
    _key =
        widget.matchingKeys.isNotEmpty
            ? widget.matchingKeys.first
            : widget.keys.first;
  }

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    return AlertDialog(
      title: Text(languageService.text('unlockFile.title')),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              languageService.text(
                'unlockFile.fileLabel',
                parameters: {'fileName': widget.fileName},
              ),
            ),
            const SizedBox(height: 6),
            Text(
              languageService.text(
                'unlockFile.methodLabel',
                parameters: {'methodName': widget.methodName},
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<LockKeyRef>(
              initialValue: _key,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: languageService.text('unlockFile.privateKey'),
                border: const OutlineInputBorder(),
              ),
              items:
                  widget.keys
                      .map(
                        (key) => DropdownMenuItem(
                          value: key,
                          child: Text(
                            widget.matchingKeys.contains(key)
                                ? languageService.text(
                                  'unlockFile.matchesRecipient',
                                  parameters: {'keyLabel': key.label},
                                )
                                : key.label,
                          ),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _key = value);
              },
            ),
            const SizedBox(height: 10),
            Text(
              widget.matchingKeys.isEmpty
                  ? languageService.text('unlockFile.noFingerprintMatch')
                  : languageService.text('unlockFile.matchingSelected'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    widget.matchingKeys.isEmpty
                        ? Theme.of(context).colorScheme.error
                        : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(languageService.text('common.cancel')),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_key),
          icon: const Icon(Icons.lock_open),
          label: Text(languageService.text('unlockFile.decrypt')),
        ),
      ],
    );
  }
}

class _Toolbox extends StatelessWidget {
  final bool busy;
  final VoidCallback onAddGroup;
  final VoidCallback onAddKey;
  final VoidCallback onAddText;
  final VoidCallback onImportFile;
  final bool canEditSelection;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _Toolbox({
    required this.busy,
    required this.onAddGroup,
    required this.onAddKey,
    required this.onAddText,
    required this.onImportFile,
    required this.canEditSelection,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddGroup,
          icon: const Icon(Icons.create_new_folder, size: 18),
          label: Text(languageService.text('toolbox.group')),
        ),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddKey,
          icon: const Icon(Icons.key, size: 18),
          label: Text(languageService.text('toolbox.key')),
        ),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddText,
          icon: const Icon(Icons.notes, size: 18),
          label: Text(languageService.text('toolbox.text')),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onImportFile,
          icon: const Icon(Icons.upload_file, size: 18),
          label: Text(languageService.text('toolbox.importKey')),
        ),
        OutlinedButton.icon(
          onPressed: busy || !canEditSelection ? null : onRename,
          icon: const Icon(Icons.drive_file_rename_outline, size: 18),
          label: Text(languageService.text('toolbox.rename')),
        ),
        OutlinedButton.icon(
          onPressed: busy || !canEditSelection ? null : onDelete,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: Text(languageService.text('toolbox.delete')),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }
}

class _TreePanel extends StatelessWidget {
  final VaultNode root;
  final VaultNode selected;
  final ValueChanged<VaultNode> onSelected;

  const _TreePanel({
    required this.root,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return _NodeTile(
      node: root,
      selected: selected,
      onSelected: onSelected,
      depth: 0,
    );
  }
}

class _NodeTile extends StatelessWidget {
  final VaultNode node;
  final VaultNode selected;
  final ValueChanged<VaultNode> onSelected;
  final int depth;

  const _NodeTile({
    required this.node,
    required this.selected,
    required this.onSelected,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    String kindLabel(String kind) {
      final translated = languageService.text('details.kinds.$kind');
      return translated == '[details.kinds.$kind]' ? kind : translated;
    }

    if (node.isGroup) {
      return ExpansionTile(
        key: PageStorageKey(node.id),
        initiallyExpanded: depth < 2,
        leading: const Icon(Icons.folder_outlined),
        title: InkWell(
          onTap: () => onSelected(node),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              node.name,
              style:
                  identical(node, selected)
                      ? TextStyle(color: Theme.of(context).colorScheme.primary)
                      : null,
            ),
          ),
        ),
        children:
            node.children
                .map(
                  (child) => Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: _NodeTile(
                      node: child,
                      selected: selected,
                      onSelected: onSelected,
                      depth: depth + 1,
                    ),
                  ),
                )
                .toList(),
      );
    }

    return ListTile(
      selected: identical(node, selected),
      leading: const Icon(Icons.key),
      title: Text(node.name),
      subtitle: node.kind.isEmpty ? null : Text(kindLabel(node.kind)),
      onTap: () => onSelected(node),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  final VaultNode node;

  const _DetailsPanel({required this.node});

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);

    String metadataLabel(String key) {
      final translated = languageService.text('metadataLabels.$key');
      return translated == '[metadataLabels.$key]' ? key : translated;
    }

    String kindLabel(String kind) {
      final translated = languageService.text('details.kinds.$kind');
      return translated == '[details.kinds.$kind]' ? kind : translated;
    }

    String metadataValue(String key, String value) {
      if (key == 'purpose' && value == 'KWVLOCK file encryption') {
        return languageService.text('metadataValues.kwvlockFileEncryption');
      }
      if (key == 'source' && value == 'issued by GitHub') {
        return languageService.text('metadataValues.issuedByGitHub');
      }
      if ((key == 'compressed' || key == 'compressed_public_key') &&
          (value == 'true' || value == 'false')) {
        return languageService.text('metadataValues.$value');
      }
      return value;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(node.name, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          node.isGroup
              ? languageService.text('details.groupType')
              : languageService.text(
                'details.entryType',
                parameters: {'kind': kindLabel(node.kind)},
              ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (node.kind == 'github-ssh') ...[
          const SizedBox(height: 20),
          _GithubPublicKey(node: node),
        ],
        if (node.meta.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            languageService.text('details.metadata'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...node.meta.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 150, child: Text(metadataLabel(entry.key))),
                  Expanded(
                    child: SelectableText(
                      metadataValue(entry.key, entry.value),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (node.files.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            languageService.text('details.files'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...node.files.map((artifact) => _ArtifactCard(artifact: artifact)),
        ],
        if (node.isGroup && node.children.isEmpty) ...[
          const SizedBox(height: 20),
          Text(languageService.text('details.emptyGroup')),
        ],
      ],
    );
  }
}

class _GithubPublicKey extends StatelessWidget {
  final VaultNode node;

  const _GithubPublicKey({required this.node});

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);
    VaultArtifact? publicKey;
    for (final file in node.files) {
      if (file.name.endsWith('.pub')) {
        publicKey = file;
        break;
      }
    }
    if (publicKey == null) return const SizedBox.shrink();
    final artifact = publicKey;
    final text = utf8.decode(artifact.data, allowMalformed: true).trim();

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              languageService.text('details.githubPublicKeyTitle'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await ClipboardService.copyText(text);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          languageService.text('details.githubPublicKeyCopied'),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(languageService.text('details.copyForGithub')),
                ),
                OutlinedButton.icon(
                  onPressed:
                      () => FileService.saveArtifact(
                        fileName: artifact.name,
                        bytes: artifact.data,
                        dialogTitle: languageService.text(
                          'fileDialogs.exportFile',
                          parameters: {'fileName': artifact.name},
                        ),
                      ),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: Text(languageService.text('details.exportPub')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  final VaultArtifact artifact;

  const _ArtifactCard({required this.artifact});

  bool get _isText =>
      artifact.contentType.startsWith('text/') ||
      artifact.name.endsWith('.pub') ||
      artifact.name.endsWith('.txt') ||
      artifact.name.endsWith('.json') ||
      artifact.name.endsWith('.pem');

  @override
  Widget build(BuildContext context) {
    final languageService = LanguageScope.of(context);
    final text =
        _isText
            ? utf8.decode(artifact.data, allowMalformed: true).trimRight()
            : null;

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${artifact.name} · ${artifact.data.length} B',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (text != null)
                  TextButton.icon(
                    onPressed: () async {
                      await ClipboardService.copyText(text);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            languageService.text(
                              'details.artifactCopied',
                              parameters: {'artifactName': artifact.name},
                            ),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(languageService.text('details.copy')),
                  ),
                TextButton.icon(
                  onPressed:
                      () => FileService.saveArtifact(
                        fileName: artifact.name,
                        bytes: artifact.data,
                        dialogTitle: languageService.text(
                          'fileDialogs.exportFile',
                          parameters: {'fileName': artifact.name},
                        ),
                      ),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: Text(languageService.text('details.export')),
                ),
              ],
            ),
            if (artifact.contentType.isNotEmpty)
              Text(
                artifact.contentType,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (text != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
