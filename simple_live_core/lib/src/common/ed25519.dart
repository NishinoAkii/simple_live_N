// Ed25519（RFC 8032）签名和校验，纯 Dart（BigInt + package:crypto 的 SHA-512）
//
// 直播源订阅的发布者签名用（见 doc/live_source_api.md §8）。照 RFC 8032 第 5.1 节和
// 第 6 节的参考实现写，测试里用第 7.1 节的测试向量核对。只用于校验公开的脚本，
// 不需要防计时攻击；签名（[ed25519Sign]）只在发布者自己的电脑上用（bin/live_source_sign.dart）。

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/core_text.dart';

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _q =
    (BigInt.one << 252) +
    BigInt.parse("27742317777372353535851937790883648493");
final BigInt _two = BigInt.two;
final BigInt _d = (-BigInt.from(121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _sqrtM1 = _two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);
final BigInt _mask255 = (BigInt.one << 255) - BigInt.one;

BigInt _inv(BigInt x) => x.modPow(_p - _two, _p);

/// 扩展坐标 (X, Y, Z, T)，x = X/Z，y = Y/Z，x*y = T/Z
class _Point {
  final BigInt x, y, z, t;
  const _Point(this.x, this.y, this.z, this.t);
}

final _Point _neutral = _Point(
  BigInt.zero,
  BigInt.one,
  BigInt.one,
  BigInt.zero,
);

final _Point _base = () {
  var y = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
  var x = _recoverX(y, 0)!;
  return _Point(x, y, BigInt.one, (x * y) % _p);
}();

_Point _add(_Point a, _Point b) {
  var aa = ((a.y - a.x) * (b.y - b.x)) % _p;
  var bb = ((a.y + a.x) * (b.y + b.x)) % _p;
  var c = (_two * a.t * b.t * _d) % _p;
  var dd = (_two * a.z * b.z) % _p;
  var e = bb - aa, f = dd - c, g = dd + c, h = bb + aa;
  return _Point((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _mul(BigInt s, _Point p) {
  var q = _neutral;
  while (s > BigInt.zero) {
    if (s.isOdd) q = _add(q, p);
    p = _add(p, p);
    s = s >> 1;
  }
  return q;
}

bool _equal(_Point a, _Point b) =>
    (a.x * b.z - b.x * a.z) % _p == BigInt.zero &&
    (a.y * b.z - b.y * a.z) % _p == BigInt.zero;

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) return null;
  var x2 = ((y * y - BigInt.one) * _inv(_d * y * y + BigInt.one)) % _p;
  if (x2 == BigInt.zero) {
    return sign == 0 ? BigInt.zero : null;
  }
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return x;
}

BigInt _fromLittleEndian(List<int> bytes) {
  var r = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(bytes[i]);
  }
  return r;
}

Uint8List _toLittleEndian(BigInt v, int length) {
  var out = Uint8List(length);
  var mask = BigInt.from(255);
  for (var i = 0; i < length; i++) {
    out[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return out;
}

Uint8List _compress(_Point p) {
  var zi = _inv(p.z);
  var x = (p.x * zi) % _p;
  var y = (p.y * zi) % _p;
  return _toLittleEndian(y | (x.isOdd ? BigInt.one << 255 : BigInt.zero), 32);
}

_Point? _decompress(List<int> s) {
  if (s.length != 32) return null;
  var v = _fromLittleEndian(s);
  var sign = (v >> 255).toInt();
  var y = v & _mask255;
  var x = _recoverX(y, sign);
  if (x == null) return null;
  return _Point(x, y, BigInt.one, (x * y) % _p);
}

BigInt _hashModQ(List<List<int>> parts) {
  var input = <int>[for (var p in parts) ...p];
  return _fromLittleEndian(sha512.convert(input).bytes) % _q;
}

(BigInt, List<int>) _expand(List<int> seed) {
  if (seed.length != 32) {
    throw ArgumentError("Ed25519 私钥（种子）必须是 32 字节".t);
  }
  var h = sha512.convert(seed).bytes;
  var a = _fromLittleEndian(h.sublist(0, 32));
  a &= (BigInt.one << 254) - BigInt.from(8);
  a |= BigInt.one << 254;
  return (a, h.sublist(32));
}

/// 由 32 字节的私钥（种子）算出 32 字节的公钥
Uint8List ed25519PublicKey(List<int> seed) =>
    _compress(_mul(_expand(seed).$1, _base));

/// 用 32 字节的私钥（种子）签名，返回 64 字节的签名
Uint8List ed25519Sign(List<int> seed, List<int> message) {
  var (a, prefix) = _expand(seed);
  var publicKey = _compress(_mul(a, _base));
  var r = _hashModQ([prefix, message]);
  var rs = _compress(_mul(r, _base));
  var h = _hashModQ([rs, publicKey, message]);
  var s = (r + h * a) % _q;
  return Uint8List.fromList([...rs, ..._toLittleEndian(s, 32)]);
}

/// 校验签名：[publicKey] 32 字节，[signature] 64 字节。格式不对或不匹配时返回 false
bool ed25519Verify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  var a = _decompress(publicKey);
  if (a == null) return false;
  var rs = signature.sublist(0, 32);
  var r = _decompress(rs);
  if (r == null) return false;
  var s = _fromLittleEndian(signature.sublist(32));
  if (s >= _q) return false;
  var h = _hashModQ([rs, publicKey, message]);
  return _equal(_mul(s, _base), _add(r, _mul(h, a)));
}
