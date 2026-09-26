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
import 'language_dropdown.dart';
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

  String _newId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Operation failed: $error')),
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
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
            onFieldSubmitted: (_) => Navigator.of(dialogContext).pop(value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(value.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _addGroup() async {
    final name = await _askSingleLine(title: 'New group', label: 'Group name');
    if (name == null || name.isEmpty) return;
    final group = VaultNode(
      id: _newId('group'),
      name: name,
      type: 'group',
    );
    await _mutate(() async {
      _targetGroup().children.add(group);
      _selected = group;
    });
  }

  Future<void> _addText() async {
    var name = 'Text';
    var text = '';
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New text / secret'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: name,
                autofocus: true,
                onChanged: (value) => name = value,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                minLines: 5,
                maxLines: 12,
                onChanged: (value) => text = value,
                decoration: const InputDecoration(
                  labelText: 'Text / secret',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
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
          generated = await KeyGenerators.sshEd25519(
            comment: request.comment,
          );
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
    final picked = await FileService.pickAnyFile();
    if (picked == null) return;

    // "Import key" is intentionally separate from "Import vault".
    // Refuse KWV1 backups here instead of treating them as arbitrary binary
    // artifacts or silently changing the meaning of this button.
    if (FileService.isVaultFileName(picked.name)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This is a KeyWallet vault. Use “Import vault” in the top bar.'),
        ),
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
    final keys = LockFileService.findX25519Keys(widget.vault.root)
        .where((key) => key.canEncrypt)
        .toList();
    if (keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No X25519 encryption key found. Create “File Lock · X25519” first.'),
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
      final path = request.directory
          ? await LockFileService.encryptPickedDirectory(recipient: request.key)
          : await LockFileService.encryptPickedFile(recipient: request.key);
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Encrypted: $path')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('LockFile failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockFile() async {
    final picked = await LockFileService.pickLockedFile();
    if (picked == null) return;

    final method = KwvLockCrypto.methodFromContainer(picked.bytes);
    final keys = LockFileService.findX25519Keys(widget.vault.root)
        .where((key) => key.canDecrypt)
        .toList();
    if (keys.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No X25519 private key is available in this vault.')),
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
      builder: (dialogContext) => _UnlockFileDialog(
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
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unlocked to: $output')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('UnlockFile failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameSelected() async {
    final selected = _selectedNode;
    if (identical(selected, widget.vault.root)) return;

    final name = await _askSingleLine(
      title: 'Rename',
      label: 'Name',
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text(
          selected.isGroup && selected.children.isNotEmpty
              ? 'Delete “${selected.name}” and everything inside it?'
              : 'Delete “${selected.name}”?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
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
    if (lower.endsWith('.txt') || lower.endsWith('.pub') || lower.endsWith('.pem')) {
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
              child: Text('KWV1 · rev ${widget.revision}'),
            ),
          ),
          if (showActionLabels) ...[
            TextButton.icon(
              onPressed: _busy ? null : widget.onImportVault,
              icon: const Icon(Icons.file_open, size: 18),
              label: const Text('Import vault'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : widget.onExportVault,
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Export vault'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _lockFile,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: const Text('LockFile'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _unlockFile,
              icon: const Icon(Icons.lock_open, size: 18),
              label: const Text('UnlockFile'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : widget.onLock,
              icon: const Icon(Icons.lock, size: 18),
              label: const Text('Lock'),
            ),
          ] else ...[
            IconButton(
              tooltip: 'Import encrypted vault',
              onPressed: _busy ? null : widget.onImportVault,
              icon: const Icon(Icons.file_open),
            ),
            IconButton(
              tooltip: 'Export encrypted vault',
              onPressed: _busy ? null : widget.onExportVault,
              icon: const Icon(Icons.save_alt),
            ),
            IconButton(
              tooltip: 'LockFile',
              onPressed: _busy ? null : _lockFile,
              icon: const Icon(Icons.lock_outline),
            ),
            IconButton(
              tooltip: 'UnlockFile',
              onPressed: _busy ? null : _unlockFile,
              icon: const Icon(Icons.lock_open),
            ),
            IconButton(
              tooltip: 'Lock',
              onPressed: _busy ? null : widget.onLock,
              icon: const Icon(Icons.lock),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: LanguageDropdown(),
            ),
          ),
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
                        canEditSelection: !identical(selected, widget.vault.root),
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
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
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
                                    onSelected: (node) =>
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
  String get title => switch (this) {
        _KeyPreset.githubSshEd25519 => 'GitHub · SSH Ed25519',
        _KeyPreset.githubSshRsa => 'GitHub · SSH RSA',
        _KeyPreset.sshEd25519 => 'SSH · Ed25519',
        _KeyPreset.sshRsa => 'SSH · RSA',
        _KeyPreset.solanaEd25519 => 'Solana · Ed25519',
        _KeyPreset.wireGuardX25519 => 'WireGuard · X25519',
        _KeyPreset.fileLockX25519 => 'File Lock · X25519',
        _KeyPreset.ethereumSecp256k1 => 'Ethereum · secp256k1',
        _KeyPreset.tronSecp256k1 => 'TRON · secp256k1',
        _KeyPreset.bitcoinWif => 'Bitcoin · WIF',
        _KeyPreset.randomToken => 'Random token',
        _KeyPreset.customKey => 'Custom keypair',
        _KeyPreset.githubToken => 'GitHub · PAT/auth token',
      };

  String get subtitle => switch (this) {
        _KeyPreset.githubSshEd25519 => 'OpenSSH authentication key for GitHub',
        _KeyPreset.githubSshRsa => 'RSA OpenSSH key for GitHub; configurable modulus size',
        _KeyPreset.sshEd25519 => 'Generic OpenSSH private/public Ed25519 pair',
        _KeyPreset.sshRsa => 'Generic OpenSSH RSA keypair with configurable size',
        _KeyPreset.solanaEd25519 => '64-byte keypair JSON + Base58 address',
        _KeyPreset.wireGuardX25519 => 'Base64 private/public X25519 keys',
        _KeyPreset.fileLockX25519 => 'Dedicated recipient key for KWVLOCK file encryption',
        _KeyPreset.ethereumSecp256k1 => 'Private key, SEC1 public key and EIP-55 address',
        _KeyPreset.tronSecp256k1 => 'Private/public key and Base58Check TRON address',
        _KeyPreset.bitcoinWif => 'WIF private key + P2PKH address',
        _KeyPreset.randomToken => 'Cryptographically random secret with configurable size',
        _KeyPreset.customKey => 'Raw configurable Ed/X25519, EC or RSA keypair',
        _KeyPreset.githubToken => 'Store a PAT/auth token issued by GitHub',
      };

  String get defaultName => switch (this) {
        _KeyPreset.githubSshEd25519 => 'GitHub SSH Ed25519',
        _KeyPreset.githubSshRsa => 'GitHub SSH RSA',
        _KeyPreset.sshEd25519 => 'SSH Ed25519',
        _KeyPreset.sshRsa => 'SSH RSA',
        _KeyPreset.solanaEd25519 => 'Solana',
        _KeyPreset.wireGuardX25519 => 'WireGuard',
        _KeyPreset.fileLockX25519 => 'File Lock X25519',
        _KeyPreset.ethereumSecp256k1 => 'Ethereum',
        _KeyPreset.tronSecp256k1 => 'TRON',
        _KeyPreset.bitcoinWif => 'Bitcoin',
        _KeyPreset.randomToken => 'Random token',
        _KeyPreset.customKey => 'Custom key',
        _KeyPreset.githubToken => 'GitHub token',
      };

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
  String _name = _KeyPreset.githubSshEd25519.defaultName;
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
  String? _error;

  bool get _customIsEc => const {
        'secp256k1',
        'secp256r1',
        'secp384r1',
        'secp521r1',
      }.contains(_customAlgorithm);

  void _changePreset(_KeyPreset? value) {
    if (value == null) return;
    setState(() {
      _preset = value;
      if (!_nameWasEdited) _name = value.defaultName;
      _error = null;
    });
  }

  void _submit() {
    final name = _name.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Entry name is required.');
      return;
    }
    if (_preset == _KeyPreset.githubToken && _secret.trim().isEmpty) {
      setState(() => _error = 'Paste the token issued by GitHub.');
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
    return DropdownButtonFormField<int>(
      initialValue: _rsaBits,
      decoration: const InputDecoration(
        labelText: 'RSA modulus size',
        border: OutlineInputBorder(),
      ),
      items: const [2048, 3072, 4096]
          .map((bits) => DropdownMenuItem(value: bits, child: Text('$bits bit')))
          .toList(),
      onChanged: (value) {
        if (value != null) setState(() => _rsaBits = value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Generate / store key'),
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
                decoration: const InputDecoration(
                  labelText: 'Preset',
                  border: OutlineInputBorder(),
                ),
                items: _KeyPreset.values
                    .map(
                      (preset) => DropdownMenuItem(
                        value: preset,
                        child: Row(
                          children: [
                            Icon(preset.icon, size: 19),
                            const SizedBox(width: 10),
                            Expanded(child: Text(preset.title)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _changePreset,
              ),
              const SizedBox(height: 10),
              Text(_preset.subtitle, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              TextFormField(
                key: ValueKey('key-name-${_preset.name}-$_nameWasEdited'),
                initialValue: _name,
                decoration: const InputDecoration(
                  labelText: 'Entry name',
                  border: OutlineInputBorder(),
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
                  decoration: const InputDecoration(
                    labelText: 'Comment / account / email',
                    hintText: 'user@example.com',
                    border: OutlineInputBorder(),
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
                  decoration: const InputDecoration(
                    labelText: 'Bitcoin network',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'mainnet', child: Text('Mainnet')),
                    DropdownMenuItem(value: 'testnet', child: Text('Testnet')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _bitcoinNetwork = value);
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Compressed public key'),
                  subtitle: const Text('Recommended for modern Bitcoin wallets'),
                  value: _bitcoinCompressed,
                  onChanged: (value) => setState(() => _bitcoinCompressed = value),
                ),
              ],
              if (_preset == _KeyPreset.randomToken) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _tokenBits,
                        decoration: const InputDecoration(
                          labelText: 'Entropy / size',
                          border: OutlineInputBorder(),
                        ),
                        items: const [64, 80, 92, 96, 112, 128, 192, 256, 384, 512, 1024]
                            .map((bits) => DropdownMenuItem(value: bits, child: Text('$bits bit')))
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
                        decoration: const InputDecoration(
                          labelText: 'Encoding',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'base64url', child: Text('Base64 URL-safe')),
                          DropdownMenuItem(value: 'base64', child: Text('Base64')),
                          DropdownMenuItem(value: 'hex', child: Text('Hex')),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _tokenEncoding = value);
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
                  decoration: const InputDecoration(
                    labelText: 'Algorithm',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'ed25519', child: Text('Ed25519')),
                    DropdownMenuItem(value: 'x25519', child: Text('X25519')),
                    DropdownMenuItem(value: 'secp256k1', child: Text('EC secp256k1')),
                    DropdownMenuItem(value: 'secp256r1', child: Text('EC P-256 / secp256r1')),
                    DropdownMenuItem(value: 'secp384r1', child: Text('EC P-384 / secp384r1')),
                    DropdownMenuItem(value: 'secp521r1', child: Text('EC P-521 / secp521r1')),
                    DropdownMenuItem(value: 'rsa', child: Text('RSA')),
                  ],
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
                    decoration: const InputDecoration(
                      labelText: 'Raw key encoding',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'hex', child: Text('Hex')),
                      DropdownMenuItem(value: 'base64', child: Text('Base64')),
                      DropdownMenuItem(value: 'base64url', child: Text('Base64 URL-safe')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _customEncoding = value);
                    },
                  ),
                if (_customIsEc)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Compressed SEC1 public key'),
                    value: _customEcCompressed,
                    onChanged: (value) => setState(() => _customEcCompressed = value),
                  ),
              ],
              if (_preset == _KeyPreset.githubToken) ...[
                const SizedBox(height: 12),
                TextFormField(
                  obscureText: !_showSecret,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'GitHub token',
                    helperText: 'GitHub issues this token; KeyWallet stores it but does not generate it.',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _showSecret ? 'Hide token' : 'Show token',
                      onPressed: () => setState(() => _showSecret = !_showSecret),
                      icon: Icon(_showSecret ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                  onChanged: (value) => _secret = value,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(_preset == _KeyPreset.githubToken ? Icons.save : Icons.auto_awesome),
          label: Text(_preset == _KeyPreset.githubToken ? 'Store' : 'Generate'),
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
    return AlertDialog(
      title: const Text('LockFile'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<LockKeyRef>(
              initialValue: _key,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Recipient public key',
                border: OutlineInputBorder(),
              ),
              items: widget.keys
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
              decoration: const InputDecoration(
                labelText: 'Source',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: false, child: Text('File')),
                DropdownMenuItem(value: true, child: Text('Directory')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _directory = value);
              },
            ),
            const SizedBox(height: 14),
            const Text('Method'),
            const SizedBox(height: 4),
            const SelectableText('X25519 + HKDF-SHA256 + AES-256-GCM'),
            const SizedBox(height: 8),
            Text(
              'The source is packed as ZIP first. Only the public key is needed to encrypt.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(
            _LockFileRequest(key: _key, directory: _directory),
          ),
          icon: const Icon(Icons.lock_outline),
          label: const Text('Choose source & encrypt'),
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
    _key = widget.matchingKeys.isNotEmpty ? widget.matchingKeys.first : widget.keys.first;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('UnlockFile'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('File: ${widget.fileName}'),
            const SizedBox(height: 6),
            Text('Method: ${widget.methodName}'),
            const SizedBox(height: 16),
            DropdownButtonFormField<LockKeyRef>(
              initialValue: _key,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Private key',
                border: OutlineInputBorder(),
              ),
              items: widget.keys
                  .map(
                    (key) => DropdownMenuItem(
                      value: key,
                      child: Text(
                        widget.matchingKeys.contains(key)
                            ? '${key.label} · matches recipient'
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
                  ? 'No key fingerprint match was found. You can still try another X25519 private key.'
                  : 'The matching recipient key was selected automatically.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.matchingKeys.isEmpty
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
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_key),
          icon: const Icon(Icons.lock_open),
          label: const Text('Decrypt'),
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
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddGroup,
          icon: const Icon(Icons.create_new_folder, size: 18),
          label: const Text('Group'),
        ),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddKey,
          icon: const Icon(Icons.key, size: 18),
          label: const Text('Key'),
        ),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onAddText,
          icon: const Icon(Icons.notes, size: 18),
          label: const Text('Text'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onImportFile,
          icon: const Icon(Icons.upload_file, size: 18),
          label: const Text('Import key'),
        ),
        OutlinedButton.icon(
          onPressed: busy || !canEditSelection ? null : onRename,
          icon: const Icon(Icons.drive_file_rename_outline, size: 18),
          label: const Text('Rename'),
        ),
        OutlinedButton.icon(
          onPressed: busy || !canEditSelection ? null : onDelete,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete'),
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
              style: identical(node, selected)
                  ? TextStyle(color: Theme.of(context).colorScheme.primary)
                  : null,
            ),
          ),
        ),
        children: node.children
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
      subtitle: node.kind.isEmpty ? null : Text(node.kind),
      onTap: () => onSelected(node),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  final VaultNode node;

  const _DetailsPanel({required this.node});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(node.name, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          node.isGroup ? 'group' : 'entry · ${node.kind}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (node.kind == 'github-ssh') ...[
          const SizedBox(height: 20),
          _GithubPublicKey(node: node),
        ],
        if (node.meta.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Metadata', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...node.meta.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 150, child: Text(entry.key)),
                  Expanded(child: SelectableText(entry.value)),
                ],
              ),
            ),
          ),
        ],
        if (node.files.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Files', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...node.files.map((artifact) => _ArtifactCard(artifact: artifact)),
        ],
        if (node.isGroup && node.children.isEmpty) ...[
          const SizedBox(height: 20),
          const Text('This group is empty.'),
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
            Text('Public SSH key for GitHub', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace')),
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
                      const SnackBar(content: Text('GitHub public key copied')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy for GitHub'),
                ),
                OutlinedButton.icon(
                  onPressed: () => FileService.saveArtifact(
                    fileName: artifact.name,
                    bytes: artifact.data,
                  ),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Export .pub'),
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
    final text = _isText
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
                        SnackBar(content: Text('${artifact.name} copied')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                TextButton.icon(
                  onPressed: () => FileService.saveArtifact(
                    fileName: artifact.name,
                    bytes: artifact.data,
                  ),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Export'),
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
