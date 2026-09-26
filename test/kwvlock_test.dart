import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/core/crypto/kwvlock.dart';

void main() {
  test('KWVLOCK X25519/AES-GCM round trip and recipient fingerprint', () async {
    final x25519 = X25519();
    final pair = await x25519.newKeyPair();
    final privateKey = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    final publicKey = await pair.extractPublicKey();
    final payload = Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff));

    final locked = await KwvLockCrypto.encrypt(
      payload: payload,
      recipientPublicKey: publicKey.bytes,
    );

    expect(KwvLockCrypto.methodFromContainer(locked), KwvLockCrypto.methodX25519AesGcm);
    final expectedId = await KwvLockCrypto.recipientId(publicKey.bytes);
    expect(KwvLockCrypto.recipientIdFromContainer(locked), orderedEquals(expectedId));

    final clear = await KwvLockCrypto.decrypt(
      locked: locked,
      recipientPrivateKey: privateKey,
    );
    expect(clear, orderedEquals(payload));
  });

  test('KWVLOCK rejects a different recipient private key', () async {
    final x25519 = X25519();
    final recipient = await x25519.newKeyPair();
    final recipientPublic = await recipient.extractPublicKey();
    final wrong = await x25519.newKeyPair();
    final wrongPrivate = await wrong.extractPrivateKeyBytes();

    final locked = await KwvLockCrypto.encrypt(
      payload: const [1, 2, 3, 4],
      recipientPublicKey: recipientPublic.bytes,
    );

    await expectLater(
      KwvLockCrypto.decrypt(
        locked: locked,
        recipientPrivateKey: wrongPrivate,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
