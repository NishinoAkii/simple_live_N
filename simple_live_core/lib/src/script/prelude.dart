/// 直播源脚本的运行环境（全局对象），见 doc/live_source_api.md §2、§3
///
/// 宿主（Dart）和脚本之间没有回调：脚本把请求放进发件箱（`__drain` 取走），
/// 宿主做完后用 `__dispatch` 送回结果；二进制数据用 Base64 字符串传递。
const String kLiveSourcePrelude = r'''
(function (G) {
  "use strict";

  // ------------------------------------------------------------------
  // 宿主通信
  // ------------------------------------------------------------------
  const outbox = [];
  const pending = new Map();
  let seq = 0;

  function replacer(k, v) {
    if (typeof v === "bigint") {
      return (v <= 9007199254740991n && v >= -9007199254740991n) ? Number(v) : v.toString();
    }
    if (v instanceof Uint8Array) return { __b64: Bytes.toBase64(v) };
    if (v instanceof ArrayBuffer) return { __b64: Bytes.toBase64(new Uint8Array(v)) };
    return v;
  }
  function encode(item) { return JSON.stringify(item, replacer); }

  // hls.rewrite 执行期间为 true：只能处理文字，不能发请求、读写存储、开定时器、往弹幕连接发数据
  let rewriting = false;
  function noIoInRewrite(what) {
    if (rewriting) throw new Error("hls.rewrite 里不能" + what + "（只能同步处理文字）");
  }

  function post(op, args) {
    // 只有日志可以（ws.send、session.emit 之类的都不行）
    if (op !== "log") noIoInRewrite("往弹幕连接发数据、发消息");
    try {
      outbox.push(encode({ id: 0, op: op, args: args }));
    } catch (e) {
      outbox.push(JSON.stringify({ id: 0, op: "log", args: { level: "error", msg: "无法发送 " + op + "：" + errMsg(e) } }));
    }
  }

  function host(op, args) {
    noIoInRewrite("发请求、读写存储");
    const id = ++seq;
    return new Promise(function (resolve, reject) {
      let text;
      try {
        text = encode({ id: id, op: op, args: args });
      } catch (e) {
        reject(e);
        return;
      }
      pending.set(id, { resolve: resolve, reject: reject });
      outbox.push(text);
    });
  }

  function errMsg(e) {
    if (e == null) return "未知错误";
    if (typeof e === "string") return e;
    if (e.message !== undefined) return String(e.message);
    try { return String(e); } catch (_) { return "未知错误"; }
  }

  function postResult(id, value) {
    try {
      outbox.push(encode({ id: 0, op: "return", args: { id: id, v: value === undefined ? null : value } }));
    } catch (e) {
      post("throw", { id: id, e: "返回值无法转换为 JSON：" + errMsg(e) });
    }
  }
  function postThrow(id, e) {
    post("throw", { id: id, e: errMsg(e), stack: e && e.stack ? String(e.stack) : null });
  }

  function logError(prefix, e) {
    post("log", { level: "error", msg: prefix + "：" + errMsg(e) + (e && e.stack ? "\n" + e.stack : "") });
  }

  function settle(value, prefix) {
    if (value && typeof value.then === "function") {
      value.then(undefined, function (e) { logError(prefix, e); });
    }
  }

  G.__drain = function () {
    if (outbox.length === 0) return null;
    const text = "[" + outbox.join(",") + "]";
    outbox.length = 0;
    return text;
  };

  const handlers = {};
  G.__dispatch = function (json) {
    const c = JSON.parse(json);
    const h = handlers[c.t];
    if (!h) throw new Error("未知的宿主命令 " + c.t);
    h(c);
    return null;
  };

  handlers.resolve = function (c) {
    const p = pending.get(c.id);
    if (p) { pending.delete(c.id); p.resolve(c.v); }
  };
  handlers.reject = function (c) {
    const p = pending.get(c.id);
    if (p) { pending.delete(c.id); p.reject(new Error(c.e)); }
  };

  // ------------------------------------------------------------------
  // 随机数（宿主给的安全随机种子，xoshiro128**）
  // ------------------------------------------------------------------
  let s0 = 0x9e3779b9, s1 = 0x243f6a88, s2 = 0xb7e15162, s3 = (Date.now() | 0) ^ 0x85a308d3;
  function rotl(x, k) { return (x << k) | (x >>> (32 - k)); }
  function nextU32() {
    const r = Math.imul(rotl(Math.imul(s1, 5), 7), 9) >>> 0;
    const t = s1 << 9;
    s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t; s3 = rotl(s3, 11);
    return r;
  }

  // ------------------------------------------------------------------
  // Bytes
  // ------------------------------------------------------------------
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const B64_CODES = [];
  const B64_INV = new Int16Array(128).fill(-1);
  for (let i = 0; i < 64; i++) { B64_CODES.push(B64.charCodeAt(i)); B64_INV[B64.charCodeAt(i)] = i; }
  B64_INV[45] = 62; // -
  B64_INV[95] = 63; // _
  const HEX = [];
  for (let i = 0; i < 256; i++) HEX.push((i < 16 ? "0" : "") + i.toString(16));

  function toU8(x) {
    if (x instanceof Uint8Array) return x;
    if (x instanceof ArrayBuffer) return new Uint8Array(x);
    if (ArrayBuffer.isView(x)) return new Uint8Array(x.buffer, x.byteOffset, x.byteLength);
    if (Array.isArray(x)) return Uint8Array.from(x);
    if (x && typeof x === "object" && typeof x.__b64 === "string") return Bytes.fromBase64(x.__b64);
    throw new TypeError("需要 Uint8Array");
  }

  function codesToString(codes) {
    let s = "";
    for (let i = 0; i < codes.length; i += 8192) {
      s += String.fromCharCode.apply(null, codes.slice(i, i + 8192));
    }
    return s;
  }

  const Bytes = {
    fromUtf8(str) {
      str = String(str);
      const out = new Uint8Array(str.length * 3);
      let p = 0;
      for (let i = 0; i < str.length; i++) {
        let c = str.charCodeAt(i);
        if (c < 0x80) {
          out[p++] = c;
        } else if (c < 0x800) {
          out[p++] = 0xc0 | (c >> 6);
          out[p++] = 0x80 | (c & 63);
        } else if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length && (str.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
          const cp = 0x10000 + ((c - 0xd800) << 10) + (str.charCodeAt(++i) - 0xdc00);
          out[p++] = 0xf0 | (cp >> 18);
          out[p++] = 0x80 | ((cp >> 12) & 63);
          out[p++] = 0x80 | ((cp >> 6) & 63);
          out[p++] = 0x80 | (cp & 63);
        } else {
          if (c >= 0xd800 && c < 0xe000) c = 0xfffd;
          out[p++] = 0xe0 | (c >> 12);
          out[p++] = 0x80 | ((c >> 6) & 63);
          out[p++] = 0x80 | (c & 63);
        }
      }
      return out.slice(0, p);
    },
    toUtf8(bytes) {
      const u = toU8(bytes);
      const codes = [];
      const n = u.length;
      for (let i = 0; i < n;) {
        const b = u[i++];
        let cp = 0xfffd;
        if (b < 0x80) {
          cp = b;
        } else if (b >= 0xc2 && b < 0xe0) {
          if (i < n && (u[i] & 0xc0) === 0x80) cp = ((b & 31) << 6) | (u[i++] & 63);
        } else if (b >= 0xe0 && b < 0xf0) {
          if (i + 1 < n && (u[i] & 0xc0) === 0x80 && (u[i + 1] & 0xc0) === 0x80) {
            cp = ((b & 15) << 12) | ((u[i] & 63) << 6) | (u[i + 1] & 63);
            i += 2;
            if (cp < 0x800 || (cp >= 0xd800 && cp < 0xe000)) cp = 0xfffd;
          }
        } else if (b >= 0xf0 && b < 0xf5) {
          if (i + 2 < n && (u[i] & 0xc0) === 0x80 && (u[i + 1] & 0xc0) === 0x80 && (u[i + 2] & 0xc0) === 0x80) {
            cp = ((b & 7) << 18) | ((u[i] & 63) << 12) | ((u[i + 1] & 63) << 6) | (u[i + 2] & 63);
            i += 3;
            if (cp < 0x10000 || cp > 0x10ffff) cp = 0xfffd;
          }
        }
        if (cp > 0xffff) {
          cp -= 0x10000;
          codes.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
        } else {
          codes.push(cp);
        }
      }
      return codesToString(codes);
    },
    fromBase64(str) {
      str = String(str);
      const n = str.length;
      const out = new Uint8Array(((n * 3) >> 2) + 3);
      let p = 0, buf = 0, bits = 0;
      for (let i = 0; i < n; i++) {
        const c = str.charCodeAt(i);
        if (c === 61 || c === 32 || c === 10 || c === 13 || c === 9) continue; // = 和空白
        const v = c < 128 ? B64_INV[c] : -1;
        if (v < 0) throw new Error("不是有效的 Base64");
        buf = ((buf << 6) | v) & 0xffffff;
        bits += 6;
        if (bits >= 8) {
          bits -= 8;
          out[p++] = (buf >> bits) & 255;
        }
      }
      return out.slice(0, p);
    },
    toBase64(bytes) {
      const u = toU8(bytes);
      const n = u.length;
      const codes = [];
      let i = 0;
      for (; i + 2 < n; i += 3) {
        const v = (u[i] << 16) | (u[i + 1] << 8) | u[i + 2];
        codes.push(B64_CODES[v >> 18], B64_CODES[(v >> 12) & 63], B64_CODES[(v >> 6) & 63], B64_CODES[v & 63]);
      }
      if (i < n) {
        const v = (u[i] << 16) | ((i + 1 < n ? u[i + 1] : 0) << 8);
        codes.push(B64_CODES[v >> 18], B64_CODES[(v >> 12) & 63]);
        codes.push(i + 1 < n ? B64_CODES[(v >> 6) & 63] : 61, 61);
      }
      return codesToString(codes);
    },
    fromHex(hex) {
      hex = String(hex).replace(/\s+/g, "");
      if (hex.length % 2 !== 0 || /[^0-9a-fA-F]/.test(hex)) throw new Error("不是有效的十六进制字符串");
      const out = new Uint8Array(hex.length / 2);
      for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
      return out;
    },
    toHex(bytes) {
      const u = toU8(bytes);
      const parts = new Array(u.length);
      for (let i = 0; i < u.length; i++) parts[i] = HEX[u[i]];
      return parts.join("");
    },
    concat(...arrays) {
      const list = arrays.map(toU8);
      let len = 0;
      for (const a of list) len += a.length;
      const out = new Uint8Array(len);
      let p = 0;
      for (const a of list) { out.set(a, p); p += a.length; }
      return out;
    },
    toWordArray(bytes) {
      const u = toU8(bytes);
      const words = [];
      for (let i = 0; i < u.length; i++) words[i >>> 2] |= u[i] << (24 - (i % 4) * 8);
      return G.CryptoJS.lib.WordArray.create(words, u.length);
    },
    fromWordArray(wa) {
      const n = wa.sigBytes;
      const words = wa.words;
      const out = new Uint8Array(n);
      for (let i = 0; i < n; i++) out[i] = (words[i >>> 2] >>> (24 - (i % 4) * 8)) & 255;
      return out;
    },
  };
  G.Bytes = Bytes;

  function latin1ToBytes(s) {
    s = String(s);
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c > 255) throw new Error("btoa 只接受 Latin1 字符");
      out[i] = c;
    }
    return out;
  }
  G.btoa = function (s) { return Bytes.toBase64(latin1ToBytes(s)); };
  G.atob = function (s) { return codesToString(Array.from(Bytes.fromBase64(s))); };

  // ------------------------------------------------------------------
  // TextEncoder / TextDecoder（只支持 UTF-8）
  // ------------------------------------------------------------------
  class TextEncoder {
    get encoding() { return "utf-8"; }
    encode(s) { return Bytes.fromUtf8(s === undefined ? "" : s); }
  }
  class TextDecoder {
    constructor(label, options) {
      const l = String(label === undefined ? "utf-8" : label).toLowerCase();
      if (l !== "utf-8" && l !== "utf8" && l !== "unicode-1-1-utf-8") {
        throw new RangeError("TextDecoder 只支持 utf-8");
      }
      this.ignoreBOM = !!(options && options.ignoreBOM);
    }
    get encoding() { return "utf-8"; }
    decode(input) {
      if (input === undefined || input === null) return "";
      let u = toU8(input);
      if (!this.ignoreBOM && u.length >= 3 && u[0] === 0xef && u[1] === 0xbb && u[2] === 0xbf) u = u.subarray(3);
      return Bytes.toUtf8(u);
    }
  }
  G.TextEncoder = TextEncoder;
  G.TextDecoder = TextDecoder;

  // ------------------------------------------------------------------
  // Proto（最小 protobuf）
  // ------------------------------------------------------------------
  // QuickJS-ng 的 BigInt.asUintN 对负数返回原值，这里用掩码自己算
  const MASK64 = 0xffffffffffffffffn;
  const SIGN64 = 0x8000000000000000n;
  function u64(b) { return b & MASK64; }
  function i64(b) { b = b & MASK64; return b >= SIGN64 ? b - 0x10000000000000000n : b; }
  function u32(b) { return Number(b & 0xffffffffn); }
  function toBig(v) {
    if (typeof v === "bigint") return v;
    if (typeof v === "number") return BigInt(Math.trunc(v));
    if (typeof v === "boolean") return v ? 1n : 0n;
    return BigInt(v);
  }

  class ProtoWriter {
    constructor() { this._buf = new Uint8Array(64); this._len = 0; }
    _ensure(n) {
      if (this._len + n <= this._buf.length) return;
      let size = this._buf.length * 2;
      while (size < this._len + n) size *= 2;
      const b = new Uint8Array(size);
      b.set(this._buf.subarray(0, this._len));
      this._buf = b;
    }
    _byte(b) { this._ensure(1); this._buf[this._len++] = b; }
    _raw(u) { this._ensure(u.length); this._buf.set(u, this._len); this._len += u.length; }
    _varint(v) {
      if (typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 0x7fffffff) {
        while (v > 127) { this._byte((v & 127) | 128); v >>>= 7; }
        this._byte(v);
        return;
      }
      let b = u64(toBig(v));
      while (b > 127n) { this._byte(Number(b & 127n) | 128); b >>= 7n; }
      this._byte(Number(b));
    }
    _tag(field, wire) { this._varint(field * 8 + wire); }
    varint(field, n) { this._tag(field, 0); this._varint(n); return this; }
    sint(field, n) {
      const v = i64(toBig(n));
      this._tag(field, 0);
      this._varint(u64((v << 1n) ^ (v >> 63n)));
      return this;
    }
    bool(field, b) { return this.varint(field, b ? 1 : 0); }
    fixed64(field, n) {
      this._tag(field, 1);
      let v = u64(toBig(n));
      for (let i = 0; i < 8; i++) { this._byte(Number(v & 255n)); v >>= 8n; }
      return this;
    }
    fixed32(field, n) {
      this._tag(field, 5);
      const v = u32(toBig(n));
      this._byte(v & 255); this._byte((v >>> 8) & 255); this._byte((v >>> 16) & 255); this._byte((v >>> 24) & 255);
      return this;
    }
    double(field, x) {
      this._tag(field, 1);
      const dv = new DataView(new ArrayBuffer(8));
      dv.setFloat64(0, Number(x), true);
      this._raw(new Uint8Array(dv.buffer));
      return this;
    }
    float(field, x) {
      this._tag(field, 5);
      const dv = new DataView(new ArrayBuffer(4));
      dv.setFloat32(0, Number(x), true);
      this._raw(new Uint8Array(dv.buffer));
      return this;
    }
    bytes(field, u) {
      u = toU8(u);
      this._tag(field, 2);
      this._varint(u.length);
      this._raw(u);
      return this;
    }
    string(field, s) { return this.bytes(field, Bytes.fromUtf8(s === undefined || s === null ? "" : s)); }
    message(field, w) { return this.bytes(field, w instanceof ProtoWriter ? w.finish() : toU8(w)); }
    finish() { return this._buf.slice(0, this._len); }
  }

  function first(v) { return Array.isArray(v) ? v[0] : v; }

  const Proto = {
    Writer: ProtoWriter,
    decode(bytes) {
      const u = toU8(bytes);
      const n = u.length;
      const out = {};
      let p = 0;
      function varint() {
        let lo = 0, shift = 0;
        while (shift < 28) {
          if (p >= n) throw new Error("protobuf 数据不完整");
          const b = u[p++];
          lo |= (b & 127) << shift;
          if (b < 128) return BigInt(lo >>> 0);
          shift += 7;
        }
        let r = BigInt(lo >>> 0), s = 28n;
        while (true) {
          if (p >= n) throw new Error("protobuf 数据不完整");
          const b = u[p++];
          r |= BigInt(b & 127) << s;
          if (b < 128) return u64(r);
          s += 7n;
          if (s > 63n) throw new Error("protobuf varint 过长");
        }
      }
      while (p < n) {
        const key = Number(varint());
        const field = Math.floor(key / 8);
        const wire = key & 7;
        let v;
        if (wire === 0) {
          v = varint();
        } else if (wire === 1) {
          if (p + 8 > n) throw new Error("protobuf 数据不完整");
          let r = 0n;
          for (let i = 7; i >= 0; i--) r = (r << 8n) | BigInt(u[p + i]);
          p += 8;
          v = r;
        } else if (wire === 2) {
          const len = Number(varint());
          if (p + len > n) throw new Error("protobuf 数据不完整");
          v = u.subarray(p, p + len);
          p += len;
        } else if (wire === 5) {
          if (p + 4 > n) throw new Error("protobuf 数据不完整");
          v = BigInt((u[p] | (u[p + 1] << 8) | (u[p + 2] << 16) | (u[p + 3] << 24)) >>> 0);
          p += 4;
        } else {
          throw new Error("不支持的 protobuf 类型 " + wire);
        }
        if (field === 0) throw new Error("protobuf 字段号不能为 0");
        (out[field] || (out[field] = [])).push(v);
      }
      return out;
    },
    str(v) {
      v = first(v);
      if (v === undefined || v === null) return "";
      if (v instanceof Uint8Array) return Bytes.toUtf8(v);
      return String(v);
    },
    num(v) {
      v = first(v);
      if (v === undefined || v === null) return 0;
      return Number(v);
    },
    signed(v) {
      v = first(v);
      if (v === undefined || v === null) return 0;
      return Number(i64(toBig(v)));
    },
    zigzag(v) {
      v = first(v);
      if (v === undefined || v === null) return 0;
      const b = u64(toBig(v));
      return Number((b >> 1n) ^ -(b & 1n));
    },
    bool(v) { return Proto.num(v) !== 0; },
    double(v) {
      v = first(v);
      if (v === undefined || v === null) return 0;
      const dv = new DataView(new ArrayBuffer(8));
      dv.setBigUint64(0, u64(toBig(v)), true);
      return dv.getFloat64(0, true);
    },
    float(v) {
      v = first(v);
      if (v === undefined || v === null) return 0;
      const dv = new DataView(new ArrayBuffer(4));
      dv.setUint32(0, u32(toBig(v)), true);
      return dv.getFloat32(0, true);
    },
  };
  G.Proto = Proto;

  // ------------------------------------------------------------------
  // Zip
  // ------------------------------------------------------------------
  async function zip(mode, bytes) {
    const r = await host("zip", { mode: mode, b64: Bytes.toBase64(toU8(bytes)) });
    return Bytes.fromBase64(r);
  }
  G.Zip = {
    gunzip(u) { return zip("gunzip", u); },
    inflate(u) { return zip("inflate", u); },
    inflateRaw(u) { return zip("inflateRaw", u); },
    brotli(u) { return zip("brotli", u); },
    gzip(u) { return zip("gzip", u); },
    deflate(u) { return zip("deflate", u); },
    deflateRaw(u) { return zip("deflateRaw", u); },
  };

  // ------------------------------------------------------------------
  // Hash（在 App 里算；字符串按 UTF-8）
  // ------------------------------------------------------------------
  function hashBytes(d) { return typeof d === "string" ? Bytes.fromUtf8(d) : toU8(d); }
  async function digest(alg, data, key) {
    const args = { alg: alg, b64: Bytes.toBase64(hashBytes(data)) };
    if (key !== undefined) args.key = Bytes.toBase64(hashBytes(key));
    return Bytes.fromBase64(await host("hash", args));
  }
  G.Hash = {
    md5(d) { return digest("md5", d); },
    sha1(d) { return digest("sha1", d); },
    sha256(d) { return digest("sha256", d); },
    sha512(d) { return digest("sha512", d); },
    hmac(alg, key, d) { return digest(String(alg).toLowerCase(), d, key); },
  };

  // ------------------------------------------------------------------
  // Settings（源的 settings 字段声明的设置项，用户在 App 里改；只读、同步）
  // ------------------------------------------------------------------
  let settingValues = {};
  function declaredDefault(key) {
    const list = G.__source && Array.isArray(G.__source.settings) ? G.__source.settings : [];
    for (const s of list) if (s && s.key === key) return s.default === undefined ? null : s.default;
    return null;
  }
  handlers.settings = function (c) {
    settingValues = c.values && typeof c.values === "object" ? c.values : {};
  };
  G.Settings = Object.freeze({
    get(key) {
      key = String(key);
      return Object.prototype.hasOwnProperty.call(settingValues, key) ? settingValues[key] : declaredDefault(key);
    },
    all() { return Object.assign({}, settingValues); },
  });

  // ------------------------------------------------------------------
  // Http
  // ------------------------------------------------------------------
  function encodePairs(obj) {
    if (typeof obj === "string") return obj;
    const parts = [];
    for (const k of Object.keys(obj)) {
      const v = obj[k];
      if (v === undefined || v === null) continue;
      const values = Array.isArray(v) ? v : [v];
      for (const x of values) {
        parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(typeof x === "object" ? JSON.stringify(x) : String(x)));
      }
    }
    return parts.join("&");
  }
  function hasHeader(headers, name) {
    for (const k of Object.keys(headers)) if (k.toLowerCase() === name) return true;
    return false;
  }

  const Http = {
    async request(opts) {
      if (typeof opts === "string") opts = { url: opts };
      opts = opts || {};
      let url = String(opts.url || "");
      if (opts.query !== undefined && opts.query !== null) {
        const q = encodePairs(opts.query);
        if (q) {
          const hash = url.indexOf("#");
          const tail = hash >= 0 ? url.slice(hash) : "";
          if (hash >= 0) url = url.slice(0, hash);
          url += (url.indexOf("?") >= 0 ? (/[?&]$/.test(url) ? "" : "&") : "?") + q + tail;
        }
      }
      const headers = {};
      if (opts.headers) {
        for (const k of Object.keys(opts.headers)) {
          const v = opts.headers[k];
          if (v !== undefined && v !== null) headers[k] = String(v);
        }
      }
      const responseType = opts.responseType || "text";
      if (responseType !== "text" && responseType !== "json" && responseType !== "bytes") {
        throw new Error("responseType 只能是 text、json 或 bytes");
      }
      const req = {
        url: url,
        method: String(opts.method || "GET").toUpperCase(),
        headers: headers,
        timeout: opts.timeout === undefined ? 15000 : Number(opts.timeout),
        followRedirects: opts.followRedirects !== false,
        bytes: responseType === "bytes",
      };
      const body = opts.body;
      if (body !== undefined && body !== null) {
        if (typeof body === "string") {
          req.text = body;
        } else if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
          req.b64 = Bytes.toBase64(toU8(body));
        } else if (typeof body === "object") {
          if (opts.contentType === "form") {
            req.text = encodePairs(body);
            if (!hasHeader(headers, "content-type")) headers["content-type"] = "application/x-www-form-urlencoded; charset=UTF-8";
          } else {
            req.text = JSON.stringify(body, replacer);
            if (!hasHeader(headers, "content-type")) headers["content-type"] = "application/json; charset=UTF-8";
          }
        } else {
          req.text = String(body);
        }
      }
      const r = await host("http", req);
      const res = { status: r.status, headers: r.headers, url: r.url, body: null };
      if (responseType === "bytes") {
        res.body = Bytes.fromBase64(r.b64 || "");
      } else if (responseType === "json") {
        res.text = r.text;
        try {
          res.body = JSON.parse(r.text);
        } catch (e) {
          if (r.status >= 200 && r.status < 300) {
            const err = new Error("返回的内容不是 JSON（HTTP " + r.status + "）：" + String(r.text).slice(0, 120));
            err.status = r.status;
            throw err;
          }
        }
      } else {
        res.body = r.text;
      }
      return res;
    },
    get(url, opts) {
      return Http.request(Object.assign({}, opts, { url: url, method: (opts && opts.method) || "GET" }));
    },
    post(url, body, opts) {
      return Http.request(Object.assign({}, opts, { url: url, method: (opts && opts.method) || "POST", body: body }));
    },
    getCookies(url) { return host("getCookies", { url: String(url) }); },
    setCookies(url, cookies) { return host("setCookies", { url: String(url), cookies: String(cookies) }); },
  };
  G.Http = Http;

  // ------------------------------------------------------------------
  // Storage
  // ------------------------------------------------------------------
  G.Storage = {
    get(key) { return host("storageGet", { key: String(key) }); },
    set(key, value) { return host("storageSet", { key: String(key), value: value === undefined ? null : value }); },
    remove(key) { return host("storageRemove", { key: String(key) }); },
  };

  // ------------------------------------------------------------------
  // log / console
  // ------------------------------------------------------------------
  function fmt(v) {
    if (typeof v === "string") return v;
    if (v instanceof Error) return v.stack ? v.message + "\n" + v.stack : String(v.message);
    if (v instanceof Uint8Array) {
      return "Uint8Array(" + v.length + ") " + Bytes.toHex(v.subarray(0, 64)) + (v.length > 64 ? "…" : "");
    }
    if (typeof v === "bigint") return v.toString() + "n";
    if (typeof v === "function") return "[function " + (v.name || "") + "]";
    if (v && typeof v === "object") {
      try { return JSON.stringify(v, replacer); } catch (_) { return String(v); }
    }
    return String(v);
  }
  function logAt(level) {
    return function (...args) { post("log", { level: level, msg: args.map(fmt).join(" ") }); };
  }
  G.log = logAt("info");
  G.console = {
    log: logAt("info"), info: logAt("info"), debug: logAt("debug"),
    warn: logAt("warn"), error: logAt("error"),
  };

  // ------------------------------------------------------------------
  // 定时器（由宿主计时）
  // ------------------------------------------------------------------
  const timers = new Map();
  let timerSeq = 0;
  function addTimer(fn, ms, repeat, args, session) {
    noIoInRewrite("开定时器");
    if (typeof fn !== "function") throw new TypeError("定时器需要传入函数");
    const id = ++timerSeq;
    ms = Math.max(0, Number(ms) || 0);
    if (repeat && ms < 10) ms = 10;
    timers.set(id, { fn: fn, args: args, repeat: repeat, session: session });
    if (session) session._timers.add(id);
    post("timer", { id: id, ms: ms, repeat: repeat, sid: session ? session._sid : 0 });
    return id;
  }
  function clearTimer(id) {
    const t = timers.get(id);
    if (!t) return;
    timers.delete(id);
    if (t.session) t.session._timers.delete(id);
    post("clearTimer", { id: id });
  }
  handlers.timer = function (c) {
    const t = timers.get(c.id);
    if (!t) return;
    if (!t.repeat) {
      timers.delete(c.id);
      if (t.session) t.session._timers.delete(c.id);
    }
    try {
      settle(t.fn.apply(undefined, t.args), "定时器出错");
    } catch (e) {
      logError("定时器出错", e);
    }
  };
  G.setTimeout = function (fn, ms, ...args) { return addTimer(fn, ms, false, args, null); };
  G.setInterval = function (fn, ms, ...args) { return addTimer(fn, ms, true, args, null); };
  G.clearTimeout = function (id) { clearTimer(id); };
  G.clearInterval = function (id) { clearTimer(id); };

  // ------------------------------------------------------------------
  // App、工具
  // ------------------------------------------------------------------
  // features：接口 v1 之后加的可选功能（"emotes"、"login"、"hlsFix"、"history"、
  // "hlsRewrite"、"settings"、"hash"、"overrides"），脚本用它判断 App 支不支持
  let app = Object.freeze({ version: "", platform: "", apiVersion: 1, features: Object.freeze([]) });
  Object.defineProperty(G, "App", { get() { return app; }, configurable: false });

  handlers.setup = function (c) {
    const features = Array.isArray(c.features) ? c.features.map(String) : [];
    app = Object.freeze({
      version: String(c.version || ""), platform: String(c.platform || ""), apiVersion: c.apiVersion | 0,
      features: Object.freeze(features),
    });
    if (Array.isArray(c.seed) && c.seed.length === 4) {
      s0 = c.seed[0] | 0; s1 = c.seed[1] | 0; s2 = c.seed[2] | 0; s3 = c.seed[3] | 0;
      if ((s0 | s1 | s2 | s3) === 0) s3 = 1;
    }
  };

  const ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  G.randomId = function (len) {
    len = len === undefined ? 16 : Math.max(0, len | 0);
    let s = "";
    for (let i = 0; i < len; i++) s += ID_CHARS[nextU32() % 62];
    return s;
  };
  G.uuid = function () {
    const b = new Uint8Array(16);
    for (let i = 0; i < 16; i += 4) {
      const r = nextU32();
      b[i] = r & 255; b[i + 1] = (r >>> 8) & 255; b[i + 2] = (r >>> 16) & 255; b[i + 3] = r >>> 24;
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = Bytes.toHex(b);
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  };
  G.crypto = {
    getRandomValues(arr) {
      const u = new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength);
      for (let i = 0; i < u.length; i++) u[i] = nextU32() & 255;
      return arr;
    },
    randomUUID() { return G.uuid(); },
  };
  G.__randomU32 = nextU32;

  // ------------------------------------------------------------------
  // LiveSource 基类
  // ------------------------------------------------------------------
  class LiveSource {
    constructor() {
      this.apiVersion = 1;
      this.domains = [];
      this.links = [];
    }
  }
  G.LiveSource = LiveSource;

  const METHODS = ["recommend", "categories", "categoryRooms", "search", "searchAnchors", "room",
    "liveStatus", "qualities", "playUrls", "avPlayerUrls", "superChats", "suggest", "resolve", "account"];

  function findClass(name) {
    let cls;
    try { cls = (0, eval)(name); } catch (_) { return null; }
    if (typeof cls === "function" && cls.prototype instanceof LiveSource) return cls;
    return null;
  }

  // 读取元数据；create 为 true 时同时把实例设为当前源
  G.__inspect = function (namesJson, create) {
    const names = JSON.parse(namesJson);
    const found = [];
    for (const n of names) {
      if (found.indexOf(n) < 0 && findClass(n)) found.push(n);
    }
    if (found.length === 0) return JSON.stringify({ error: "没有找到继承 LiveSource 的类（class Xxx extends LiveSource）" });
    if (found.length > 1) return JSON.stringify({ error: "只能有一个继承 LiveSource 的类，找到了 " + found.join("、") });
    const Cls = findClass(found[0]);
    const s = new Cls();
    if (create === "1") G.__source = s;
    const pick = function (v) { return v === undefined || v === null ? null : v; };
    const dm = s.danmaku;
    return JSON.stringify({
      className: found[0],
      key: pick(s.key), name: pick(s.name), version: pick(s.version), apiVersion: pick(s.apiVersion),
      url: pick(s.url), icon: pick(s.icon), description: pick(s.description),
      domains: pick(s.domains), links: pick(s.links),
      methods: METHODS.filter(function (m) { return typeof s[m] === "function"; }),
      danmaku: !!(dm && typeof dm.start === "function"),
      login: pick(s.login),
      hlsRewrite: !!(s.hls && typeof s.hls.rewrite === "function"),
      settings: pick(s.settings),
      overrides: pick(s.overrides), useAccount: pick(s.useAccount),
    }, replacer);
  };

  // hls.rewrite(text, info)：本机中转每次取到播放列表后同步调用（宿主限时约 200 毫秒），
  // 返回改过的文字；返回 null / undefined 表示不改。不能是 async，不能发请求
  G.__hlsRewrite = function (text, infoJson) {
    const src = G.__source;
    const h = src && src.hls;
    if (!h || typeof h.rewrite !== "function") throw new Error("直播源没有 hls.rewrite");
    rewriting = true;
    const out = h.rewrite.call(h, String(text), JSON.parse(infoJson));
    rewriting = false;
    if (out === undefined || out === null) return null;
    if (typeof out !== "string") throw new Error("hls.rewrite 必须同步返回字符串（不能是 Promise）");
    return out;
  };
  // 宿主在每次调用后执行（被中断时 finally 不会执行）
  G.__hlsRewriteEnd = function () { rewriting = false; return null; };

  handlers.call = function (c) {
    const src = G.__source;
    Promise.resolve().then(function () {
      if (!src) throw new Error("直播源还没有加载");
      const fn = src[c.m];
      if (typeof fn !== "function") throw new Error("直播源没有实现 " + c.m + "()");
      return fn.apply(src, c.a || []);
    }).then(function (v) { postResult(c.id, v); }, function (e) { postThrow(c.id, e); });
  };

  // ------------------------------------------------------------------
  // 弹幕会话
  // ------------------------------------------------------------------
  const sessions = new Map();
  const sockets = new Map();
  let wsSeq = 0;

  class LiveWebSocket {
    constructor(id, session, url) {
      this.id = id;
      this.url = url;
      this._session = session;
      this._queue = [];
      this._onMessage = null;
      this.onClose = null;
      this.closed = false;
    }
    get onMessage() { return this._onMessage; }
    set onMessage(fn) {
      this._onMessage = fn;
      if (typeof fn === "function" && this._queue.length) {
        const q = this._queue;
        this._queue = [];
        for (const d of q) deliver(this, d);
      }
    }
    send(data) {
      if (this.closed) return false;
      if (typeof data === "string") post("wsSend", { ws: this.id, text: data });
      else post("wsSend", { ws: this.id, b64: Bytes.toBase64(toU8(data)) });
      return true;
    }
    close(code, reason) {
      if (this.closed) return;
      this.closed = true;
      sockets.delete(this.id);
      this._session._sockets.delete(this.id);
      post("wsClose", { ws: this.id, code: code || 1000, reason: reason ? String(reason) : "" });
    }
  }

  function deliver(ws, data) {
    try {
      settle(ws._onMessage(data), "处理弹幕消息出错");
    } catch (e) {
      logError("处理弹幕消息出错", e);
    }
  }

  handlers.ws = function (c) {
    const ws = sockets.get(c.ws);
    if (!ws || ws.closed) return;
    const data = c.b64 !== undefined ? Bytes.fromBase64(c.b64) : c.text;
    if (typeof ws._onMessage === "function") {
      deliver(ws, data);
    } else {
      ws._queue.push(data);
      if (ws._queue.length > 2000) ws._queue.shift();
    }
  };

  handlers.wsClosed = function (c) {
    const ws = sockets.get(c.ws);
    if (!ws) return;
    sockets.delete(c.ws);
    ws._session._sockets.delete(c.ws);
    if (ws.closed) return;
    ws.closed = true;
    if (typeof ws.onClose === "function") {
      try {
        settle(ws.onClose(c.code, c.reason), "ws.onClose 出错");
      } catch (e) {
        logError("ws.onClose 出错", e);
      }
    }
  };

  class DanmakuSession {
    constructor(sid) {
      this._sid = sid;
      this._alive = true;
      this._ready = false;
      this._timers = new Set();
      this._sockets = new Map();
      this.data = {};
      this.source = G.__source;
    }
    get alive() { return this._alive; }
    emit(messages) {
      if (!this._alive || messages === undefined || messages === null) return;
      if (!Array.isArray(messages)) messages = [messages];
      if (messages.length === 0) return;
      post("emit", { sid: this._sid, messages: messages });
    }
    ready() {
      if (!this._alive || this._ready) return;
      this._ready = true;
      post("ready", { sid: this._sid });
    }
    fail(message) {
      if (!this._alive) return;
      post("fail", { sid: this._sid, message: message === undefined || message === null ? "" : errMsg(message) });
    }
    async websocket(url, opts) {
      if (!this._alive) throw new Error("弹幕会话已结束");
      opts = opts || {};
      const id = ++wsSeq;
      const ws = new LiveWebSocket(id, this, String(url));
      sockets.set(id, ws);
      this._sockets.set(id, ws);
      const headers = {};
      if (opts.headers) {
        for (const k of Object.keys(opts.headers)) {
          const v = opts.headers[k];
          if (v !== undefined && v !== null) headers[k] = String(v);
        }
      }
      let protocols = opts.protocols || [];
      if (typeof protocols === "string") protocols = [protocols];
      try {
        await host("wsOpen", {
          sid: this._sid, ws: id, url: String(url), headers: headers, protocols: protocols.map(String),
          timeout: opts.timeout === undefined ? 15000 : Number(opts.timeout),
        });
      } catch (e) {
        sockets.delete(id);
        this._sockets.delete(id);
        ws.closed = true;
        throw e;
      }
      if (!this._alive) {
        ws.closed = true;
        throw new Error("弹幕会话已结束");
      }
      return ws;
    }
    setTimeout(fn, ms, ...args) { return this._alive ? addTimer(fn, ms, false, args, this) : 0; }
    setInterval(fn, ms, ...args) { return this._alive ? addTimer(fn, ms, true, args, this) : 0; }
    clearTimeout(id) { clearTimer(id); }
    clearInterval(id) { clearTimer(id); }
  }

  handlers.dmStart = function (c) {
    const src = G.__source;
    const s = new DanmakuSession(c.sid);
    sessions.set(c.sid, s);
    Promise.resolve().then(function () {
      const dm = src && src.danmaku;
      if (!dm || typeof dm.start !== "function") throw new Error("直播源不支持弹幕");
      return dm.start(c.room, s);
    }).then(function () { postResult(c.id, null); }, function (e) { postThrow(c.id, e); });
  };

  // 结束会话：先调用 danmaku.stop（这时连接还在），再清掉定时器和连接
  handlers.dmEnd = function (c) {
    const s = sessions.get(c.sid);
    if (!s) {
      post("sessionClosed", { sid: c.sid });
      return;
    }
    sessions.delete(c.sid);
    const finish = function () {
      s._alive = false;
      for (const id of s._timers) timers.delete(id);
      s._timers.clear();
      for (const ws of s._sockets.values()) { ws.closed = true; sockets.delete(ws.id); }
      s._sockets.clear();
      post("sessionClosed", { sid: c.sid });
    };
    const src = G.__source;
    Promise.resolve().then(function () {
      const dm = src && src.danmaku;
      if (dm && typeof dm.stop === "function") return dm.stop(s);
      return null;
    }).then(finish, function (e) { logError("danmaku.stop 出错", e); finish(); });
  };
})(globalThis);
''';

/// CryptoJS 加载后执行：随机数改用宿主种子的生成器（引擎里没有 crypto 模块）
const String kLiveSourcePreludeAfterCrypto = r'''
(function (G) {
  if (G.CryptoJS && G.CryptoJS.lib && G.CryptoJS.lib.WordArray) {
    const WordArray = G.CryptoJS.lib.WordArray;
    WordArray.random = function (n) {
      const words = [];
      for (let i = 0; i < n; i += 4) words.push(G.__randomU32() | 0);
      return WordArray.create(words, n);
    };
  }
})(globalThis);
''';
