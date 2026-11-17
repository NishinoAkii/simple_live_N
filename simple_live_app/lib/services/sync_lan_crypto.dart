import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// 局域网同步内容的加密。
///
/// 接收方每次启动同步服务时生成一对临时的 P-256 密钥，公钥放进 /info 的 [infoKey]，
/// features 里声明 [feature]。发送方每发一次也临时生成一对，用 ECDH 算出共享密钥，
/// 再用 AES-256-GCM 加密请求内容，接口路径作为附加数据（密文挪到别的接口会解不开）。
///
/// 这样同一局域网里抓包只能看到密文。公钥没有人工核对，所以防不了有人冒充对方设备。
/// 官方版和旧版本不声明 [feature]，发给它们的照常是明文，账号不发给它们。
class LanSyncCrypto {
  static const String feature = "enc1";
  static const String infoKey = "encKey";
  static const String _label = "simple-live-lan-sync-v1";
  static final ECDomainParameters _curve = ECCurve_secp256r1();

  LanSyncCrypto() : _keys = _newKeys();

  final AsymmetricKeyPair<PublicKey, PrivateKey> _keys;

  /// 本机公钥（未压缩的点，base64）
  String get publicKey => base64.encode(_point(_keys.publicKey));

  /// 发送方：用对方的公钥 [peerKey] 加密发往 [path] 的内容 [plain]
  static Map<String, dynamic> seal(String peerKey, String path, String plain) {
    var mine = _newKeys();
    var sender = _point(mine.publicKey);
    var receiver = base64.decode(peerKey);
    var key = _derive(mine.privateKey, receiver, sender, receiver);
    var iv = _randomBytes(12);
    var data =
        _gcm(true, key, iv, path, Uint8List.fromList(utf8.encode(plain)));
    return {
      "lanEnc": 1,
      "key": base64.encode(sender),
      "iv": base64.encode(iv),
      "data": base64.encode(data),
    };
  }

  /// 接收方：[body] 是加密的就解开返回明文；不是（官方版发来的明文）返回 null。
  /// 解不开（内容被改过、换了接口、对方用的是重启前的公钥）时抛出异常
  String? open(String path, String body) {
    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (parsed is! Map || parsed["lanEnc"] != 1) {
      return null;
    }
    var sender = base64.decode("${parsed["key"]}");
    var key =
        _derive(_keys.privateKey, sender, sender, _point(_keys.publicKey));
    var plain = _gcm(
      false,
      key,
      base64.decode("${parsed["iv"]}"),
      path,
      base64.decode("${parsed["data"]}"),
    );
    return utf8.decode(plain);
  }

  /// 共享密钥：SHA-256(标签 + ECDH 结果 + 发送方公钥 + 接收方公钥)
  static Uint8List _derive(
    PrivateKey own,
    Uint8List other,
    Uint8List sender,
    Uint8List receiver,
  ) {
    var point = _curve.curve.decodePoint(other);
    if (point == null || point.isInfinity) {
      throw const FormatException("bad public key");
    }
    var agreement = ECDHBasicAgreement()..init(own as ECPrivateKey);
    var secret = agreement.calculateAgreement(ECPublicKey(point, _curve));
    var digest = crypto.sha256.convert([
      ...utf8.encode(_label),
      ..._fixed(secret, 32),
      ...sender,
      ...receiver,
    ]);
    return Uint8List.fromList(digest.bytes);
  }

  static Uint8List _gcm(
    bool encrypt,
    Uint8List key,
    Uint8List iv,
    String path,
    Uint8List input,
  ) {
    var cipher = GCMBlockCipher(AESEngine())
      ..init(
        encrypt,
        AEADParameters(
          KeyParameter(key),
          128,
          iv,
          Uint8List.fromList(utf8.encode(path)),
        ),
      );
    return cipher.process(input);
  }

  static AsymmetricKeyPair<PublicKey, PrivateKey> _newKeys() {
    var random = FortunaRandom()..seed(KeyParameter(_randomBytes(32)));
    var generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), random));
    return generator.generateKeyPair();
  }

  static Uint8List _point(PublicKey key) =>
      (key as ECPublicKey).Q!.getEncoded(false);

  static Uint8List _randomBytes(int length) {
    var random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)));
  }

  /// 大端、左边补零到 [length] 字节
  static Uint8List _fixed(BigInt value, int length) {
    var bytes = Uint8List(length);
    var rest = value;
    for (var i = length - 1; i >= 0 && rest > BigInt.zero; i--) {
      bytes[i] = (rest & BigInt.from(0xff)).toInt();
      rest = rest >> 8;
    }
    return bytes;
  }
}
