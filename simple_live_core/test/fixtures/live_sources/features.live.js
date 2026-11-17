// 测试用直播源：全局 API（Http、Proto、Zip、CryptoJS、Storage、定时器…）
const BASE = "{{BASE}}";

// 顶层代码在加载元数据时也会执行一遍：这里的请求不会真的发出去
Http.get(BASE + "/toplevel");

class Features extends LiveSource {
  key = "test_features";
  name = "功能测试";
  version = "1.0.0";
  domains = ["127.0.0.1"];

  async httpJson() {
    const r = await Http.get(BASE + "/rooms", { query: { page: 2, q: "中 文" }, responseType: "json" });
    return { status: r.status, body: r.body, type: r.headers["content-type"] };
  }

  async httpPostJson() {
    const r = await Http.post(BASE + "/echo", { a: 1, 中文: "值" }, { responseType: "json" });
    return r.body;
  }

  async httpPostForm() {
    const r = await Http.post(BASE + "/echo?x=1", { a: "1 2", b: ["x", "y"], n: null }, {
      contentType: "form", responseType: "json", headers: { "X-Test": "yes", "User-Agent": "TestAgent/1.0" },
    });
    return r.body;
  }

  async httpPutBytes() {
    const r = await Http.request({
      url: BASE + "/echo", method: "PUT", body: Bytes.fromHex("00ff10"),
      headers: { "content-type": "application/octet-stream" }, responseType: "json",
    });
    return r.body;
  }

  async httpBytes() {
    const r = await Http.get(BASE + "/bytes", { responseType: "bytes" });
    return { len: r.body.length, first: r.body[0], last: r.body[255], isU8: r.body instanceof Uint8Array };
  }

  async http404() {
    const r = await Http.get(BASE + "/notfound");
    const j = await Http.get(BASE + "/notfound", { responseType: "json" });
    return { status: r.status, body: r.body, jsonBody: j.body, jsonText: j.text };
  }

  async cookies() {
    await Http.get(BASE + "/setcookie");
    const echoed = (await Http.get(BASE + "/cookie")).body;
    await Http.setCookies(BASE, "manual=1; other=2");
    const jar = await Http.getCookies(BASE + "/x");
    const echoed2 = (await Http.get(BASE + "/cookie", { headers: { Cookie: "extra=3" } })).body;
    return { echoed, jar, echoed2 };
  }

  async redirect() {
    const r = await Http.get(BASE + "/redirect", { responseType: "json" });
    const p = await Http.post(BASE + "/redirect", "body", { responseType: "json" });
    return { status: r.status, url: r.url, method: r.body.method, postMethod: p.body.method };
  }

  async noRedirect() {
    const r = await Http.get(BASE + "/redirect", { followRedirects: false });
    return { status: r.status, location: r.headers.location };
  }

  async forbidden() { await Http.get("https://not-allowed.example.org/x"); }
  async forbiddenRedirect() { await Http.get(BASE + "/redirect-out"); }
  async gzipResponse() { return (await Http.get(BASE + "/gzip")).body; }
  async httpTimeout() { await Http.get(BASE + "/slow", { timeout: 300 }); }

  proto() {
    const inner = new Proto.Writer().bool(1, true).string(2, "内层");
    const w = new Proto.Writer()
      .varint(1, 150)
      .string(2, "直播")
      .sint(3, -5)
      .fixed64(4, 2n ** 63n)
      .message(5, inner)
      .varint(6, -1)
      .bytes(7, Bytes.fromHex("0102"))
      .varint(1, 2n ** 40n)
      .fixed32(8, 0xdeadbeef)
      .double(9, 1.5);
    const bytes = w.finish();
    const d = Proto.decode(bytes);
    const i = Proto.decode(d[5][0]);
    return {
      hex: Bytes.toHex(bytes.subarray(0, 3)),
      v1: d[1].map(Proto.num),
      s2: Proto.str(d[2]),
      z3: Proto.zigzag(d[3]),
      f4: d[4][0].toString(),
      inner: [Proto.bool(i[1]), Proto.str(i[2])],
      n6: Proto.signed(d[6]),
      b7: Bytes.toHex(d[7][0]),
      f8: Proto.num(d[8]),
      d9: Proto.double(d[9]),
      missing: [Proto.num(d[99]), Proto.str(d[99])],
    };
  }

  async zip() {
    const data = Bytes.fromUtf8("压缩测试".repeat(20));
    const gz = await Zip.gzip(data);
    const df = await Zip.deflate(data);
    const raw = await Zip.deflateRaw(data);
    // brotli 压缩的 "time"
    const br = Bytes.fromHex("1b030000000080e3b40d0000075b26314002" + "00e04e1b4102");
    return {
      gzMagic: Bytes.toHex(gz.subarray(0, 2)),
      gunzip: Bytes.toUtf8(await Zip.gunzip(gz)),
      inflate: Bytes.toUtf8(await Zip.inflate(df)),
      inflateRaw: Bytes.toUtf8(await Zip.inflateRaw(raw)),
      brotli: Bytes.toUtf8(await Zip.brotli(br)),
    };
  }

  async gunzipBase64(b64) { return Bytes.toUtf8(await Zip.gunzip(Bytes.fromBase64(b64))); }
  async badZip() { await Zip.gunzip(Bytes.fromHex("0001020304")); }

  crypto() {
    const key = CryptoJS.enc.Hex.parse("000102030405060708090a0b0c0d0e0f");
    const ecb = CryptoJS.AES.encrypt(CryptoJS.enc.Hex.parse("00112233445566778899aabbccddeeff"), key,
      { mode: CryptoJS.mode.ECB, padding: CryptoJS.pad.NoPadding }).ciphertext.toString();
    const iv = Bytes.toWordArray(Bytes.fromUtf8("1234567890abcdef"));
    const cbc = CryptoJS.AES.encrypt("你好，直播", key, { iv }).toString();
    const plain = CryptoJS.AES.decrypt(cbc, key, { iv }).toString(CryptoJS.enc.Utf8);
    const pass = CryptoJS.AES.encrypt("口令加密", "secret").toString();
    return {
      md5: CryptoJS.MD5("hello").toString(),
      sha256: CryptoJS.SHA256("abc").toString(),
      hmac: CryptoJS.HmacSHA256("data", "key").toString(),
      ecb,
      plain,
      pass: CryptoJS.AES.decrypt(pass, "secret").toString(CryptoJS.enc.Utf8),
      wordArray: Bytes.toHex(Bytes.fromWordArray(Bytes.toWordArray(Bytes.fromHex("0102030405")))),
      base64: CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse("直播")),
    };
  }

  async storage() {
    await Storage.set("a", { x: 1, s: "中文" });
    const a = await Storage.get("a");
    await Storage.set("b", 2);
    await Storage.remove("b");
    const b = await Storage.get("b");
    return { a, b };
  }

  async storageGet(key) { return await Storage.get(key); }

  timers() {
    return new Promise((resolve) => {
      const order = [];
      setTimeout(() => order.push("t60"), 60);
      setTimeout((x) => order.push("t5" + x), 5, "!");
      const cancelled = setTimeout(() => order.push("never"), 20);
      clearTimeout(cancelled);
      let n = 0;
      const iv = setInterval(() => {
        n++;
        order.push("i" + n);
        if (n === 3) {
          clearInterval(iv);
          setTimeout(() => resolve(order), 120);
        }
      }, 15);
    });
  }

  textCodec() {
    const enc = new TextEncoder().encode("直播abc😀");
    return {
      len: enc.length,
      back: new TextDecoder().decode(enc),
      b64: btoa("hello"),
      atob: atob("aGVsbG8="),
      bytesB64: Bytes.toBase64(Bytes.fromUtf8("直播")),
      fromB64: Bytes.toUtf8(Bytes.fromBase64("55u05pKt")),
      concat: Bytes.toHex(Bytes.concat(Bytes.fromHex("01"), new Uint8Array([2, 3]), [4])),
    };
  }

  misc() {
    return {
      app: { version: App.version, platform: App.platform, apiVersion: App.apiVersion },
      rid: randomId(12).length,
      uuid: /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid()),
    };
  }

  logs() {
    log("日志", 1, { a: 2 }, Bytes.fromHex("abcd"));
    console.warn("警告");
    return true;
  }
}
