import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keywallet_multios/core/crypto/key_generators.dart';

void main() {
  test('GitHub Ed25519 generator creates OpenSSH pair', () async {
    final generated = await KeyGenerators.githubSshEd25519(
      comment: 'test@example.com',
    );

    expect(generated.kind, 'github-ssh');
    expect(generated.files.length, 2);

    final privateKey = utf8.decode(generated.files[0].data);
    final publicKey = utf8.decode(generated.files[1].data).trim();

    expect(privateKey, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
    expect(privateKey, contains('-----END OPENSSH PRIVATE KEY-----'));
    expect(publicKey, startsWith('ssh-ed25519 '));
    expect(publicKey, endsWith(' test@example.com'));
    expect(generated.meta['fingerprint'], startsWith('SHA256:'));
  });

  test('Solana generator creates 64-byte JSON keypair and Base58 address', () async {
    final generated = await KeyGenerators.solanaEd25519();
    expect(generated.kind, 'solana');
    expect(generated.meta['algorithm'], 'Ed25519');

    final keypair = jsonDecode(utf8.decode(generated.files[0].data)) as List<dynamic>;
    expect(keypair.length, 64);
    expect(keypair.every((value) => value is int && value >= 0 && value <= 255), isTrue);

    final address = utf8.decode(generated.files[1].data).trim();
    expect(address, isNotEmpty);
    expect(generated.meta['address'], address);
  });

  test('WireGuard generator creates two 32-byte Base64 keys', () async {
    final generated = await KeyGenerators.wireGuardX25519();
    expect(generated.kind, 'wireguard');

    final privateText = utf8.decode(generated.files[0].data).trim();
    final publicText = utf8.decode(generated.files[1].data).trim();
    expect(base64Decode(privateText).length, 32);
    expect(base64Decode(publicText).length, 32);
    expect(generated.meta['public_key'], publicText);
  });

  test('Ethereum generator creates secp256k1 private key and address', () {
    final generated = KeyGenerators.ethereumSecp256k1();
    final privateText = utf8.decode(generated.files[0].data).trim();
    final address = generated.meta['address']!;
    expect(privateText, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(privateText), isTrue);
    expect(RegExp(r'^0x[0-9A-Fa-f]{40}$').hasMatch(address), isTrue);
  });

  test('TRON generator creates Base58Check address', () {
    final generated = KeyGenerators.tronSecp256k1();
    final address = generated.meta['address']!;
    expect(address, startsWith('T'));
    expect(address.length, inInclusiveRange(33, 35));
  });

  test('Bitcoin WIF supports mainnet and compressed public key', () {
    final generated = KeyGenerators.bitcoinWif(network: 'mainnet', compressed: true);
    final wif = utf8.decode(generated.files[0].data).trim();
    final address = generated.meta['address']!;
    expect(wif, isNotEmpty);
    expect(address, startsWith('1'));
    expect(generated.meta['compressed'], 'true');
  });

  test('Random token honors size and encoding', () {
    final urlToken = KeyGenerators.randomToken(bits: 256, encoding: 'base64url');
    final urlText = utf8.decode(urlToken.files.single.data).trim();
    expect(urlText, isNot(contains('=')));
    expect(urlToken.meta['bits'], '256');
    expect(urlToken.meta['encoding'], 'base64url');

    final hexToken = KeyGenerators.randomToken(bits: 128, encoding: 'hex');
    final hexText = utf8.decode(hexToken.files.single.data).trim();
    expect(hexText.length, 32);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(hexText), isTrue);

    final token92 = KeyGenerators.randomToken(bits: 92, encoding: 'hex');
    final token92Text = utf8.decode(token92.files.single.data).trim();
    expect(token92Text.length, 24); // 12 stored bytes, with 4 unused high bits masked
    expect(token92Text, startsWith('0'));
    expect(token92.meta['bits'], '92');
  });

  test('Custom secp256k1 keypair honors raw hex and compressed public key', () async {
    final generated = await KeyGenerators.customKeyPair(
      algorithm: 'secp256k1',
      encoding: 'hex',
      ecCompressed: true,
    );
    final privateText = utf8.decode(generated.files[0].data).trim();
    final publicText = utf8.decode(generated.files[1].data).trim();
    expect(privateText, hasLength(64));
    expect(publicText.length, 66);
    expect(publicText.startsWith('02') || publicText.startsWith('03'), isTrue);
  });

  test('File Lock preset creates dedicated X25519 pair', () async {
    final generated = await KeyGenerators.fileLockX25519();
    expect(generated.kind, 'file-lock');
    expect(generated.meta['algorithm'], 'X25519');
    expect(generated.meta['purpose'], contains('KWVLOCK'));
    expect(base64Decode(utf8.decode(generated.files[0].data).trim()).length, 32);
    expect(base64Decode(utf8.decode(generated.files[1].data).trim()).length, 32);
  });

  test('GitHub token preset stores a supplied token instead of generating one', () {
    final generated = KeyGenerators.githubToken(token: 'github_pat_test');
    expect(generated.kind, 'github-token');
    expect(utf8.decode(generated.files.single.data).trim(), 'github_pat_test');
    expect(generated.meta['source'], 'issued by GitHub');
  });
}
