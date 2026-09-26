import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/core/crypto/kwv1_crypto.dart';
import 'package:keywallet_multios/core/formats/kwv1.dart';

// Cross-language KWV1 fixture generated according to the same binary format
// used by KeyWallet 0.1.4. PBKDF2 iterations are intentionally low here so
// unit tests stay fast; production writes 600000 iterations.
const _fixtureBase64 =
    'S1dWMegDAAAHAAAAAAAAAAABAgMEBQYHCAkKCwwNDg+goaKjpKWmp6ipqqu/A2pitIwP5Pk+yHk4C6OYqUhXlJiYyd0WW8UdYUyUHOB0B1fK/NKKSl7KDngc/YyfPf4reFyHxxH8eocASYly4Ux5BLH2861Xebqv1HKdaTy9sQgmRPmBPl7kud9J3t+aEPXe17tPY7sBJR4aT3BkV9X8axSL75n5PY5Qz2ZZnN6Dz9RRRTYlyvC5ZC41rp+VFzsNjGXTT+q494PqB3lPByWKCtyBXWX2oeUNEbsNW+5a9yu1AD9qOaj9q1ic/hMvPltfmULj33c9ABGD/9jNV6eZv7t5CuSYmAB/V79VXrZ6lOeAB+SP8QNbxEeZge73tgjwvbPZVtITqFOp0cquwnRpjXv9S9QXkRsk8L/DNT257vQjyp7rlKikZC8+jiVNO7lWowRud9VhAAtu+wHZcEtfN8FBq6GtRNQA0dceZT914tCtLbO7UdULOnXrYVjGEEjLY4As5Adhw/9Jzm9T+Kvsp2Ram68KmolJdxAzHMBujOJ6VCOBZCPuVwqUBdcTmbKN2QlrWA==';

void main() {
  test('KWV1 header parser reads little-endian fields', () {
    final raw = base64Decode(_fixtureBase64);
    final container = Kwv1Container.parse(raw);

    expect(container.iterations, 1000);
    expect(container.revision, 7);
    expect(container.salt, List<int>.generate(16, (i) => i));
    expect(container.nonce, List<int>.generate(12, (i) => 0xa0 + i));
    expect(container.mac.length, 16);
    expect(container.toBytes(), raw);
  });

  test('decrypts a KeyWallet-compatible KWV1 fixture', () async {
    final decoded = await Kwv1Crypto.decrypt(
      base64Decode(_fixtureBase64),
      'test-password',
    );

    expect(decoded.vault.version, 1);
    expect(decoded.vault.root.name, 'KeyWallet');
    expect(decoded.vault.root.children, hasLength(1));

    final entry = decoded.vault.root.children.single;
    expect(entry.name, 'SSH');
    expect(entry.kind, 'github-ssh');
    expect(entry.meta['algorithm'], 'Ed25519');
    expect(entry.files, hasLength(1));
    expect(entry.files.single.name, 'id_ed25519.pub');
    expect(
      utf8.decode(entry.files.single.data),
      'ssh-ed25519 TEST user@example.com\n',
    );
  });

  test('wrong password is rejected', () async {
    expect(
      () => Kwv1Crypto.decrypt(
        base64Decode(_fixtureBase64),
        'not-the-password',
      ),
      throwsA(isA<Kwv1CryptoException>()),
    );
  });
}
