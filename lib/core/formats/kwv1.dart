import 'dart:typed_data';

/// Parsed platform-independent KeyWallet KWV1 container.
///
/// Layout (all integers little-endian):
///   0..3   magic "KWV1"
///   4..7   PBKDF2 iteration count (uint32)
///   8..15  vault revision (uint64)
///   16..31 salt (16 bytes)
///   32..43 AES-GCM nonce (12 bytes)
///   44..N  ciphertext followed by a 16-byte GCM tag
class Kwv1Container {
  static const int headerLength = 44;
  static const int saltLength = 16;
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const List<int> magic = <int>[0x4b, 0x57, 0x56, 0x31]; // KWV1

  final int iterations;
  final int revision;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;
  final Uint8List header;

  const Kwv1Container({
    required this.iterations,
    required this.revision,
    required this.salt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    required this.header,
  });

  factory Kwv1Container.parse(List<int> raw) {
    final bytes = Uint8List.fromList(raw);
    final minimumLength = headerLength + tagLength;
    if (bytes.length < minimumLength) {
      throw const FormatException('KWV1 container is too short');
    }

    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const FormatException('Invalid KWV1 magic');
      }
    }

    final data = ByteData.sublistView(bytes);
    final iterations = data.getUint32(4, Endian.little);
    final revision = data.getUint64(8, Endian.little);

    final encryptedLength = bytes.length - headerLength;
    if (encryptedLength < tagLength) {
      throw const FormatException('KWV1 encrypted payload is too short');
    }

    final cipherEnd = bytes.length - tagLength;
    return Kwv1Container(
      iterations: iterations,
      revision: revision,
      salt: Uint8List.fromList(bytes.sublist(16, 32)),
      nonce: Uint8List.fromList(bytes.sublist(32, 44)),
      cipherText: Uint8List.fromList(bytes.sublist(headerLength, cipherEnd)),
      mac: Uint8List.fromList(bytes.sublist(cipherEnd)),
      header: Uint8List.fromList(bytes.sublist(0, headerLength)),
    );
  }

  static Uint8List buildHeader({
    required int iterations,
    required int revision,
    required List<int> salt,
    required List<int> nonce,
  }) {
    if (iterations <= 0 || iterations > 0xffffffff) {
      throw ArgumentError.value(iterations, 'iterations');
    }
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision');
    }
    if (salt.length != saltLength) {
      throw ArgumentError.value(salt.length, 'salt.length', 'must be 16');
    }
    if (nonce.length != nonceLength) {
      throw ArgumentError.value(nonce.length, 'nonce.length', 'must be 12');
    }

    final out = Uint8List(headerLength);
    out.setRange(0, 4, magic);
    final data = ByteData.sublistView(out);
    data.setUint32(4, iterations, Endian.little);
    data.setUint64(8, revision, Endian.little);
    out.setRange(16, 32, salt);
    out.setRange(32, 44, nonce);
    return out;
  }

  Uint8List toBytes() {
    final out = Uint8List(header.length + cipherText.length + mac.length);
    var offset = 0;
    out.setRange(offset, offset + header.length, header);
    offset += header.length;
    out.setRange(offset, offset + cipherText.length, cipherText);
    offset += cipherText.length;
    out.setRange(offset, offset + mac.length, mac);
    return out;
  }
}
