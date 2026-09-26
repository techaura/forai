import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypt;
import 'package:pointycastle/export.dart' as pc;

import '../vault/vault_node.dart';

class GeneratedKeyEntry {
  final String kind;
  final Map<String, String> meta;
  final List<VaultArtifact> files;

  const GeneratedKeyEntry({
    required this.kind,
    required this.meta,
    required this.files,
  });
}

/// Pure-Dart generators shared by Windows and Android.
///
/// No shell-outs to ssh-keygen/gpg are used here. That keeps the generated
/// material and the .kwvault format portable between desktop and mobile.
class KeyGenerators {
  static final crypt.Ed25519 _ed25519 = crypt.Ed25519();
  static final crypt.X25519 _x25519 = crypt.X25519();
  static final crypt.Sha256 _sha256 = crypt.Sha256();
  static final Random _secureRandom = Random.secure();

  static Future<GeneratedKeyEntry> githubSshEd25519({
    required String comment,
  }) async {
    return _sshEd25519(comment: comment, kind: 'github-ssh');
  }

  static Future<GeneratedKeyEntry> sshEd25519({
    required String comment,
  }) async {
    return _sshEd25519(comment: comment, kind: 'ssh');
  }

  static Future<GeneratedKeyEntry> _sshEd25519({
    required String comment,
    required String kind,
  }) async {
    final keyPair = await _ed25519.newKeyPair();
    final privateSeed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    final publicBytes = Uint8List.fromList(publicKey.bytes);

    if (privateSeed.length != 32 || publicBytes.length != 32) {
      throw StateError('Unexpected Ed25519 key length');
    }

    final publicBlob = BytesBuilder(copy: false)
      ..add(_sshString(utf8.encode('ssh-ed25519')))
      ..add(_sshString(publicBytes));
    final publicBlobBytes = publicBlob.toBytes();

    final cleanComment = comment.trim();
    final publicLine =
        'ssh-ed25519 ${base64Encode(publicBlobBytes)}${cleanComment.isEmpty ? '' : ' $cleanComment'}';
    final privateText = _buildOpenSshPrivate(
      publicBlob: publicBlobBytes,
      publicKey: publicBytes,
      privateSeed: privateSeed,
      comment: cleanComment,
    );

    final digest = await _sha256.hash(publicBlobBytes);
    final fp = base64Encode(digest.bytes).replaceAll('=', '');

    return GeneratedKeyEntry(
      kind: kind,
      meta: {
        'algorithm': 'Ed25519',
        if (cleanComment.isNotEmpty) 'comment': cleanComment,
        'fingerprint': 'SHA256:$fp',
      },
      files: [
        VaultArtifact(
          name: 'id_ed25519',
          data: Uint8List.fromList(utf8.encode(privateText)),
          contentType: 'application/x-openssh-private-key',
          note: 'SSH private key',
        ),
        VaultArtifact(
          name: 'id_ed25519.pub',
          data: Uint8List.fromList(utf8.encode('$publicLine\n')),
          contentType: 'text/plain',
          note: 'SSH public key',
        ),
      ],
    );
  }

  static Future<GeneratedKeyEntry> githubSshRsa({
    required String comment,
    required int bits,
  }) async {
    return _sshRsa(comment: comment, bits: bits, kind: 'github-ssh');
  }

  static Future<GeneratedKeyEntry> sshRsa({
    required String comment,
    required int bits,
  }) async {
    return _sshRsa(comment: comment, bits: bits, kind: 'ssh');
  }

  static Future<GeneratedKeyEntry> _sshRsa({
    required String comment,
    required int bits,
    required String kind,
  }) async {
    if (![2048, 3072, 4096].contains(bits)) {
      throw ArgumentError.value(bits, 'bits', 'SSH RSA must be 2048, 3072 or 4096 bits');
    }

    final pair = _generateRsa(bits);
    final publicKey = pair.publicKey;
    final privateKey = pair.privateKey;
    final n = publicKey.modulus!;
    final e = publicKey.exponent!;

    final publicBlob = BytesBuilder(copy: false)
      ..add(_sshString(utf8.encode('ssh-rsa')))
      ..add(_sshMpInt(e))
      ..add(_sshMpInt(n));
    final publicBlobBytes = publicBlob.toBytes();
    final cleanComment = comment.trim();
    final publicLine =
        'ssh-rsa ${base64Encode(publicBlobBytes)}${cleanComment.isEmpty ? '' : ' $cleanComment'}';

    final digest = await _sha256.hash(publicBlobBytes);
    final fp = base64Encode(digest.bytes).replaceAll('=', '');

    return GeneratedKeyEntry(
      kind: kind,
      meta: {
        'algorithm': 'RSA',
        'bits': '$bits',
        if (cleanComment.isNotEmpty) 'comment': cleanComment,
        'fingerprint': 'SHA256:$fp',
      },
      files: [
        VaultArtifact(
          name: 'id_rsa',
          data: Uint8List.fromList(utf8.encode(_rsaPrivatePem(privateKey, publicKey))),
          contentType: 'application/x-pem-file',
          note: 'RSA private key (PKCS#1 PEM)',
        ),
        VaultArtifact(
          name: 'id_rsa.pub',
          data: Uint8List.fromList(utf8.encode('$publicLine\n')),
          contentType: 'text/plain',
          note: 'SSH public key',
        ),
      ],
    );
  }

  /// Solana uses an Ed25519 keypair. The conventional JSON keypair file is
  /// a 64-byte array: 32-byte private seed followed by the 32-byte public key.
  static Future<GeneratedKeyEntry> solanaEd25519() async {
    final keyPair = await _ed25519.newKeyPair();
    final seed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    final publicBytes = Uint8List.fromList(publicKey.bytes);
    if (seed.length != 32 || publicBytes.length != 32) {
      throw StateError('Unexpected Solana Ed25519 key length');
    }

    final keypair64 = Uint8List.fromList([...seed, ...publicBytes]);
    final address = _base58Encode(publicBytes);
    final jsonKeypair = '${jsonEncode(keypair64.toList())}\n';

    return GeneratedKeyEntry(
      kind: 'solana',
      meta: {
        'algorithm': 'Ed25519',
        'address': address,
      },
      files: [
        VaultArtifact(
          name: 'solana-keypair.json',
          data: Uint8List.fromList(utf8.encode(jsonKeypair)),
          contentType: 'application/json',
          note: '64-byte Solana keypair JSON',
        ),
        VaultArtifact(
          name: 'solana-address.txt',
          data: Uint8List.fromList(utf8.encode('$address\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  /// Generates raw X25519 keys in the Base64 representation used by
  /// WireGuard configuration files.
  static Future<GeneratedKeyEntry> wireGuardX25519() async {
    final keyPair = await _x25519.newKeyPair();
    final privateBytes = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    final publicBytes = Uint8List.fromList(publicKey.bytes);
    if (privateBytes.length != 32 || publicBytes.length != 32) {
      throw StateError('Unexpected X25519 key length');
    }

    final privateText = base64Encode(privateBytes);
    final publicText = base64Encode(publicBytes);
    return GeneratedKeyEntry(
      kind: 'wireguard',
      meta: {
        'algorithm': 'X25519',
        'public_key': publicText,
      },
      files: [
        VaultArtifact(
          name: 'wireguard-private.key',
          data: Uint8List.fromList(utf8.encode('$privateText\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'wireguard-public.key',
          data: Uint8List.fromList(utf8.encode('$publicText\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  /// Dedicated X25519 recipient key for KWVLOCK file encryption.
  /// Keeping this separate from WireGuard avoids reusing a network key for
  /// an unrelated cryptographic purpose.
  static Future<GeneratedKeyEntry> fileLockX25519() async {
    final keyPair = await _x25519.newKeyPair();
    final privateBytes = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    final publicBytes = Uint8List.fromList(publicKey.bytes);
    if (privateBytes.length != 32 || publicBytes.length != 32) {
      throw StateError('Unexpected X25519 key length');
    }

    return GeneratedKeyEntry(
      kind: 'file-lock',
      meta: {
        'algorithm': 'X25519',
        'encoding': 'base64',
        'purpose': 'KWVLOCK file encryption',
      },
      files: [
        VaultArtifact(
          name: 'kwvlock-private.key',
          data: Uint8List.fromList(utf8.encode('${base64Encode(privateBytes)}\n')),
          contentType: 'text/plain',
          note: 'KWVLOCK X25519 private key',
        ),
        VaultArtifact(
          name: 'kwvlock-public.key',
          data: Uint8List.fromList(utf8.encode('${base64Encode(publicBytes)}\n')),
          contentType: 'text/plain',
          note: 'KWVLOCK X25519 public key',
        ),
      ],
    );
  }

  static GeneratedKeyEntry ethereumSecp256k1() {
    final pair = _generateEc('secp256k1', compressed: false);
    final uncompressed = pair.publicBytes;
    if (uncompressed.length != 65 || uncompressed.first != 0x04) {
      throw StateError('Unexpected secp256k1 public key');
    }
    final publicBody = Uint8List.sublistView(uncompressed, 1);
    final hash = pc.KeccakDigest(256).process(publicBody);
    final lower = _hex(hash.sublist(hash.length - 20));
    final address = _ethereumChecksumAddress(lower);

    return GeneratedKeyEntry(
      kind: 'ethereum',
      meta: {
        'algorithm': 'secp256k1',
        'address': address,
      },
      files: [
        VaultArtifact(
          name: 'ethereum-private-key.hex',
          data: Uint8List.fromList(utf8.encode('${_hex(pair.privateBytes)}\n')),
          contentType: 'text/plain',
          note: '32-byte secp256k1 private key',
        ),
        VaultArtifact(
          name: 'ethereum-public-key.hex',
          data: Uint8List.fromList(utf8.encode('${_hex(uncompressed)}\n')),
          contentType: 'text/plain',
          note: 'Uncompressed SEC1 public key',
        ),
        VaultArtifact(
          name: 'ethereum-address.txt',
          data: Uint8List.fromList(utf8.encode('$address\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  static GeneratedKeyEntry tronSecp256k1() {
    final pair = _generateEc('secp256k1', compressed: false);
    final uncompressed = pair.publicBytes;
    final publicBody = Uint8List.sublistView(uncompressed, 1);
    final hash = pc.KeccakDigest(256).process(publicBody);
    final payload = Uint8List.fromList([0x41, ...hash.sublist(hash.length - 20)]);
    final address = _base58Check(payload);

    return GeneratedKeyEntry(
      kind: 'tron',
      meta: {
        'algorithm': 'secp256k1',
        'address': address,
      },
      files: [
        VaultArtifact(
          name: 'tron-private-key.hex',
          data: Uint8List.fromList(utf8.encode('${_hex(pair.privateBytes)}\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'tron-public-key.hex',
          data: Uint8List.fromList(utf8.encode('${_hex(uncompressed)}\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'tron-address.txt',
          data: Uint8List.fromList(utf8.encode('$address\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  static GeneratedKeyEntry bitcoinWif({
    required String network,
    required bool compressed,
  }) {
    if (network != 'mainnet' && network != 'testnet') {
      throw ArgumentError.value(network, 'network', 'Expected mainnet or testnet');
    }

    final pair = _generateEc('secp256k1', compressed: compressed);
    final privatePayload = Uint8List.fromList([
      network == 'mainnet' ? 0x80 : 0xef,
      ...pair.privateBytes,
      if (compressed) 0x01,
    ]);
    final wif = _base58Check(privatePayload);

    final sha = pc.SHA256Digest().process(pair.publicBytes);
    final ripe = pc.RIPEMD160Digest().process(sha);
    final addressPayload = Uint8List.fromList([
      network == 'mainnet' ? 0x00 : 0x6f,
      ...ripe,
    ]);
    final address = _base58Check(addressPayload);

    return GeneratedKeyEntry(
      kind: 'bitcoin',
      meta: {
        'algorithm': 'secp256k1',
        'network': network,
        'compressed': '$compressed',
        'address': address,
      },
      files: [
        VaultArtifact(
          name: 'bitcoin-wif.txt',
          data: Uint8List.fromList(utf8.encode('$wif\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'bitcoin-private-key.hex',
          data: Uint8List.fromList(utf8.encode('${_hex(pair.privateBytes)}\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'bitcoin-public-key.hex',
          data: Uint8List.fromList(utf8.encode('${_hex(pair.publicBytes)}\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'bitcoin-address.txt',
          data: Uint8List.fromList(utf8.encode('$address\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  static GeneratedKeyEntry randomToken({
    required int bits,
    String encoding = 'base64url',
  }) {
    if (bits < 32 || bits > 4096) {
      throw ArgumentError.value(bits, 'bits', 'Must be 32..4096 bits');
    }
    final byteLength = (bits + 7) ~/ 8;
    final bytes = _randomBytes(byteLength);
    final unusedHighBits = byteLength * 8 - bits;
    if (unusedHighBits > 0) {
      // Preserve exactly the requested amount of entropy even when the bit
      // count is not byte-aligned (for example 92 bits).
      bytes[0] &= 0xff >> unusedHighBits;
    }
    final token = _encodeBytes(bytes, encoding);

    return GeneratedKeyEntry(
      kind: 'random-token',
      meta: {
        'bits': '$bits',
        'encoding': encoding,
      },
      files: [
        VaultArtifact(
          name: 'token.txt',
          data: Uint8List.fromList(utf8.encode('$token\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  /// GitHub issues PAT/auth tokens itself. KeyWallet only stores the supplied
  /// token; generating a fake token would be misleading.
  static GeneratedKeyEntry githubToken({required String token}) {
    final clean = token.trim();
    if (clean.isEmpty) {
      throw ArgumentError('GitHub token is empty');
    }
    return GeneratedKeyEntry(
      kind: 'github-token',
      meta: const {'source': 'issued by GitHub'},
      files: [
        VaultArtifact(
          name: 'github-token.txt',
          data: Uint8List.fromList(utf8.encode('$clean\n')),
          contentType: 'text/plain',
          note: 'GitHub PAT/auth token',
        ),
      ],
    );
  }

  /// Configurable raw keypair generator. This is intentionally format-neutral:
  /// it produces the underlying key material instead of pretending to be a
  /// protocol-specific key.
  static Future<GeneratedKeyEntry> customKeyPair({
    required String algorithm,
    required String encoding,
    int rsaBits = 3072,
    bool ecCompressed = true,
  }) async {
    switch (algorithm) {
      case 'ed25519':
        final pair = await _ed25519.newKeyPair();
        final privateBytes = Uint8List.fromList(await pair.extractPrivateKeyBytes());
        final publicKey = await pair.extractPublicKey();
        final publicBytes = Uint8List.fromList(publicKey.bytes);
        return _rawPairEntry(
          kind: 'custom-key',
          algorithm: 'Ed25519',
          privateBytes: privateBytes,
          publicBytes: publicBytes,
          encoding: encoding,
        );
      case 'x25519':
        final pair = await _x25519.newKeyPair();
        final privateBytes = Uint8List.fromList(await pair.extractPrivateKeyBytes());
        final publicKey = await pair.extractPublicKey();
        final publicBytes = Uint8List.fromList(publicKey.bytes);
        return _rawPairEntry(
          kind: 'custom-key',
          algorithm: 'X25519',
          privateBytes: privateBytes,
          publicBytes: publicBytes,
          encoding: encoding,
        );
      case 'secp256k1':
      case 'secp256r1':
      case 'secp384r1':
      case 'secp521r1':
        final pair = _generateEc(algorithm, compressed: ecCompressed);
        return _rawPairEntry(
          kind: 'custom-key',
          algorithm: algorithm,
          privateBytes: pair.privateBytes,
          publicBytes: pair.publicBytes,
          encoding: encoding,
          extraMeta: {'compressed_public_key': '$ecCompressed'},
        );
      case 'rsa':
        if (![2048, 3072, 4096].contains(rsaBits)) {
          throw ArgumentError.value(rsaBits, 'rsaBits', 'RSA must be 2048, 3072 or 4096 bits');
        }
        final pair = _generateRsa(rsaBits);
        final publicKey = pair.publicKey;
        final privateKey = pair.privateKey;
        return GeneratedKeyEntry(
          kind: 'custom-key',
          meta: {
            'algorithm': 'RSA',
            'bits': '$rsaBits',
            'format': 'PKCS#1 PEM',
          },
          files: [
            VaultArtifact(
              name: 'private.pem',
              data: Uint8List.fromList(utf8.encode(_rsaPrivatePem(privateKey, publicKey))),
              contentType: 'application/x-pem-file',
            ),
            VaultArtifact(
              name: 'public.pem',
              data: Uint8List.fromList(utf8.encode(_rsaPublicPem(publicKey))),
              contentType: 'application/x-pem-file',
            ),
          ],
        );
      default:
        throw ArgumentError.value(algorithm, 'algorithm', 'Unsupported custom algorithm');
    }
  }

  static GeneratedKeyEntry _rawPairEntry({
    required String kind,
    required String algorithm,
    required Uint8List privateBytes,
    required Uint8List publicBytes,
    required String encoding,
    Map<String, String> extraMeta = const {},
  }) {
    final privateText = _encodeBytes(privateBytes, encoding);
    final publicText = _encodeBytes(publicBytes, encoding);
    return GeneratedKeyEntry(
      kind: kind,
      meta: {
        'algorithm': algorithm,
        'encoding': encoding,
        ...extraMeta,
      },
      files: [
        VaultArtifact(
          name: 'private.key',
          data: Uint8List.fromList(utf8.encode('$privateText\n')),
          contentType: 'text/plain',
        ),
        VaultArtifact(
          name: 'public.key',
          data: Uint8List.fromList(utf8.encode('$publicText\n')),
          contentType: 'text/plain',
        ),
      ],
    );
  }

  static _EcMaterial _generateEc(String curveName, {required bool compressed}) {
    final domain = pc.ECDomainParameters(curveName);
    final d = _randomScalar(domain.n);
    final point = domain.G * d;
    if (point == null || point.isInfinity) {
      throw StateError('Could not derive EC public key');
    }
    final privateLength = (domain.n.bitLength + 7) ~/ 8;
    return _EcMaterial(
      privateBytes: _bigIntToFixed(d, privateLength),
      publicBytes: Uint8List.fromList(point.getEncoded(compressed)),
    );
  }

  static pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> _generateRsa(int bits) {
    final random = pc.FortunaRandom()..seed(pc.KeyParameter(_randomBytes(32)));
    final generator = pc.RSAKeyGenerator()
      ..init(
        pc.ParametersWithRandom<pc.RSAKeyGeneratorParameters>(
          pc.RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    return pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey>(
      pair.publicKey,
      pair.privateKey,
    );
  }

  static String _rsaPrivatePem(pc.RSAPrivateKey privateKey, pc.RSAPublicKey publicKey) {
    final n = publicKey.modulus!;
    final e = publicKey.exponent!;
    final d = privateKey.privateExponent!;
    final p = privateKey.p!;
    final q = privateKey.q!;
    final dP = d % (p - BigInt.one);
    final dQ = d % (q - BigInt.one);
    final qInv = q.modInverse(p);
    final der = _derSequence([
      ..._derInteger(BigInt.zero),
      ..._derInteger(n),
      ..._derInteger(e),
      ..._derInteger(d),
      ..._derInteger(p),
      ..._derInteger(q),
      ..._derInteger(dP),
      ..._derInteger(dQ),
      ..._derInteger(qInv),
    ]);
    return _pem('RSA PRIVATE KEY', der);
  }

  static String _rsaPublicPem(pc.RSAPublicKey publicKey) {
    final der = _derSequence([
      ..._derInteger(publicKey.modulus!),
      ..._derInteger(publicKey.exponent!),
    ]);
    return _pem('RSA PUBLIC KEY', der);
  }

  static String _pem(String label, Uint8List der) {
    final b64 = base64Encode(der);
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, min(i + 64, b64.length)));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  static Uint8List _derInteger(BigInt value) {
    var bytes = _bigIntToUnsigned(value);
    if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
    if ((bytes.first & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    return Uint8List.fromList([0x02, ..._derLength(bytes.length), ...bytes]);
  }

  static Uint8List _derSequence(List<int> content) =>
      Uint8List.fromList([0x30, ..._derLength(content.length), ...content]);

  static Uint8List _derLength(int length) {
    if (length < 0x80) return Uint8List.fromList([length]);
    final bytes = <int>[];
    var value = length;
    while (value > 0) {
      bytes.insert(0, value & 0xff);
      value >>= 8;
    }
    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }

  static String _ethereumChecksumAddress(String lowerHex40) {
    final hash = pc.KeccakDigest(256).process(Uint8List.fromList(utf8.encode(lowerHex40)));
    final hashHex = _hex(hash);
    final out = StringBuffer('0x');
    for (var i = 0; i < lowerHex40.length; i++) {
      final c = lowerHex40[i];
      final nibble = int.parse(hashHex[i], radix: 16);
      out.write(nibble >= 8 ? c.toUpperCase() : c);
    }
    return out.toString();
  }

  static String _base58Check(List<int> payload) {
    final first = pc.SHA256Digest().process(Uint8List.fromList(payload));
    final second = pc.SHA256Digest().process(first);
    return _base58Encode([...payload, ...second.sublist(0, 4)]);
  }

  static BigInt _randomScalar(BigInt n) {
    final byteLength = (n.bitLength + 7) ~/ 8;
    while (true) {
      final candidate = _bytesToBigInt(_randomBytes(byteLength));
      if (candidate > BigInt.zero && candidate < n) return candidate;
    }
  }

  static Uint8List _randomBytes(int length) => Uint8List.fromList(
        List<int>.generate(length, (_) => _secureRandom.nextInt(256)),
      );

  static BigInt _bytesToBigInt(List<int> bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  static Uint8List _bigIntToFixed(BigInt value, int length) {
    final raw = _bigIntToUnsigned(value);
    if (raw.length > length) {
      throw StateError('Integer does not fit in $length bytes');
    }
    return Uint8List.fromList([
      ...List<int>.filled(length - raw.length, 0),
      ...raw,
    ]);
  }

  static Uint8List _bigIntToUnsigned(BigInt value) {
    if (value == BigInt.zero) return Uint8List(0);
    var v = value;
    final bytes = <int>[];
    while (v > BigInt.zero) {
      bytes.insert(0, (v & BigInt.from(0xff)).toInt());
      v >>= 8;
    }
    return Uint8List.fromList(bytes);
  }

  static String _encodeBytes(List<int> bytes, String encoding) {
    switch (encoding) {
      case 'hex':
        return _hex(bytes);
      case 'base64':
        return base64Encode(bytes);
      case 'base64url':
        return base64UrlEncode(bytes).replaceAll('=', '');
      default:
        throw ArgumentError.value(encoding, 'encoding', 'Unsupported encoding');
    }
  }

  static String _buildOpenSshPrivate({
    required Uint8List publicBlob,
    required Uint8List publicKey,
    required Uint8List privateSeed,
    required String comment,
  }) {
    final random = Random.secure();
    final check = Uint8List.fromList(List<int>.generate(4, (_) => random.nextInt(256)));

    final privateBlock = BytesBuilder(copy: false)
      ..add(check)
      ..add(check)
      ..add(_sshString(utf8.encode('ssh-ed25519')))
      ..add(_sshString(publicKey))
      ..add(_sshString(Uint8List.fromList([...privateSeed, ...publicKey])))
      ..add(_sshString(utf8.encode(comment)));

    var privateBytes = privateBlock.toBytes();
    final padding = <int>[];
    var index = 1;
    while ((privateBytes.length + padding.length) % 8 != 0) {
      padding.add(index++);
    }
    privateBytes = Uint8List.fromList([...privateBytes, ...padding]);

    final outer = BytesBuilder(copy: false)
      ..add(utf8.encode('openssh-key-v1\x00'))
      ..add(_sshString(utf8.encode('none')))
      ..add(_sshString(utf8.encode('none')))
      ..add(_sshString(const <int>[]))
      ..add(_uint32(1))
      ..add(_sshString(publicBlob))
      ..add(_sshString(privateBytes));

    final encoded = base64Encode(outer.toBytes());
    final lines = <String>[];
    for (var i = 0; i < encoded.length; i += 70) {
      lines.add(encoded.substring(i, min(i + 70, encoded.length)));
    }
    return '-----BEGIN OPENSSH PRIVATE KEY-----\n${lines.join('\n')}\n-----END OPENSSH PRIVATE KEY-----\n';
  }

  static String _base58Encode(List<int> input) {
    const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    if (input.isEmpty) return '';

    var value = BigInt.zero;
    for (final byte in input) {
      value = (value << 8) | BigInt.from(byte);
    }

    final encoded = StringBuffer();
    final radix = BigInt.from(58);
    while (value > BigInt.zero) {
      final remainder = (value % radix).toInt();
      encoded.write(alphabet[remainder]);
      value ~/= radix;
    }

    for (final byte in input) {
      if (byte != 0) break;
      encoded.write('1');
    }
    return encoded.toString().split('').reversed.join();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _sshString(List<int> bytes) {
    return Uint8List.fromList([..._uint32(bytes.length), ...bytes]);
  }

  static Uint8List _sshMpInt(BigInt value) {
    var bytes = _bigIntToUnsigned(value);
    if (bytes.isNotEmpty && (bytes.first & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    return _sshString(bytes);
  }

  static Uint8List _uint32(int value) {
    final out = ByteData(4)..setUint32(0, value, Endian.big);
    return out.buffer.asUint8List();
  }
}

class _EcMaterial {
  final Uint8List privateBytes;
  final Uint8List publicBytes;

  const _EcMaterial({required this.privateBytes, required this.publicBytes});
}
