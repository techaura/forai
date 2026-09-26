import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypt;

/// KWVLOCK v1 envelope.
///
/// Method 1:
///   X25519 ephemeral ECDH
///   HKDF-HMAC-SHA256 (32-byte output)
///   AES-256-GCM for the ZIP payload
///
/// Binary header (84 bytes):
///   0..3   "KVL1"
///   4      method id (1)
///   5      flags/reserved
///   6..7   header length, uint16 LE (84)
///   8..23  recipient id = first 16 bytes SHA-256(recipient public key)
///   24..55 ephemeral X25519 public key (32 bytes)
///   56..71 HKDF salt (16 bytes)
///   72..83 AES-GCM nonce (12 bytes)
///   84..   ciphertext followed by 16-byte GCM tag
///
/// The complete header is authenticated as AES-GCM AAD.
class KwvLockCrypto {
  static const int methodX25519AesGcm = 1;
  static const int headerLength = 84;
  static const int macLength = 16;

  static final crypt.X25519 _x25519 = crypt.X25519();
  static final crypt.Hkdf _hkdf = crypt.Hkdf(
    hmac: crypt.Hmac.sha256(),
    outputLength: 32,
  );
  static final crypt.AesGcm _aes = crypt.AesGcm.with256bits();
  static final crypt.Sha256 _sha256 = crypt.Sha256();
  static final Random _random = Random.secure();
  static final List<int> _hkdfInfo = utf8.encode('KeyWallet KWVLOCK v1 X25519 AES-256-GCM');

  static Future<Uint8List> recipientId(List<int> publicKey) async {
    if (publicKey.length != 32) {
      throw ArgumentError.value(publicKey.length, 'publicKey', 'X25519 public key must be 32 bytes');
    }
    final digest = await _sha256.hash(publicKey);
    return Uint8List.fromList(digest.bytes.sublist(0, 16));
  }

  static Uint8List recipientIdFromContainer(List<int> locked) {
    final bytes = Uint8List.fromList(locked);
    _validateHeader(bytes);
    return Uint8List.fromList(bytes.sublist(8, 24));
  }

  static int methodFromContainer(List<int> locked) {
    final bytes = Uint8List.fromList(locked);
    _validateHeader(bytes);
    return bytes[4];
  }

  static String methodName(int method) => switch (method) {
        methodX25519AesGcm => 'X25519 + HKDF-SHA256 + AES-256-GCM',
        _ => 'Unknown method $method',
      };

  static Future<Uint8List> encrypt({
    required List<int> payload,
    required List<int> recipientPublicKey,
  }) async {
    if (recipientPublicKey.length != 32) {
      throw ArgumentError('Recipient X25519 public key must be 32 bytes');
    }

    final recipientPublic = crypt.SimplePublicKey(
      recipientPublicKey,
      type: crypt.KeyPairType.x25519,
    );
    final ephemeralPair = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeralPair.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeralPair,
      remotePublicKey: recipientPublic,
    );

    final salt = _randomBytes(16);
    final nonce = Uint8List.fromList(_aes.newNonce());
    final contentKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: _hkdfInfo,
    );
    final recipient = await recipientId(recipientPublicKey);

    final header = Uint8List(headerLength);
    header.setRange(0, 4, const [0x4b, 0x56, 0x4c, 0x31]); // KVL1
    header[4] = methodX25519AesGcm;
    header[5] = 0;
    ByteData.sublistView(header).setUint16(6, headerLength, Endian.little);
    header.setRange(8, 24, recipient);
    header.setRange(24, 56, ephemeralPublic.bytes);
    header.setRange(56, 72, salt);
    header.setRange(72, 84, nonce);

    final box = await _aes.encrypt(
      payload,
      secretKey: contentKey,
      nonce: nonce,
      aad: header,
    );

    return Uint8List.fromList([
      ...header,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  static Future<Uint8List> decrypt({
    required List<int> locked,
    required List<int> recipientPrivateKey,
  }) async {
    final bytes = Uint8List.fromList(locked);
    _validateHeader(bytes);
    if (bytes[4] != methodX25519AesGcm) {
      throw const FormatException('Unsupported KWVLOCK method');
    }
    if (recipientPrivateKey.length != 32) {
      throw ArgumentError('Recipient X25519 private key must be 32 bytes');
    }

    final recipientPair = await _x25519.newKeyPairFromSeed(recipientPrivateKey);
    final recipientPublic = await recipientPair.extractPublicKey();
    final expectedId = bytes.sublist(8, 24);
    final actualId = await recipientId(recipientPublic.bytes);
    if (!_constantTimeEqual(expectedId, actualId)) {
      throw StateError('The selected key does not match this KWVLOCK file');
    }

    final ephemeralPublic = crypt.SimplePublicKey(
      bytes.sublist(24, 56),
      type: crypt.KeyPairType.x25519,
    );
    final salt = bytes.sublist(56, 72);
    final nonce = bytes.sublist(72, 84);
    final shared = await _x25519.sharedSecretKey(
      keyPair: recipientPair,
      remotePublicKey: ephemeralPublic,
    );
    final contentKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: _hkdfInfo,
    );

    final cipherEnd = bytes.length - macLength;
    final box = crypt.SecretBox(
      bytes.sublist(headerLength, cipherEnd),
      nonce: nonce,
      mac: crypt.Mac(bytes.sublist(cipherEnd)),
    );
    final clear = await _aes.decrypt(
      box,
      secretKey: contentKey,
      aad: bytes.sublist(0, headerLength),
    );
    return Uint8List.fromList(clear);
  }

  static void _validateHeader(Uint8List bytes) {
    if (bytes.length < headerLength + macLength) {
      throw const FormatException('KWVLOCK file is too short');
    }
    if (bytes[0] != 0x4b || bytes[1] != 0x56 || bytes[2] != 0x4c || bytes[3] != 0x31) {
      throw const FormatException('Not a KWVLOCK v1 file');
    }
    final declared = ByteData.sublistView(bytes).getUint16(6, Endian.little);
    if (declared != headerLength) {
      throw const FormatException('Unsupported KWVLOCK header length');
    }
  }

  static Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List<int>.generate(length, (_) => _random.nextInt(256)));

  static bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
