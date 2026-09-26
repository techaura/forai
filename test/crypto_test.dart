import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/core/crypto/kwv1_crypto.dart';
import 'package:keywallet_multios/core/vault/vault.dart';
import 'package:keywallet_multios/core/vault/vault_node.dart';

void main() {
  test('PBKDF2-HMAC-SHA256 matches the KWV1 reference vector', () async {
    final key = await Kwv1Crypto.deriveKeyBytes(
      password: 'test-password',
      salt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
      iterations: 1000,
    );

    expect(
      key,
      <int>[
        0x0a, 0xc8, 0x9c, 0xbd, 0x45, 0x9b, 0x1c, 0x6b,
        0x36, 0xb6, 0xd5, 0xa1, 0xe6, 0x5b, 0x96, 0x61,
        0x22, 0xcf, 0xcd, 0x07, 0x62, 0x7d, 0x57, 0xb3,
        0xd3, 0x11, 0x1e, 0xf5, 0xc2, 0x7d, 0xb6, 0x11,
      ],
    );
  });

  test('KWV1 encrypt/decrypt round trip retains tree and binary files', () async {
    final vault = Vault(
      version: 1,
      createdAt: '2026-09-24T20:00:00Z',
      updatedAt: '2026-09-24T20:01:00Z',
      root: VaultNode(
        id: 'root-test',
        name: 'KeyWallet',
        type: 'group',
        children: <VaultNode>[
          VaultNode(
            id: 'entry-test',
            name: 'Binary secret',
            type: 'entry',
            kind: 'generic-file',
            files: <VaultArtifact>[
              VaultArtifact(
                name: 'secret.bin',
                data: Uint8List.fromList(<int>[0, 1, 2, 3, 254, 255]),
                contentType: 'application/octet-stream',
              ),
            ],
          ),
        ],
      ),
    );

    final encrypted = await Kwv1Crypto.encrypt(
      vault,
      'round-trip-password',
      revision: 123,
      iterations: 1000,
      salt: Uint8List.fromList(List<int>.generate(16, (i) => 0x10 + i)),
      nonce: Uint8List.fromList(List<int>.generate(12, (i) => 0x80 + i)),
    );

    expect(utf8.decode(encrypted.sublist(0, 4)), 'KWV1');

    final decoded = await Kwv1Crypto.decrypt(
      encrypted,
      'round-trip-password',
    );
    expect(decoded.container.revision, 123);
    expect(decoded.vault.root.children.single.name, 'Binary secret');
    expect(
      decoded.vault.root.children.single.files.single.data,
      <int>[0, 1, 2, 3, 254, 255],
    );
  });
}
