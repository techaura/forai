import 'package:flutter/material.dart';
import 'language_dropdown.dart';

class UnlockPage extends StatefulWidget {
  final bool hasVault;
  final bool busy;
  final String? error;
  final Future<void> Function(String password) onUnlock;
  final Future<void> Function(String password) onCreate;
  final Future<void> Function(String password) onImport;

  const UnlockPage({
    super.key,
    required this.hasVault,
    required this.busy,
    required this.error,
    required this.onUnlock,
    required this.onCreate,
    required this.onImport,
  });

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.busy) return;
    if (widget.hasVault) {
      await widget.onUnlock(_password.text);
    } else {
      await widget.onCreate(_password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerRight,
                    child: LanguageDropdown(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.hasVault ? 'Unlock KeyWallet' : 'Create KeyWallet',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.hasVault
                        ? 'Enter the master password for the local encrypted vault.'
                        : 'Create a master password, or import an existing .kwvault.',
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    autofocus: true,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Master password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                  if (widget.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      widget.error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: widget.busy ? null : _submit,
                        child: Text(widget.hasVault ? 'Open' : 'Create'),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.busy
                            ? null
                            : () => widget.onImport(_password.text),
                        icon: const Icon(Icons.file_open),
                        label: const Text('Import .kwvault'),
                      ),
                    ],
                  ),
                  if (widget.busy) ...[
                    const SizedBox(height: 20),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
