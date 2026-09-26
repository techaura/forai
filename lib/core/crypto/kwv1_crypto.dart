import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../formats/kwv1.dart';
import '../vault/vault.dart';

class Kwv1CryptoException implements Exception {
  final String message;
  const Kwv1CryptoException(this.message);

  @override
  String toString() => 'Kwv1CryptoException: $message';
}

class DecryptedKwv1 {
  final Kwv1Container container;
  final Vault vault;

  const DecryptedKwv1({required this.container, required this.vault});
}

class Kwv1Crypto {
  static const int currentIterations = 600000;
  static const int maxSupportedIterations = 5000000;

  static final AesGcm _aes = AesGcm.with256bits();
  static final Random _random = Random.secure();

  static Future<Uint8List> deriveKeyBytes({
    required String password,
    required List<int> salt,
    required int iterations,
  }) async {
    if (iterations <= 0 || iterations > maxSupportedIterations) {
      throw Kwv1CryptoException('Unsupported PBKDF2 iteration count: $iterations');
    }
    if (salt.length != Kwv1Container.saltLength) {
      throw const Kwv1CryptoException('KWV1 salt must contain 16 bytes');
    }

    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  static Future<DecryptedKwv1> decrypt(
    List<int> raw,
    String password,
  ) async {
    final container = Kwv1Container.parse(raw);
    if (container.iterations <= 0 ||
        container.iterations > maxSupportedIterations) {
      throw Kwv1CryptoException(
        'Unsupported PBKDF2 iteration count: ${container.iterations}',
      );
    }

    final keyBytes = await deriveKeyBytes(
      password: password,
      salt: container.salt,
      iterations: container.iterations,
    );

    Uint8List? plainBytes;
    try {
      final box = SecretBox(
        container.cipherText,
        nonce: container.nonce,
        mac: Mac(container.mac),
      );
      final plain = await _aes.decrypt(
        box,
        secretKey: SecretKey(keyBytes),
        aad: container.header,
      );
      plainBytes = Uint8List.fromList(plain);

      final vault = Vault.fromUtf8Bytes(plainBytes);
      return DecryptedKwv1(container: container, vault: vault);
    } catch (_) {
      throw const Kwv1CryptoException(
        'Wrong password, damaged KWV1 container, or invalid vault JSON',
      );
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
      plainBytes?.fillRange(0, plainBytes.length, 0);
    }
  }

  static Future<Uint8List> encrypt(
    Vault vault,
    String password, {
    required int revision,
    int iterations = currentIterations,
    Uint8List? salt,
    Uint8List? nonce,
  }) async {
    vault.validate();
    if (iterations <= 0 || iterations > maxSupportedIterations) {
      throw Kwv1CryptoException('Unsupported PBKDF2 iteration count: $iterations');
    }
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision');
    }

    final actualSalt = salt ?? _randomBytes(Kwv1Container.saltLength);
    final actualNonce = nonce ?? _randomBytes(Kwv1Container.nonceLength);
    if (actualSalt.length != Kwv1Container.saltLength) {
      throw const Kwv1CryptoException('KWV1 salt must contain 16 bytes');
    }
    if (actualNonce.length != Kwv1Container.nonceLength) {
      throw const Kwv1CryptoException('KWV1 nonce must contain 12 bytes');
    }

    final header = Kwv1Container.buildHeader(
      iterations: iterations,
      revision: revision,
      salt: actualSalt,
      nonce: actualNonce,
    );
    final keyBytes = await deriveKeyBytes(
      password: password,
      salt: actualSalt,
      iterations: iterations,
    );
    final plain = vault.toUtf8Bytes();

    try {
      final box = await _aes.encrypt(
        plain,
        secretKey: SecretKey(keyBytes),
        nonce: actualNonce,
        aad: header,
      );
      if (box.mac.bytes.length != Kwv1Container.tagLength) {
        throw Kwv1CryptoException(
          'Unexpected AES-GCM tag length: ${box.mac.bytes.length}',
        );
      }

      final out = Uint8List(
        header.length + box.cipherText.length + box.mac.bytes.length,
      );
      var offset = 0;
      out.setRange(offset, offset + header.length, header);
      offset += header.length;
      out.setRange(offset, offset + box.cipherText.length, box.cipherText);
      offset += box.cipherText.length;
      out.setRange(offset, offset + box.mac.bytes.length, box.mac.bytes);
      return out;
    } finally {
      keyBytes.fillRange(0, keyBytes.length, 0);
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256), growable: false),
    );
  }
}
