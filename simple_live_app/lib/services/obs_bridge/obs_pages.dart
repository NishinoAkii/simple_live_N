import 'dart:convert';
import 'package:simple_live_app/i18n/i18n.dart';

/// 录屏接口的网页：首页（地址与说明）、弹幕层、聊天框、醒目留言。
/// 都是一个文件，不用外部脚本和字体；背景透明，断开后自动重连，换直播间时清空
class ObsPages {
  ObsPages._();

  /// 转义 & < > "（不转义 /，地址保持原样可读）
  static const HtmlEscape _html = HtmlEscape(HtmlEscapeMode.attribute);

  /// 页面共用的脚本：读地址参数、带上令牌、读应用的弹幕设置、
  /// WebSocket 自动重连、按表情切开文字
  static const String _common = r'''
const Q = new URLSearchParams(location.search);
const TOKEN = Q.get('token') || '';
function withToken(p) {
  if (!TOKEN) return p;
  return p + (p.indexOf('?') < 0 ? '?' : '&') + 'token=' + encodeURIComponent(TOKEN);
}
function num(name, def, min, max) {
  const v = parseFloat(Q.get(name));
  if (isNaN(v)) return def;
  return Math.min(max, Math.max(min, v));
}
function flag(name, def) {
  const v = Q.get(name);
  if (v === null || v === '') return def;
  return !(v === '0' || v === 'false' || v === 'no' || v === 'off');
}
async function loadConfig() {
  for (let i = 0; i < 3; i++) {
    try {
      const r = await fetch(withToken('/api/config'), { cache: 'no-store' });
      if (r.ok) return await r.json();
    } catch (e) {}
    await new Promise(r => setTimeout(r, 1000));
  }
  return {};
}
function roomKey(r) { return r ? r.site + '|' + r.roomId : ''; }
// 连接 WebSocket，断开后 1~10 秒重连；onRoom 在直播间变化（含重连后发现变了）时调用，
// onConnected 在每次连上、补发消息之前调用
function connect(query, onEvent, onRoom, onConnected) {
  let delay = 1000;
  let current = null;
  function open() {
    let first = true;
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    let ws;
    try {
      ws = new WebSocket(proto + '//' + location.host + withToken('/ws' + (query || '')));
    } catch (e) {
      setTimeout(open, delay);
      return;
    }
    ws.onopen = () => { delay = 1000; };
    ws.onmessage = (m) => {
      let ev;
      try { ev = JSON.parse(m.data); } catch (e) { return; }
      if (ev.type === 'room') {
        if (first) {
          first = false;
          if (onConnected) onConnected();
        }
        const key = roomKey(ev.room);
        if (key !== current) {
          current = key;
          onRoom(ev.room);
        }
        return;
      }
      if (ev.type === 'clear') {
        onRoom(null, true);
        return;
      }
      onEvent(ev);
    };
    ws.onclose = () => {
      setTimeout(open, delay);
      delay = Math.min(delay * 2, 10000);
    };
    ws.onerror = () => { try { ws.close(); } catch (e) {} };
  }
  open();
}
function isWord(c) {
  return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95;
}
// 与应用里的 splitLiveEmotes 相同：长的优先，字母数字组成的表情名前后不能紧挨字母数字
function splitEmotes(text, emotes) {
  const map = new Map();
  for (const e of emotes || []) {
    if (e && e.text && e.url && !map.has(e.text)) map.set(e.text, e);
  }
  if (!map.size || !text) return [{ text: text || '' }];
  const codes = Array.from(map.keys()).sort((a, b) => b.length - a.length);
  const parts = [];
  let buf = '';
  let i = 0;
  while (i < text.length) {
    let m = null;
    for (const code of codes) {
      if (!text.startsWith(code, i)) continue;
      const end = i + code.length;
      if (isWord(code.charCodeAt(0)) && i > 0 && isWord(text.charCodeAt(i - 1))) continue;
      if (isWord(code.charCodeAt(code.length - 1)) && end < text.length && isWord(text.charCodeAt(end))) continue;
      m = code;
      break;
    }
    if (m === null) { buf += text[i]; i++; continue; }
    if (buf) { parts.push({ text: buf }); buf = ''; }
    parts.push({ text: m, emote: map.get(m) });
    i += m.length;
  }
  if (buf) parts.push({ text: buf });
  return parts;
}
function emoteImg(e, h, cls) {
  const img = document.createElement('img');
  img.className = cls;
  img.alt = e.text || '';
  img.referrerPolicy = 'no-referrer';
  img.style.height = h + 'px';
  img.style.width = ((e.width > 0 && e.height > 0) ? h * e.width / e.height : h) + 'px';
  img.onerror = () => { img.replaceWith(document.createTextNode(img.alt)); };
  img.src = e.url;
  return img;
}
// 把消息内容放进 el：表情换成图片，整条是大表情时显示大图
function fillContent(el, text, emotes, sticker, images, emoteH, stickerH) {
  if (images && sticker && sticker.url) {
    el.appendChild(emoteImg(sticker, stickerH, 'sticker'));
    return;
  }
  if (!images) { el.appendChild(document.createTextNode(text || '')); return; }
  for (const part of splitEmotes(text, emotes)) {
    if (part.emote) el.appendChild(emoteImg(part.emote, emoteH, 'emote'));
    else el.appendChild(document.createTextNode(part.text));
  }
}
function strokeShadow(s, color) {
  if (!(s > 0)) return 'none';
  const c = color || 'rgba(0,0,0,0.85)';
  const d = Math.round(s * 10) / 10;
  return [d + 'px 0 ' + c, -d + 'px 0 ' + c, '0 ' + d + 'px ' + c, '0 ' + -d + 'px ' + c,
    d + 'px ' + d + 'px ' + c, -d + 'px ' + -d + 'px ' + c, d + 'px ' + -d + 'px ' + c,
    -d + 'px ' + d + 'px ' + c].join(',');
}
''';

  static String _page(String title, String css, String body, String script) =>
      '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
body { font-family: "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", sans-serif; }
$css
</style>
</head>
<body>
$body
<script>
$_common
$script
</script>
</body>
</html>
''';

  /// 弹幕层：和应用里一样从右往左滚动，分行不重叠
  static final String overlay = _page(
    "SimpleLive 弹幕",
    r'''
#stage { position: fixed; left: 0; top: 0; right: 0; bottom: 0; pointer-events: none; }
.dm { position: absolute; left: 0; top: 0; white-space: nowrap; will-change: transform; }
.dm img { vertical-align: middle; object-fit: contain; }
''',
    '<div id="stage"></div>',
    r'''
(async function () {
  const cfg = await loadConfig();
  const stage = document.getElementById('stage');
  const baseSize = cfg.size || 16;
  // 不填 size 时按应用的弹幕大小随画面高度放大（应用里的大小以 540 高为准）
  const size = num('size', Math.round(baseSize * Math.max(1, window.innerHeight / 540)), 6, 300);
  const speed = num('speed', cfg.speed || 10, 1, 120);
  const area = num('area', cfg.area != null ? cfg.area : 0.8, 0.05, 1);
  const opacity = num('opacity', cfg.opacity != null ? cfg.opacity : 1, 0, 1);
  const stroke = num('stroke', (cfg.stroke != null ? cfg.stroke : 2) * size / baseSize / 2, 0, 20);
  const images = flag('emotes', cfg.emoteImage !== false);
  const emoteScale = num('emoteScale', cfg.emoteScale || 1, 0.3, 4);
  const weight = num('weight', cfg.fontWeight != null ? (cfg.fontWeight + 1) * 100 : 500, 100, 900);
  const all = flag('all', false);
  const laneH = Math.ceil(size * 1.25);
  const gap = size / 2;
  stage.style.opacity = opacity;
  stage.style.fontSize = size + 'px';
  stage.style.lineHeight = laneH + 'px';
  stage.style.fontWeight = weight;
  stage.style.textShadow = strokeShadow(stroke);
  let lanes = [];
  function laneCount() { return Math.max(1, Math.floor(window.innerHeight * area / laneH)); }
  function fits(p, now, w) {
    if (!p) return true;
    const W = window.innerWidth;
    const D = speed * 1000;
    const vp = (W + p.w) / D;
    const vn = (W + w) / D;
    const el = now - p.start;
    if (el * vp < p.w + gap) return false;
    if (vn * (p.start + D - now) > W - gap) return false;
    return true;
  }
  function allocate(now, w, k) {
    const n = laneCount();
    for (let i = 0; i + k <= n; i++) {
      let ok = true;
      for (let j = i; j < i + k; j++) {
        if (!fits(lanes[j], now, w)) { ok = false; break; }
      }
      if (ok) return i;
    }
    if (!all) return -1;
    let best = 0;
    let bestT = Infinity;
    for (let i = 0; i + k <= n; i++) {
      const t = lanes[i] ? lanes[i].start : -Infinity;
      if (t < bestT) { bestT = t; best = i; }
    }
    return best;
  }
  function add(ev) {
    if (stage.childElementCount > 500) return;
    const el = document.createElement('div');
    el.className = 'dm';
    el.style.color = ev.color || '#ffffff';
    fillContent(el, ev.text, ev.emotes, ev.sticker, images, size * 1.15 * emoteScale, size * 2.4 * emoteScale);
    el.style.visibility = 'hidden';
    el.style.transform = 'translateX(' + window.innerWidth + 'px)';
    stage.appendChild(el);
    const w = el.offsetWidth;
    const k = Math.max(1, Math.ceil(el.offsetHeight / laneH - 0.05));
    const now = performance.now();
    const lane = allocate(now, w, k);
    if (lane < 0) { el.remove(); return; }
    for (let j = lane; j < lane + k; j++) lanes[j] = { start: now, w: w };
    el.style.top = (lane * laneH) + 'px';
    el.style.visibility = 'visible';
    const anim = el.animate(
      [{ transform: 'translateX(' + window.innerWidth + 'px)' }, { transform: 'translateX(' + (-w) + 'px)' }],
      { duration: speed * 1000, easing: 'linear' });
    anim.onfinish = () => el.remove();
  }
  function clear() { stage.textContent = ''; lanes = []; }
  connect('', (ev) => { if (ev.type === 'chat') add(ev); }, () => clear());
})();
''',
  );

  /// 聊天框：最新的在最下面
  static final String chat = _page(
    "SimpleLive 聊天",
    r'''
#list { position: fixed; left: 0; right: 0; bottom: 0; display: flex; flex-direction: column; justify-content: flex-end; padding: 8px; box-sizing: border-box; max-height: 100%; overflow: hidden; }
.row { margin: 2px 0; color: #fff; word-break: break-word; transition: opacity .5s; }
.row.out { opacity: 0; }
.row img { vertical-align: middle; object-fit: contain; }
.row .face { border-radius: 50%; margin-right: .35em; }
.row .name { color: #8fd3ff; margin-right: .3em; }
.row.sc { background: rgba(255, 196, 0, .25); border-radius: 6px; padding: 2px 6px; }
.row.sc .price { color: #ffd54f; margin-right: .3em; }
''',
    '<div id="list"></div>',
    r'''
(async function () {
  const cfg = await loadConfig();
  const list = document.getElementById('list');
  const size = num('size', 20, 8, 160);
  const lines = Math.round(num('lines', 20, 1, 300));
  const images = flag('emotes', cfg.emoteImage !== false);
  const faces = flag('faces', cfg.chatShowFace !== false);
  const showSc = flag('sc', true);
  const fade = num('fade', 0, 0, 3600);
  const emoteScale = num('emoteScale', cfg.emoteScale || 1, 0.3, 4);
  const stroke = num('stroke', Math.max(1, size / 12), 0, 20);
  list.style.fontSize = size + 'px';
  list.style.lineHeight = '1.35';
  list.style.textShadow = strokeShadow(stroke);
  function add(ev) {
    const row = document.createElement('div');
    row.className = 'row';
    if (faces && ev.face) {
      const img = emoteImg({ url: ev.face, text: '' }, size * 1.2, 'face');
      img.onerror = () => img.remove();
      row.appendChild(img);
    }
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = (ev.user || '') + '：';
    if (ev.type === 'superchat') {
      row.classList.add('sc');
      const price = document.createElement('span');
      price.className = 'price';
      price.textContent = ev.priceText || '';
      row.appendChild(price);
    }
    row.appendChild(name);
    const text = document.createElement('span');
    text.className = 'text';
    fillContent(text, ev.text, ev.emotes, ev.sticker, images, size * 1.15 * emoteScale, size * 2.4 * emoteScale);
    row.appendChild(text);
    list.appendChild(row);
    while (list.childElementCount > lines) list.firstElementChild.remove();
    if (fade > 0) {
      setTimeout(() => { row.classList.add('out'); setTimeout(() => row.remove(), 600); }, fade * 1000);
    }
  }
  // 每次连上都会补发最近的聊天，先清空免得重复
  const clear = () => { list.textContent = ''; };
  connect('?history=' + lines, (ev) => {
    if (ev.type === 'chat' || (showSc && ev.type === 'superchat')) add(ev);
  }, clear, clear);
})();
''',
  );

  /// 醒目留言卡片：每张显示到它的结束时间
  static final String superChat = _page(
    "SimpleLive 醒目留言",
    r'''
#list { position: fixed; left: 0; right: 0; bottom: 0; display: flex; flex-direction: column; justify-content: flex-end; padding: 8px; box-sizing: border-box; max-height: 100%; overflow: hidden; }
.card { margin: 4px 0; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,.35); transition: opacity .5s; }
.card.out { opacity: 0; }
.head { display: flex; align-items: center; padding: .4em .6em; color: #333; }
.head .face { border-radius: 50%; margin-right: .5em; object-fit: cover; }
.head .who { flex: 1; min-width: 0; }
.head .user { font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.head .price { font-size: .8em; opacity: .8; }
.head .left { font-size: .75em; opacity: .7; margin-left: .5em; }
.body { padding: .4em .6em; color: #fff; word-break: break-word; }
.body img { vertical-align: middle; object-fit: contain; }
''',
    '<div id="list"></div>',
    r'''
(async function () {
  const cfg = await loadConfig();
  const list = document.getElementById('list');
  const size = num('size', 18, 8, 120);
  const max = Math.round(num('max', 5, 1, 50));
  const images = flag('emotes', cfg.emoteImage !== false);
  const emoteScale = num('emoteScale', cfg.emoteScale || 1, 0.3, 4);
  list.style.fontSize = size + 'px';
  const cards = new Map();
  function key(ev) { return ev.scId || (ev.user + '|' + ev.start + '|' + ev.text); }
  function add(ev) {
    const k = key(ev);
    if (cards.has(k)) return;
    const end = Math.max(ev.end || 0, Date.now() + 5000);
    const card = document.createElement('div');
    card.className = 'card';
    const head = document.createElement('div');
    head.className = 'head';
    head.style.background = ev.color || '#edf5ff';
    if (ev.face) {
      const img = emoteImg({ url: ev.face, text: '' }, size * 2, 'face');
      img.onerror = () => img.remove();
      head.appendChild(img);
    }
    const who = document.createElement('div');
    who.className = 'who';
    const user = document.createElement('div');
    user.className = 'user';
    user.textContent = ev.user || '';
    const price = document.createElement('div');
    price.className = 'price';
    price.textContent = ev.priceText || '';
    who.appendChild(user);
    who.appendChild(price);
    head.appendChild(who);
    const left = document.createElement('div');
    left.className = 'left';
    head.appendChild(left);
    const body = document.createElement('div');
    body.className = 'body';
    body.style.background = ev.colorBottom || '#2a60b2';
    fillContent(body, ev.text, ev.emotes, ev.sticker, images, size * 1.15 * emoteScale, size * 2.4 * emoteScale);
    card.appendChild(head);
    if (ev.text || ev.sticker) card.appendChild(body);
    list.appendChild(card);
    cards.set(k, { card: card, left: left, end: end });
    while (list.childElementCount > max) {
      const first = list.firstElementChild;
      for (const [kk, v] of cards) { if (v.card === first) cards.delete(kk); }
      first.remove();
    }
    tick();
  }
  function tick() {
    const now = Date.now();
    for (const [k, v] of cards) {
      const s = Math.ceil((v.end - now) / 1000);
      if (s <= 0) {
        cards.delete(k);
        v.card.classList.add('out');
        setTimeout(() => v.card.remove(), 600);
      } else {
        v.left.textContent = s + 's';
      }
    }
  }
  setInterval(tick, 500);
  connect('?superchats=1', (ev) => { if (ev.type === 'superchat') add(ev); },
    () => { list.textContent = ''; cards.clear(); });
})();
''',
  );

  /// 首页：可以直接粘贴到 OBS 的地址和说明。[base] 如 http://127.0.0.1:25789
  static String index({required String base, String? token}) {
    String url(String path) {
      var full = "$base$path";
      if (token == null || token.isEmpty) {
        return full;
      }
      return "$full${path.contains("?") ? "&" : "?"}token=${Uri.encodeQueryComponent(token)}";
    }

    String e(String text) => _html.convert(text);
    String row(String name, String path, String desc) {
      var u = url(path);
      return '<tr><td>${e(name)}</td><td><a href="${e(u)}"><code>${e(u)}</code></a></td>'
          '<td>$desc</td></tr>';
    }

    var tokenNote = token == null || token.isEmpty
        ? "只有本机能访问（127.0.0.1）。".t
        : "已允许局域网访问：每个地址都要带上 <code>token=…</code>，不要把地址发给别人。".t;
    var ws = url("/ws").replaceFirst("http://", "ws://");
    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SimpleLive 录屏接口</title>
<style>
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1f2328; --muted: #656d76; --line: #d0d7de; --code: #f6f8fa; }
@media (prefers-color-scheme: dark) { :root { --bg: #0d1117; --fg: #e6edf3; --muted: #8d96a0; --line: #30363d; --code: #161b22; } }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg); font: 15px/1.6 "Microsoft YaHei", "PingFang SC", sans-serif; }
main { max-width: 960px; margin: 0 auto; }
h1 { font-size: 22px; } h2 { font-size: 18px; margin-top: 28px; }
p, li { color: var(--fg); } .muted { color: var(--muted); }
table { border-collapse: collapse; width: 100%; display: block; overflow-x: auto; }
td, th { border: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
code, pre { background: var(--code); border-radius: 4px; font-family: Consolas, Menlo, monospace; font-size: 13px; }
code { padding: 1px 4px; word-break: break-all; } pre { padding: 10px; overflow-x: auto; }
a { color: #2f81f7; }
</style>
</head>
<body>
<main>
<h1>SimpleLive 录屏接口</h1>
<p>在 SimpleLive 里打开直播间，这里的页面就显示它的弹幕和聊天。$tokenNote</p>
<p>OBS 里添加“浏览器”来源，填入地址，宽高设成画面大小（如 1920×1080）；页面背景是透明的，叠在画面采集上面即可。应用重启或换直播间时页面会自动重连、清空。</p>
<h2>页面</h2>
<table>
<tr><th>名称</th><th>地址</th><th>说明</th></tr>
${row("弹幕层".t, "/overlay", "透明背景的滚动弹幕，和应用里的一样（颜色、描边、表情图片、分行不重叠）".t)}
${row("聊天框".t, "/chat", "竖排聊天列表，最新的在最下面；有头像时显示头像".t)}
${row("醒目留言".t, "/sc", "醒目留言（SC）卡片，显示到它的结束时间".t)}
</table>
<h2>页面参数</h2>
<p class="muted">加在地址后面，如 <code>/overlay?size=40&amp;speed=8</code>（已有 <code>?</code> 时用 <code>&amp;</code> 连接）。不填时用应用里的弹幕设置。</p>
<table>
<tr><th>页面</th><th>参数</th><th>说明</th></tr>
<tr><td>/overlay</td><td><code>size</code></td><td>字号（像素）。不填时按应用的弹幕大小随画面高度放大（应用里的大小以 540 高为准）</td></tr>
<tr><td>/overlay</td><td><code>speed</code></td><td>弹幕从右到左穿过画面的秒数</td></tr>
<tr><td>/overlay</td><td><code>area</code></td><td>弹幕占画面高度的比例，0~1</td></tr>
<tr><td>/overlay</td><td><code>opacity</code></td><td>不透明度，0~1</td></tr>
<tr><td>/overlay</td><td><code>stroke</code></td><td>描边粗细（像素），0 为不描边</td></tr>
<tr><td>/overlay</td><td><code>emotes</code></td><td>表情显示为图片：1 显示，0 显示为文字</td></tr>
<tr><td>/overlay</td><td><code>all</code></td><td>设为 1 时没有空行也照样显示（会重叠）；默认不显示</td></tr>
<tr><td>/chat</td><td><code>size</code>、<code>lines</code>、<code>emotes</code></td><td>字号（默认 20）、最多显示几行（默认 20）、表情图片</td></tr>
<tr><td>/chat</td><td><code>faces</code>、<code>sc</code>、<code>fade</code></td><td>显示头像、显示醒目留言（默认都显示）；每行显示几秒后淡出（默认 0 不淡出）</td></tr>
<tr><td>/sc</td><td><code>size</code>、<code>max</code>、<code>emotes</code></td><td>字号（默认 18）、最多同时显示几张（默认 5）、表情图片</td></tr>
</table>
<h2>ASS 弹幕字幕</h2>
<table>
<tr><th>名称</th><th>地址</th><th>说明</th></tr>
${row("实时 ASS".t, "/ass/live", "边收边写的 ASS 字幕流：先写文件头，每收到一条弹幕写一行，时间从打开这个地址算起；换直播间时继续写并加一行备注。可用下载工具或 <code>curl -o 弹幕.ass</code> 保存，和录屏一起开始".t)}
${row("导出 ASS".t, "/api/ass", "导出这次打开录屏接口后收到的弹幕。<code>from</code>、<code>to</code> 为 Unix 毫秒时间，时间从 <code>from</code> 算起（不填为最早一条）".t)}
</table>
<p class="muted">ASS 参数：<code>w</code>、<code>h</code> 画面大小（默认 1920×1080）；<code>size</code> 字号；<code>speed</code> 滚动秒数；<code>area</code>、<code>opacity</code>、<code>stroke</code> 同上；<code>font</code> 字体（默认 Microsoft YaHei）；<code>all=1</code> 没有空行时也保留；<code>sc=0</code> 不写醒目留言。表情写成文字（如 [doge]）。</p>
<h2>数据接口</h2>
<table>
<tr><th>名称</th><th>地址</th><th>说明</th></tr>
${row("WebSocket", "/ws", "推送事件（JSON，见下）。连上后先发一条 room；<code>history=N</code> 补发最近 N 条聊天，<code>superchats=1</code> 补发还在显示的醒目留言".t)}
${row("当前直播间".t, "/api/room", "<code>{\"v\":1,\"room\":{…}}</code>，没有打开直播间时 room 为 null".t)}
${row("最近消息".t, "/api/messages?since=0", "最近 300 条聊天和醒目留言中 id 大于 since 的；返回 lastId，下次带上它。instance 变了表示接口重启过".t)}
${row("弹幕设置".t, "/api/config", "应用当前的弹幕设置：size、speed、area、opacity、stroke、fontWeight、emoteImage、emoteScale 等".t)}
</table>
<p class="muted">WebSocket 地址：<code>${e(ws)}</code></p>
<h2>事件格式（v1）</h2>
<p>每个事件都有 <code>v</code>（版本，目前为 1，字段只增不改）、<code>type</code>、<code>time</code>（Unix 毫秒）。chat、superchat 还有 <code>id</code>（递增）、<code>site</code>（平台 id）、<code>roomId</code>。</p>
<pre>{"v":1,"type":"chat","id":12,"time":1730000000000,"site":"bilibili","roomId":"6",
 "user":"用户名","text":"你好[doge]","color":"#ffffff","face":null,
 "emotes":[{"text":"[doge]","url":"https://…/doge.png","width":0,"height":0}],
 "sticker":null}

{"v":1,"type":"superchat","id":13,"time":1730000000000,"site":"bilibili","roomId":"6",
 "scId":"123","user":"用户名","face":"https://…","text":"留言","price":30,"priceText":"￥30",
 "start":1730000000000,"end":1730000060000,"color":"#edf5ff","colorBottom":"#2a60b2",
 "emotes":[],"sticker":null}

{"v":1,"type":"online","time":1730000000000,"site":"bilibili","roomId":"6","online":12345}

{"v":1,"type":"room","time":1730000000000,"room":{"site":"bilibili","siteName":"哔哩哔哩",
 "roomId":"6","title":"标题","streamer":"主播","avatar":"https://…","cover":"https://…",
 "live":true,"isRecord":false,"url":"https://live.bilibili.com/6","online":12345}}

{"v":1,"type":"clear","time":1730000000000}</pre>
<ul>
<li><code>emotes</code>：<code>text</code> 里出现的这些文字可以换成图片（宽高为 0 表示平台没给）；<code>sticker</code> 不为 null 时整条消息是一张大表情，<code>text</code> 是它的文字说明。</li>
<li><code>room</code> 的 room 为 null 表示直播间关了；换直播间时先发 <code>clear</code> 再发 <code>room</code>。</li>
<li>被关键词屏蔽的弹幕不会推送。</li>
</ul>
</main>
</body>
</html>
''';
  }
}
