import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/ed25519.dart';

/// 直播源脚本的发布者签名（Ed25519），见 doc/live_source_api.md §8
///
/// - 公钥、签名都用标准 Base64（公钥 32 字节，签名 64 字节）；
/// - 签名的内容是脚本文件的字节，先把 CRLF 换成 LF（在 Windows 上用 Git 提交、上传时换行符可能被改，
///   对 JS 的含义没有影响）。

/// 签名、校验前统一换行符：CRLF → LF
Uint8List liveSourceCanonicalBytes(List<int> bytes) {
  var out = BytesBuilder(copy: false);
  var start = 0;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10) {
      out.add(bytes.sublist(start, i));
      start = i + 1;
    }
  }
  if (start == 0) return Uint8List.fromList(bytes);
  out.add(bytes.sublist(start));
  return out.takeBytes();
}

Uint8List? _decode(String? text, int length) {
  if (text == null) return null;
  try {
    var bytes = base64.decode(text.trim());
    return bytes.length == length ? bytes : null;
  } catch (_) {
    return null;
  }
}

/// Base64 的公钥 → 32 字节；格式不对时为 null
Uint8List? liveSourceDecodePublicKey(String? text) => _decode(text, 32);

/// Base64 的签名 → 64 字节；格式不对时为 null
Uint8List? liveSourceDecodeSignature(String? text) => _decode(text, 64);

/// 用 32 字节的私钥（种子）给脚本签名，返回 Base64 的签名
String liveSourceSign(List<int> seed, List<int> scriptBytes) =>
    base64.encode(ed25519Sign(seed, liveSourceCanonicalBytes(scriptBytes)));

/// 校验脚本的签名；公钥、签名格式不对时也返回 false
bool liveSourceVerify(
  String publicKey,
  List<int> scriptBytes,
  String signature,
) {
  var key = liveSourceDecodePublicKey(publicKey);
  var sig = liveSourceDecodeSignature(signature);
  if (key == null || sig == null) return false;
  return ed25519Verify(key, liveSourceCanonicalBytes(scriptBytes), sig);
}

/// 公钥的短指纹（SHA-256 的前 8 字节，如 "1a2b 3c4d 5e6f 7a8b"），给用户核对用
String liveSourceKeyFingerprint(String publicKey) {
  var key = liveSourceDecodePublicKey(publicKey) ?? utf8.encode(publicKey);
  var hex = sha256
      .convert(key)
      .bytes
      .take(8)
      .map((b) => b.toRadixString(16).padLeft(2, "0"))
      .join();
  return [for (var i = 0; i < 16; i += 4) hex.substring(i, i + 4)].join(" ");
}
