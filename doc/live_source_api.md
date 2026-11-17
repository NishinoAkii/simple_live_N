# 直播源订阅：脚本接口约定（v1）

一个直播平台 = 一个 `xxx.live.js` 文件。App 从“订阅”（`index.json`）或单个文件地址安装，
之后改脚本、改订阅就能修平台或加平台，不用重新编译 App。参考 Venera 的漫画源，但补上了
WebSocket、超时、隔离和每个源独立的 Cookie。App 自带的平台（B站、斗鱼……）改了接口时，
也可以发一个替换它部分功能的“修正”脚本（`overrides`，§9）。

写源的说明、示例和模板见直播源订阅仓库 [simple_live_N-sources](https://github.com/NishinoAkii/simple_live_N-sources) 的 `GUIDE.md`、`sample.js` 和 `_template.live.js`，检查工具见 §6。

## 1. 文件格式

```js
class AcFunLive extends LiveSource {
  key = "acfun"                 // 必填，^[a-z0-9_]+$，全局唯一；App 里的平台 id 为 "js:acfun"
  name = "AcFun 直播"            // 必填
  version = "1.0.0"             // 必填，语义化版本，用于检查更新
  apiVersion = 1                // 用到的脚本接口版本；大于 App 支持的版本时不加载（不写为 1）
  url = "https://…/acfun.live.js"   // 更新地址（可选）
  icon = "https://…/favicon.png"    // 平台图标（可选，http(s) 或 data: URI）
  description = "…"             // 一句话说明（可选）
  domains = ["acfun.cn", "*.acfun.cn", "*.kuaishouzt.com"]  // Http/WebSocket 只能访问这些域名
  links = ["live\\.acfun\\.cn/live/(\\d+)"]  // 粘贴链接识别：正则字符串，第 1 组为房间号

  // ---- 以下全部可选，没写的功能 App 不显示 ----
  async recommend(page) { return { hasMore, rooms: [/* Room */] } }
  async categories() { return [{ id, name, children: [{ id, name, pic }] }] }
  async categoryRooms(category /* {id,name,parentId,pic} */, page) { return { hasMore, rooms } }
  async search(keyword, page) { return { hasMore, rooms } }
  async searchAnchors(keyword, page) { return { hasMore, anchors: [/* Anchor */] } }
  async suggest(keyword) { return [/* Suggestion：主播、直播间卡片 */] }
  async resolve(input) { return "房间号" /* 或 { roomId }，认不出时 null */ }
  async room(roomId) { return /* RoomDetail */ }
  async liveStatus(roomId) { return true /* 或 false */ }
  async qualities(room /* RoomDetail */) { return [{ name: "原画", data: /* 任意 JSON */, sort? }] }
  async playUrls(room, quality) { return { urls: ["https://…flv"], headers: { referer: "…" } } }
  async avPlayerUrls(room, quality) { return { urls: ["https://…m3u8"], headers } /* 或 null */ }
  async superChats(roomId) { return [/* SuperChat */] }
  danmaku = { async start(room, session) { … }, async stop(session) { … } }

  // ---- 可选功能（App.features，见 §7）：旧版 App 忽略 ----
  login = { url: "https://…/login", cookieUrl: "https://…/", cookieNames: ["auth"], tip: "…" }
  async account() { return { loggedIn, userName?, avatar?, uid? } }
  settings = [{ key: "hd", type: "switch", label: "默认高清", default: true }]   // 设置项，脚本用 Settings.get 读
  hls = { rewrite(text, info) { return text } }   // 改写 HLS 列表（playUrls 返回 hlsFix: ["rewrite"] 时）
  overrides = "bilibili"   // 不是新平台：替换内置平台里上面实现了的函数（§9）
  useAccount = true        // 和 overrides 一起用：App 代为加内置平台的登录信息，脚本读不到（§9.5）
}
```

安装、更新时 App 给用户看 `domains` 和敏感功能（`login`、`hls.rewrite`、`overrides`、
`useAccount`），更新新增了这些要用户确认；订阅可以带发布者签名。见 §8。

文件里只能有这一个继承 `LiveSource` 的类；顶层不要做网络请求（加载时会执行一遍）。

- 字段校验：`key` 不超过 64 个字符；`version` 形如 `1.2.3`（可带 `-beta` 之类的后缀）；
  `url` 为 http(s) 或 file 地址；`domains` 每项为 `example.com` 或 `*.example.com`；`links` 每项必须是有效的正则。
- 分类要 `categories` 和 `categoryRooms` 都实现才显示。
- 没有 `liveStatus` 时，App 调用 `room(roomId)` 读 `live`。
- `playUrls` / `avPlayerUrls` 也可以直接返回地址数组（没有请求头时）。
- `qualities` 的 `sort` 可选，不写时为序号；第一个是默认清晰度。
- `searchAnchors` 应尽量包括没开播的主播（`live: false`）：App 默认的“综合”搜索把直播间和主播合在一起，
  靠它找到没开播的人（`search` 一般只有在播的）。
- `suggest(keyword)`：输入时的搜索联想，**只给直播相关的：主播、直播间卡片**（有 `roomId`，点了直接进直播间），
  不要平台的通用联想词（多是视频、话题词）。App 只显示有 `roomId` 的项，只有词的项（包括字符串数组）不显示。
  平台没有直播专用的联想接口时，可以用一次轻量的主播搜索（如 `searchAnchors` 第一页的前 5 个）代替，
  或者干脆不实现。App 停止输入约 280 毫秒后调用，超时 3 秒；超时、出错都不提示，
  也不算进“连续超时就重启”。
- `resolve(input)`：搜索时 App 先用它试“直达”。输入不是链接（数字 ID、用户号、@名称等）时调用，
  返回房间号，认不出返回 `null`；App 接着调用 `room()`，能打开时在结果最上面放一张卡片（不自动跳转）。
  没有这个方法时 App 不试直达（不会拿任意关键词调用 `room()`）。
- `suggest`、`resolve` 和 Anchor 的新字段都是可选的，`apiVersion` 不用改；旧版 App 不认识时直接忽略。

### 数据结构

- `Room`：`{ roomId, title, cover, userName, online }`（online 为数字）
- `Anchor`：`{ roomId, userName, avatar, live, followers?, lastTitle?, lastLiveTime?, isRecord? }`
  - `live`：是否在播；`followers`：粉丝数；`lastTitle`：上次直播的标题；
    `lastLiveTime`：上次开播时间（秒或毫秒时间戳，或 ISO 8601 文字）；`isRecord`：正在轮播
- `Suggestion`：`{ text, roomId?, userName?, avatar?, live?, isRecord?, subtitle? }`
  - 有 `roomId` 的是主播卡片，点了直接进直播间（`text` 可以不写，用 `userName`）；没有 `roomId` 的 App 不显示
  - `live` 不写表示不知道是否在播；`subtitle`：补充说明（分类、直播标题）
- `RoomDetail`：`{ roomId, title, cover, userName, userAvatar, online, live, introduction?, notice?, url, data?, danmakuData?, isRecord?, showTime? }`
  - `live`：是否在播；`url`：网页地址；`data` / `danmakuData`：任意 JSON，原样传回 `qualities` / `playUrls` / `danmaku.start`
  - 整个 `room()` 返回的对象（包括额外的字段）会原样作为 `room` 参数传给 `qualities`、`playUrls`、`avPlayerUrls`、`danmaku.start`
  - `isRecord`：是否在轮播（重播以前的直播）；`showTime`：开播时间文字（两者可选）
- `Message`（弹幕）：
  - `{ type: "chat", user, userId?, text, color?: 0xRRGGBB, face?: 头像地址, emotes?: [Emote], sticker?: Emote, history?: true }`
    （`userId`：发言人在这个平台上的 ID，字符串或数字，选填。填写后，屏蔽、备注和“只看这个人”按 ID 认人，改名后也能认出；
    不填时按用户名认）
    （emotes / sticker 见 §7，`App.features` 含 `"emotes"` 时显示为图片；`history` 见 §7，
    `App.features` 含 `"history"` 时只进聊天区）
  - `{ type: "superChat", user, userId?, text, face?, price, priceText?, startTime: 毫秒, endTime: 毫秒, backgroundColor?: "#RRGGBB", backgroundBottomColor?: "#RRGGBB", id? }`
  - `{ type: "online", online: 数字 }`
  - `{ type: "system", text }`（只显示在聊天区）
- `SuperChat`：同上 superChat 消息去掉 type。`price` 为人民币金额（整数），`priceText` 为带币种的金额（如 `"$5.00"`，可选）；
  时间戳是秒时也认。

所有函数都可以是 `async`；抛出的 `Error` 会作为错误提示显示给用户（`message` 用中文）。
返回值要能转成 JSON：`BigInt` 在安全整数范围内转为数字，否则转为字符串；`Uint8Array` 转为 `{ "__b64": "…" }`。

## 2. 运行环境

- 每个源在自己的后台 isolate 里有一个独立的 QuickJS 引擎（内存上限 64 MB），互不影响，也不会卡住界面。
  第一次调用时启动，没有调用、没有弹幕会话 3 分钟后关闭。
- 每次调用（如 `room()`）超过 20 秒未完成就报超时；连续超时的源会被重启。
- 同步代码（如死循环）连续执行超过 10 秒会被中断（抛出不可捕获的错误），这个源随即重启。
- 支持 ES2023、Promise、async/await、BigInt、DataView。没有 DOM、`fetch`、Node 模块；用下面的全局对象。
- 安装、加载时 App 在临时引擎里执行脚本读取元数据，这时发出的请求、定时器都会被丢弃。
- 引擎的已知问题：`BigInt.asUintN` / `BigInt.asIntN` 对负数返回原值（用掩码 `b & 0xffffffffffffffffn` 代替）；
  栈上限约 512 KB（32 位设备约 192 KB），深递归会报 `Maximum call stack size exceeded`。

### 全局对象（脚本里直接用）

| 名称 | 说明 |
|---|---|
| `Http.request({url, method="GET", headers, body, query, contentType, responseType="text", timeout=15000, followRedirects=true})` | async。`body` 可为字符串、`Uint8Array` 或对象（对象按 `contentType` 编码：`"json"` 或 `"form"`，默认 json）。`query` 为对象（数组值会重复键）或字符串，追加到地址后。返回 `{status, headers, body, url}`，`body` 按 `responseType`：`"text"` / `"json"` / `"bytes"`（Uint8Array）；`url` 为重定向后的最终地址；`headers` 的键为小写。状态码不是 2xx 也会返回，不抛错；网络错误、超时抛错。只能访问 `domains` 里的域名（重定向的每一跳都检查）。自动带上并保存本源的 Cookie。 |
| | `responseType: "json"` 时：2xx 但内容不是 JSON 会抛错；非 2xx 时 `body` 为 null。两种情况原文都在 `text` 里。没写 `User-Agent` 时默认用桌面版 Chrome 的 UA。gzip / deflate / br 压缩的响应自动解压。响应最大 32 MB。 |
| `Http.get(url, opts)` / `Http.post(url, body, opts)` | 上面的简写 |
| `Http.getCookies(url)` / `Http.setCookies(url, "a=1; b=2")` | async，本源的 Cookie 罐；`getCookies` 返回发往该地址的 Cookie 字符串（`"a=1; b=2"`），`setCookies` 写入该主机、路径 `/` 的 Cookie |
| `Bytes` | 同步：`fromUtf8(str)`、`toUtf8(bytes)`、`fromBase64(str)`、`toBase64(bytes)`、`fromHex`、`toHex`、`concat(...arrays)`（参数也可以是 ArrayBuffer、普通数组） |
| `Proto` | 同步，最小 protobuf：`new Proto.Writer()`（`.varint(field, n)` `.sint(field,n)` `.fixed64(field, bigint)` `.string(field, s)` `.bytes(field, u8)` `.message(field, writer)` `.bool(field,b)` `.finish()` → Uint8Array；另有 `.fixed32` `.double` `.float`）；`Proto.decode(u8)` → `{字段号: [值…]}`，值为 BigInt（varint/fixed）或 Uint8Array（长度前缀）；`Proto.str(u8)`、`Proto.num(v)` 辅助转换（可以直接传数组，取第一个；没有时返回 `""` / `0`）；另有 `Proto.signed(v)`（int64 负数）、`Proto.zigzag(v)`（sint）、`Proto.bool(v)`、`Proto.double(v)`、`Proto.float(v)` |
| `Zip` | async：`gunzip(u8)`、`inflate(u8)`（zlib）、`inflateRaw(u8)`、`brotli(u8)`，返回 Uint8Array；另有压缩 `gzip(u8)`、`deflate(u8)`、`deflateRaw(u8)`。输入和解压结果最大 16 MB（超过就停，报错） |
| `Hash` | async，在 App 里算（比 CryptoJS 快）：`md5(d)`、`sha1(d)`、`sha256(d)`、`sha512(d)`、`hmac(alg, key, d)`（alg 为上面四个之一），`d` / `key` 为字符串（UTF-8）或 Uint8Array，返回 Uint8Array（`Bytes.toHex` 转十六进制）；输入最大 16 MB。`App.features` 含 `"hash"` 时才有 |
| `CryptoJS` | 同步，完整的 CryptoJS 4（MD5/SHA/HMAC/AES-CBC/ECB/Base64…，没有 GCM）；`Bytes` 与 `CryptoJS.lib.WordArray` 互转：`Bytes.toWordArray(u8)`、`Bytes.fromWordArray(wa)` |
| `Storage.get(key)` / `Storage.set(key, value)` / `Storage.remove(key)` | async，本源的持久数据（JSON 值），没有时 `get` 返回 null |
| `Settings.get(key)` / `Settings.all()` | 同步、只读：用户在 App 里改的设置项（§7 settings），没改过时为声明的 `default`。`App.features` 含 `"settings"` 时才有 |
| `log(...args)` | 写入 App 日志（带源名前缀）；也可以用 `console.log` / `info` / `debug` / `warn` / `error` |
| `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` | 标准语义（额外参数会传给回调；`setInterval` 最短 10 毫秒） |
| `App.version`、`App.platform`（"android" / "ios" / "windows" / "macos" / "linux"）、`App.apiVersion` | 只读 |
| `randomId(len)`、`uuid()` | 工具（`randomId` 默认 16 位字母数字，`uuid` 为 v4） |
| `TextEncoder` / `TextDecoder`、`atob` / `btoa`、`crypto.getRandomValues` / `crypto.randomUUID` | 常用的浏览器 API（TextDecoder 只支持 UTF-8） |
| `App.features` | 只读字符串数组：App 支持的可选功能（§7）。旧版 App 没有这个字段，用 `Array.isArray(App.features) && App.features.includes("login")` 判断 |

## 3. 弹幕会话

```js
danmaku = {
  async start(room, session) {
    const ws = await session.websocket("wss://…", { headers, protocols })  // 连上才返回，失败抛错
    ws.onMessage = async (data) => {          // data：二进制为 Uint8Array，文本为 string
      session.emit([{ type: "chat", user: "a", text: "hi" }])
    }
    ws.onClose = (code, reason) => {}         // 可选
    ws.send(Bytes.fromUtf8("…"))              // string 或 Uint8Array
    session.setInterval(() => ws.send(heartbeat), 20000)   // 会话结束时自动清除
    // 轮询型平台：不开 websocket，直接 session.setInterval + Http + session.emit
  },
  async stop(session) {}                       // 可选，App 会关闭连接并清除定时器
}
```

- `session.emit(messages)`：把一批消息交给 App（数组；单条消息也可以直接传对象）。
- `session.ready()`：连接就绪（App 显示“弹幕服务器连接正常”）；不调用时第一条非 system 消息视为就绪（只发 system 提示时不算就绪，如“主播未开播”）。
- `session.fail(message)`：报告断开原因；App 按退避（2、4、8…最长 30 秒）重新调用 `start`。
- websocket 意外断开时，App 同样按退避重新调用 `start`（新的 session）。`start` 抛错或 20 秒没有完成也一样。
  会话就绪后退避重新从 2 秒开始。
- `session.data`：会话内的临时对象，脚本随意存放（如序号、密钥）。
- `session.source`：源对象本身（`danmaku` 里的 `this` 是 danmaku 对象，不是源）；`session.alive`：会话是否还在。
- `session.setTimeout` / `setInterval` / `clearTimeout` / `clearInterval`：同全局的，会话结束时自动清除。
- `session.websocket` 的请求头没写 `User-Agent` 时默认用桌面版 Chrome 的 UA，没写 `Cookie` 时带上本源 Cookie 罐里的 Cookie；
  也可以传 `timeout`（毫秒，默认 15000）。地址必须是 `ws://` 或 `wss://`，域名要在 `domains` 里。
- 在设置 `ws.onMessage` 之前收到的消息会先缓存，设置后依次送达。
- `ws.close(code, reason)`：脚本自己关闭连接，不算意外断开，不会触发重连。
- `stop(session)` 在每个会话结束时调用（App 停止弹幕，或会话失败 / 断开之后、重连之前），这时连接还没关闭；
  它返回（最多等 3 秒）后 App 关闭这个会话的连接和定时器。

## 4. 订阅（index.json）

```json
{
  "name": "SimpleLive 直播源",
  "publicKey": "…Base64（可选，见 §8）…",
  "sources": [
    { "key": "acfun", "name": "AcFun 直播", "version": "1.0.0", "url": "acfun.live.js", "description": "…",
      "signature": "…Base64（有 publicKey 时必须有它，或者 acfun.live.js.sig）…" }
  ]
}
```

- `url` 可以是绝对地址，也可以是相对订阅地址的路径。
- App 里可以添加多个订阅；每天检查一次更新（版本号更高时提示更新）。
- 订阅地址支持 `https://`，以及本机测试用的 `file:///` 路径（和 `http://127.0.0.1` / `http://localhost`）。
  单个脚本的安装地址同样如此。
- `key` 不合法或没有 `url` 的项会被跳过。
- `publicKey` / `signature`：发布者签名（Ed25519），可选；没有签名的订阅照常能用，App 显示“未签名”。见 §8。

## 5. App 侧（Dart，simple_live_core）

```dart
final manager = LiveSourceManager(directory: "<应用数据>/live_sources", appVersion: "1.24.0");
await manager.init();                         // 加载已安装的源
manager.sites;                                // List<ScriptLiveSite>，ScriptLiveSite implements LiveSite（id = "js:<key>"）
manager.changes;                              // Stream<void>：安装、更新、删除后触发
await manager.installFromUrl(url);            // 返回 LiveSourceInfo
await manager.installFromFile(path);
await manager.remove(key);
manager.subscriptions;                        // List<String>
await manager.addSubscription(url); await manager.removeSubscription(url);
await manager.fetchSubscription(url);         // List<LiveSourceIndexEntry>（带 installedVersion / hasUpdate）
await manager.checkUpdates();                 // List<LiveSourceIndexEntry>，有更新的（只检查，不安装）
await manager.update(key);                    // 权限扩大时抛 LiveSourceConfirmationRequired（§8）

// 两步：先给用户看权限，确认后再装（App 用这个）
var plan = await manager.prepareInstallFromUrl(url);   // 或 prepareInstallFromFile(path)、prepareUpdate(key)
plan.next.domains; plan.diff.addedDomains; plan.signed; plan.needsConfirmation;
await manager.applyPlan(plan, confirmed: true);
```

`ScriptLiveSite` 另有：`info`（key、name、version、icon、url、description）、`linkPatterns`（List<RegExp>）、
能力：`hasRecommend`、`hasCategories`、`hasSearch`、`hasSearchAnchors`、`hasSuggest`、`hasResolve`、`hasSuperChat`、`hasDanmaku`、`hasAvPlayer`。
`getDanmaku()` 返回 `ScriptLiveDanmaku`（LiveDanmaku 子类）；`getAvPlayerUrls` 映射到脚本的 `avPlayerUrls`；
`getSearchSuggestions(keyword)` 映射到 `suggest`（没有时为空列表，超时 `ScriptLiveSite.suggestTimeout`，默认 3 秒）；
`resolveRoomId(input)` 映射到 `resolve`（没有时为 null）。

补充（在上面的基础上增加的）：

- 目录：`sources/<key>.live.js`（脚本）、`sources/<key>.origin`（安装来源，脚本没有 `url` 时用来更新）、
  `subscriptions.json`（订阅地址、名称、上次检查更新的时间）、`data/<key>/cookies.json`、`data/<key>/storage.json`。
- `LiveSourceManager`：`site(key)`、`loadErrors`（文件名 → 原因）、`removeFile(fileName)`（删除加载失败的文件）、
  `subscriptionName(url)`（index.json 的 name）、`lastUpdateCheck`（App 每天检查一次时用）、`dispose()`。
  `checkUpdates()` 也会检查不在任何订阅里、但脚本写了 `url` 的源（这些项的 `subscription` 为空字符串）。
  脚本下载只支持 https（本机测试：file:/// 和 http://127.0.0.1），最大 5 MB。
- `LiveSourceInfo`：另有 `domains`、`links`、`capabilities`（实现了的方法名，有弹幕时含 `"danmaku"`）、`settings`、`file`、`siteId`。
- `LiveSourceIndexEntry`：另有 `publicKey`（订阅记下的公钥）、`signature`、`signed`、`blockedReason`（订阅的公钥变了时的说明）。
- 签名：`publicKeyOf(key)`（签名安装的源记下的公钥）、`subscriptionPublicKey(url)`、`subscriptionKeyError(url)`；
  目录里另有 `sources/<key>.trust`（签名安装的源的公钥）、`data/<key>/settings.json`（设置项）。
- `ScriptLiveSite(info, {dataDirectory, appVersion})`：构造参数可选；`dataDirectory` 默认为脚本目录旁的 `../data/<key>`。
  另有 `matchRoomId(text)`（用 `links` 找房间号）、`callScript(method, args)`（调用源对象的任意方法，作者工具和测试用）、
  `getCookies(url)` / `setCookies(url, "a=1; b=2")`（如 App 里登录后写入）、`shutdown()`（关闭后台 isolate，下次调用重新启动）、
  `dispose()`。静态设置：`ScriptLiveSite.callTimeout`（20 秒）、`idleTimeout`（3 分钟）、`scriptSliceTimeout`（10 秒）。
  脚本抛出的错误、超时都变成 `CoreError(message)`。
- `getRoomDetail` 返回的 `LiveRoomDetail.danmakuData` 是 `ScriptDanmakuArgs`（保存 `room()` 的原始对象，`.data` 为脚本的 `danmakuData`）；
  `ScriptLiveDanmaku.start(detail.danmakuData)` 用它调用 `danmaku.start`。`hasDanmaku` 为 false 时 `start` 什么也不做。
- `ScriptLiveDanmaku.onSystemMessage`：`system` 消息的回调；没设置时交给 `onClose`（App 现在的 `onClose` 就是在聊天区加一条系统提示）。
  断开重连时 `onClose` 收到 “<原因>，N 秒后重新连接”。

## 6. 作者工具

- 模板和示例：直播源订阅仓库（[simple_live_N-sources](https://github.com/NishinoAkii/simple_live_N-sources)）里的 `_template.live.js`（演示所有字段和功能：WebSocket 弹幕、轮询弹幕、protobuf、AES、gzip）和 `sample.js`（带注释的示例）。
- 说明：同一个仓库的 `GUIDE.md`（编写步骤、查找平台数据、测试、发布、常见问题）。
- 检查工具（在 `simple_live_core` 目录）：
  `dart run bin/live_source_check.dart <file.live.js> [--room <id>] [--search <关键词>] [--suggest <关键词>] [--resolve <输入>] [--danmaku <秒>] [--play] [--data <目录>]`，
  依次打印元数据和功能（含敏感功能、设置项）、推荐第 1 页、分类、搜索、联想、解析、直播间、清晰度、播放地址（隐去查询参数）、醒目留言和 N 秒弹幕。
- 签名工具（在 `simple_live_core` 目录）：`dart run bin/live_source_sign.dart keygen | pubkey | sign | index | verify …`，见 §8.3。

## 7. 可选功能（App.features）

接口 v1 之后加的功能都是可选的、向后兼容的：旧版 App 不认识这些字段和方法，直接忽略，脚本照常能用；
所以 `apiVersion` 仍然是 1（只有不兼容的改动才需要提高它，提高后旧版 App 会拒绝加载脚本）。
脚本用 `App.features` 判断当前 App 支持哪些（旧版 App 没有这个字段）：

```js
function hasFeature(name) {
  return typeof App !== "undefined" && Array.isArray(App.features) && App.features.includes(name)
}
```

### emotes：消息里的表情图片

chat 消息可以带 `emotes`（文字里出现的表情）和 `sticker`（整条消息是一张大表情）：

```js
session.emit([{
  type: "chat", user: "a", text: "好耶 :steamhappy:",
  emotes: [{ text: ":steamhappy:", url: "https://…/steamhappy", width: 54, height: 54 }],
}, {
  type: "chat", user: "b", text: "[贴纸] Tag",
  sticker: { text: "[贴纸] Tag", url: "https://…/tag.png", staticUrl: "https://…/tag_static.png", width: 150, height: 150 },
}])
```

- `Emote`：`{ text, url, staticUrl?, width?, height?, spaced?, cacheKey? }`。`text` 必须出现在消息的 `text` 里
  （sticker 的 text 一般就是消息本身）；`url` / `staticUrl` 为 http(s)；`staticUrl` 是动图的静态版本（视频弹幕只画一帧时用）；
  `spaced` 为 true 时只匹配前后是空白的整个词；地址每次变而图片不变时给 `cacheKey`。
- 文字里没出现的、地址不合法的表情会被丢掉，一条消息最多 50 个。旧版 App 只显示文字。
- App 的聊天区、视频弹幕和录屏接口（OBS 页面）都按现有的表情渲染显示。
  视频弹幕只画一帧（有 `staticUrl` 时用它），图片没下载好时最多等 0.6 秒，还没好就先显示文字；
  一批消息里的表情多时排队下载。

### history：之前的聊天只进聊天区

很多平台在连上弹幕时先补发最近的一批聊天（进直播间之前发的）。这批消息标上 `history: true`，
App 只把它们放进聊天区（和电视侧栏），不上视频弹幕、不进录屏接口和弹幕记录，不会进直播间就一起飞过视频：

```js
const backlog = hasFeature("history")
  ? recent.map((m) => ({ type: "chat", user: m.name, text: m.text, history: true }))
  : []   // 旧版 App 会把它们当成新弹幕一起飞过视频：不发，或者只发最后一两条
session.emit(backlog)
```

- 只对 `chat` 消息有效；不写或为 false 时是普通的新消息。
- 断开重连后再补发时，脚本自己去掉已经发过的（App 不查重复）。
- 旧版 App 不认识 `history`，照常显示在聊天区和视频弹幕上：没有这个功能时最好不发之前的聊天。

### login：网页登录

```js
login = {
  url: "https://example.com/login",          // 登录页（https）
  cookieUrl: "https://example.com/",         // 读取、保存 Cookie 的地址（https，默认同 url）
  cookieNames: ["auth_token"],               // 登录后才有的 Cookie，出现任意一个（值不为空）就算已登录
  tip: "部分直播要登录后才能看",               // 可选，显示在登录页上方
}
async account() { return { loggedIn: true, userName: "名字", avatar: "https://…", uid: "123" } }  // 可选
```

- App 在“账号管理”和直播源设置里给这个源显示“登录”：有系统 WebView 的平台在 App 里打开 `url`，
  出现 `cookieNames` 里的 Cookie 后，把 `cookieUrl` 下的**全部** Cookie 写进这个源自己的 Cookie 罐（和 `Http.setCookies` 一样，
  作用于 `cookieUrl` 的主机、路径 /）；所有平台都可以手动粘贴整段 Cookie（`a=1; b=2`）。之后脚本的 `Http` 请求和
  WebSocket 握手都自动带上这些 Cookie。
- 退出登录：App 删除发往 `cookieUrl` 的全部 Cookie。
- `account()` 可选，用来显示帐号名字；没有时 App 只按 Cookie 判断是否登录。
- Cookie 只保存在本源的数据目录（`data/<key>/cookies.json`），App 不写日志、不同步。

### hlsFix：修正 HLS 列表

`playUrls` 可以返回 `hlsFix`（字符串或数组），App 把 `.m3u8` 地址换成本机中转
`http://127.0.0.1:<端口>/hlsfix/<编号>/<序号>.m3u8`：主列表和媒体列表都经中转实时取原地址、改写后返回，
分段地址改成原地址的绝对路径（播放器直接从 CDN 下载），请求原地址时带上 `headers`。

```js
return { urls: ["https://…/master.m3u8"], headers: { referer: "…" }, hlsFix: "durations" }
```

- `durations`：媒体列表里比 1.5×`#EXT-X-TARGETDURATION` 还长的 `#EXTINF` 改成 TARGETDURATION
  （例如 Steam 客户端直播的音频列表把 3 秒的分段写成 143 秒，ffmpeg 因此 140 多秒不刷新音频列表而卡住）。
- `rewrite`：交给脚本自己的 `hls.rewrite`（下一节，`App.features` 含 `"hlsRewrite"`），可以和 `durations` 一起用
  （`hlsFix: ["rewrite", "durations"]`，先执行脚本的改写）。
- 不认识的名称忽略；只改 `playUrls`（mpv），`avPlayerUrls` 不经中转。中转出错时用原地址。
- 旧版 App 忽略 `hlsFix`，直接播放原地址。

### hlsRewrite：脚本改写 HLS 列表

平台的列表有 App 没有内置修正的问题（广告分段、错的属性、缺的标签……）时，脚本可以自己改：

```js
hls = {
  rewrite(text, info) {          // info：{ url, kind: "master" | "media", index, variant }
    if (info.kind !== "media") return null          // null / undefined：不改
    return text.replace(/#EXT-X-DISCONTINUITY\n/g, "")
  },
}
async playUrls(room, quality) { return { urls: [m3u8], hlsFix: ["rewrite"] } }
```

- 本机中转每次取到主列表、媒体列表（直播时每隔几秒一次）都调用一次，在这个源自己的引擎里**同步**执行，
  限时约 200 毫秒（超时被中断，这次用原列表；源不会因此重启）；列表超过 2 MB 时不调用。
- 只能处理文字：执行期间 `Http`、`Storage`、`Zip`、`Hash`、定时器都会抛错；可以用 `Settings.get`、`log`。
  返回值必须是字符串（不能是 Promise）。
- `info.url`：列表的地址（重定向之后的）；`info.index`：0 是主列表，媒体列表从 1 起；
  `info.variant`：主列表里引用这个媒体列表的那一行（`#EXT-X-STREAM-INF:…` 或 `#EXT-X-MEDIA:…`），不知道时为 null。
- App 检查返回的列表，有问题就用原列表：要以 `#EXTM3U` 开头，不超过 2 MB，没有控制字符；
  每个地址行和每个 `URI=` 属性（必须加引号）按列表地址解析后必须是 http(s)，主机在源的 `domains` 里或就是原列表的主机；
  `file:`、`data:`、`concat:`、`subfile:` 之类的协议、反斜杠（Windows 路径）一律拒绝。连续 3 次没用上（出错、超时、
  没通过检查）后这一路不再调用。
- 之后照常做 App 的处理：地址改成绝对地址（分段由播放器直接从 CDN 下载）、子列表换成本机地址、`durations`。
- `hls.rewrite` 算敏感功能：更新时新加了它要用户确认（§8）。

### settings：设置项

```js
settings = [
  { key: "preferHls", type: "switch", label: "优先 HLS", description: "关掉时优先 FLV", default: false },
  { key: "token", type: "text", label: "访问令牌", placeholder: "可不填" },
  { key: "delay", type: "number", label: "延迟（秒）", min: 0, max: 30, default: 3 },
  { key: "line", type: "select", label: "线路", options: [{ value: "a", label: "主线路" }, "b"], default: "a" },
]
// 用的时候：Settings.get("preferHls")（同步；没改过时为 default）
```

- App 在直播源详情页（直播源设置 → 点源）里显示和修改：`switch` 开关、`text` 文字、`number` 数字（`min` / `max` 可选）、
  `select` 单选（`options` 为 `{ value, label }` 或直接写值；值可以是字符串、数字、true/false）。
- `key`：字母、数字、`_ . -`，最多 64 个字符，不能重复；最多 50 项。`label` 不写时用 key；`default` 不合法时用
  false / 空字符串 / min（或 0）/ 第一个选项。格式不对时脚本加载失败（检查工具会提示）。
- 值保存在本源数据目录的 `settings.json`：只在本机，不同步，删除源时一起删除。App 只接受声明过的 key 和合法的值；
  脚本只能读（`Settings.get`、`Settings.all()`），改了下次调用就生效（已经开着的弹幕会话不会重启）。
- 旧版 App 没有 `Settings`：用 `typeof Settings !== "undefined"` 判断。

### hash：摘要

`await Hash.md5(d)`、`sha1`、`sha256`、`sha512`、`await Hash.hmac("sha256", key, d)`：在 App 里用 Dart 算，大数据时比
CryptoJS 快得多；返回 Uint8Array（`Bytes.toHex(...)`）。CryptoJS 照旧可用（同步）。AES 仍用 CryptoJS（CBC / ECB；
App 里没有可用的 GCM 实现）。protobuf 用 `Proto.decode`（返回 `{字段号: [值…]}`），Base64 / 十六进制用 `Bytes`。

### overrides：修内置平台

`overrides = "bilibili"`（可选 `useAccount = true`）：这个源不是新平台，而是替换 App 自带平台的一部分函数。见 §9。

App 侧（Dart）：`ScriptLiveSite` 另有 `hasLogin`、`hasHlsRewrite`、`settings`、`getSettings()`、
`setSettings({key: 值或 null})`、`login`（`LiveSourceLogin`）、`isLoggedIn()`、
`loginWithCookies(cookies)`、`logout()`、`account()`（`LiveSourceAccount`）；
`LiveSourceInfo.capabilities` 含 `"login"`、`"account"`；中转为 `HlsFixRelay`
（`ScriptLiveSite.useHlsFix = false` 可以关掉）。chat 消息的 `history` 转成 `LiveMessage.history`
（App 的直播间收到 `history` 为 true 的聊天时只记进聊天区）。

## 8. 权限、签名与更新确认

脚本能做的事由 `domains` 决定（Http、WebSocket 只能访问这些域名，重定向的每一跳都检查；Cookie 罐、Storage、设置都是
每个源单独的）。所以订阅被人改了（比如托管的地方被盗），最危险的是新版本悄悄加一个域名，把这个源的登录 Cookie 发过去。
App 因此把下面这些当作“权限”：

- `domains` 里的每一项；
- 敏感功能：`login`（网页登录，App 把登录后的 Cookie 交给这个源）、
  `hlsRewrite`（`hls.rewrite`，改写播放列表）、`overrides`（替换内置平台的函数）、`useAccount`（用内置平台的帐号，§9）；
- 修正替换的平台和函数：多替换了函数、换了平台都算扩大（§9.4）；
- 登录页、Cookie 地址（`login.url`、`login.cookieUrl`）的主机。

### 8.1 安装和更新

- 安装（链接、文件、订阅）：App 先下载、解析（有签名时校验），把签名状态、`domains`、敏感功能、设置项个数给用户看，
  同意了才装。
- 更新：比较新旧版本。新增了域名（旧的没有覆盖的：`*.a.com` 覆盖 `x.a.com`，反过来不算）、新增了敏感功能、
  登录地址换了主机，或者去掉了签名、换了公钥时，App 列出变化并等用户确认；只是减少或者不变的直接更新。
- “全部更新”只装没扩大权限的，扩大了的逐个问；每天的自动检查只提醒“有 N 个可以更新”，从不自动安装。
- Dart：`prepareInstallFromUrl` / `prepareInstallFromFile` / `prepareUpdate` 返回 `LiveSourcePlan`（`next`、`current`、
  `diff`、`publicKey`、`needsConfirmation`），`applyPlan(plan, confirmed: true)` 才写进去；`needsConfirmation` 而没有确认时
  抛 `LiveSourceConfirmationRequired`（带着 plan）。`installFromUrl` / `installFromFile` / `update` 保留：新装照旧，
  覆盖或更新时权限扩大要 `allowExpanded: true`。
- 从同步备份恢复时，本机没有的源按备份里的地址直接安装（用户自己的备份；从签名订阅装的照样校验签名）。

### 8.2 发布者签名（可选）

- 算法 Ed25519（RFC 8032）。`index.json` 顶层 `publicKey`：32 字节公钥的 Base64；每一项 `signature`：64 字节签名的
  Base64，也可以不写在 index.json 里，而是放在脚本旁边的 `<脚本地址>.sig`（文件内容就是 Base64）。
- 签名的内容是脚本文件的字节，先把 CRLF 换成 LF（Windows 上 Git 改换行符不影响签名）。
- App 第一次添加订阅时记下公钥（TOFU，也就是“第一次见到时信任”）；原来没签名的订阅开始带 `publicKey` 时，第一次见到时记下。
  之后：
  - 订阅的公钥变了或者去掉了：停止从这个订阅安装、更新，订阅卡片上说明原因。发布者确实换了密钥时，用户删除订阅后
    重新添加（重新记下公钥）。
  - 签名不对、缺签名：不安装（“签名校验失败：脚本被改过，或者不是这个订阅的发布者签的”）。
- 从签名订阅装的源记下公钥（`sources/<key>.trust`）：之后的更新必须是同一把公钥签的（不在签名订阅里的更新地址要有
  `<地址>.sig`），版本也不能比已安装的旧。用户自己用别的地址重新安装时要确认（显示“已安装的版本有签名，这个版本没有”）。
- 没有签名的订阅照常能用，App 显示“未签名”。签名只能证明“和第一次添加时是同一个发布者”，不能证明发布者可信。

### 8.3 签名工具

在 `simple_live_core` 目录：

```sh
dart run bin/live_source_sign.dart keygen ~/.config/simplelive/live_source.key   # 生成私钥（只做一次；不要提交、不要上传）
dart run bin/live_source_sign.dart pubkey ~/.config/simplelive/live_source.key   # 打印公钥和指纹
dart run bin/live_source_sign.dart index  ~/.config/simplelive/live_source.key path/to/index.json   # 签所有源，写进 index.json
dart run bin/live_source_sign.dart verify path/to/index.json                      # 发布前自检
dart run bin/live_source_sign.dart sign   ~/.config/simplelive/live_source.key a.live.js            # 只写 a.live.js.sig
```

`index` 按每一项 `url` 的文件名在 index.json 所在的目录（或 `--dir <目录>`）找脚本，写入 `publicKey` 和每一项的
`signature`，其它字段和顺序不变。私钥文件是 JSON（`seed` 为 32 字节种子的 Base64），丢了就只能换密钥（用户要重新添加订阅），
泄露了别人就能冒充发布者——放在仓库外面，备份到安全的地方。

**用在 simple-live-sources 的发布流程里**（只是说明，那个仓库没有改）：`./publish.sh` 现在是“改版本号 → 上传脚本和
index.json 到 gist”。加签名只要在上传之前多一步：

```sh
# publish.sh 里，改完 version、更新完 index.json 之后、上传之前：
(cd "$SIMPLE_LIVE/simple_live_core" && \
  dart run bin/live_source_sign.dart index "$HOME/.config/simplelive/live_source.key" "$REPO/index.json" --dir "$REPO" && \
  dart run bin/live_source_sign.dart verify "$REPO/index.json" --dir "$REPO") || exit 1
# 然后照旧上传 *.live.js 和 index.json（签名在 index.json 里，不用另传 .sig）
```

- 每次改了脚本都要重新签（`index` 会全部重签，没改的签名不变）；`verify` 不通过就不要上传。
- 第一次发布带 `publicKey` 的 index.json 后，已经添加过这个订阅的 App 会在下次读取时记下公钥；新用户添加时记下。
  之后不要换密钥，除非愿意让所有人重新添加订阅。

### 8.4 播放器的限制

- 直播间的 mpv 只允许 `tcp,tls,http,https,crypto` 协议（`demuxer-lavf-o` 的 `protocol_whitelist`；media_kit 默认还有
  `file,data,udp,rtp`）：播放地址和 HLS 列表来自网络，列表里写 `file:///…`、`data:`、`concat:`、`subfile:` 时 ffmpeg
  直接拒绝，不会读本机文件。本机中转（127.0.0.1）是 http，不受影响；AES-128 加密的 HLS 用 crypto。
- `allowed_extensions=ALL` 保留（Steam、YouTube 中转的分段没有扩展名，较新的 ffmpeg 对 http 分段也检查扩展名）；
  旧版 ffmpeg 里它只放开 `file:` 分段，而 `file` 已经不在白名单里。
- `playUrls` / `avPlayerUrls` 返回的地址只保留 http(s) 的。

## 9. 内置平台的修正（overrides）

平台（B站、斗鱼……）改了接口时，App 自带的代码就坏了，以前只能等新版 App。现在可以发一个**修正**：
一个普通的 `.live.js`，多写一行 `overrides = "bilibili"`，只实现坏掉的那几个函数。装上以后它不是一个新平台
（没有新的标签页，不出现在平台排序里），而是替换内置平台的这几个函数；没实现的照常用 App 内置的代码。

```js
class BilibiliPlayFix extends LiveSource {
  key = "bilibili_play_fix"
  name = "哔哩哔哩播放修正"
  version = "1.0.0"
  overrides = "bilibili"      // bilibili、douyu、huya、douyin、twitch、kick、youtube
  useAccount = true           // 可选：用 App 里登录的 B站 帐号（App 代为加，脚本读不到 Cookie），§9.5
  domains = ["api.live.bilibili.com"]

  // room 是内置的直播间，只有公开字段（room.builtIn 为 true），见 §9.2
  async qualities(room) { /* … */ return [{ name: "原画", data: 10000 }] }
  async playUrls(room, quality) { /* … */ return { urls, headers /*, hlsFix */ } }
}
```

测试用的示例（替换开播状态，接口和内置代码一样；不发布）：
`simple_live_core/test/fixtures/overrides/bilibili_live_status.live.js`。检查工具照常用，会打印替换了什么。

### 9.1 能替换什么

| 脚本函数 | 替换的 | 说明 |
|---|---|---|
| `recommend`、`categories`、`categoryRooms` | 首页推荐、分类、分类里的直播间 | 分类的 id 是平台自己的（和内置的一样） |
| `search`、`searchAnchors`、`suggest` | 搜索直播间、搜索主播、搜索联想 | B站、虎牙的“综合”搜索本来一次请求拿两种；替换了其中一个时分开请求 |
| `resolve` | 搜索时的“直达”（输入 → 房间号） | 出错时改用 App 内置的规则 |
| `room` | 直播间信息 | 没替换的后续函数用内置 `room()` 的结果，见 §9.2 |
| `liveStatus` | 开播状态（关注列表刷新） | 没写时用内置的（不会改调 `room()`） |
| `qualities`、`playUrls`、`avPlayerUrls` | 清晰度、播放地址、iOS 系统画中画的地址 | `playUrls` 可以带 `hlsFix`、用 `hls.rewrite`（§7）；替换 `qualities` 时必须也替换 `playUrls` |
| `superChats` | 醒目留言 | |
| `danmaku`（`danmaku.start`） | 弹幕 | 见 §9.2 |

- 修正**不能**改平台的 id、名字、图标、链接识别（不用写 `links`），也不能替换登录、账号关注：
  脚本里有 `login`、`account()` 时加载失败（这一版不替换内置平台的登录）。
- 至少要实现一个上表里的函数；`overrides` 不是上面 7 个 id 之一时加载失败。
- 同一个平台装了几个修正时只有一个生效（能生效的里面 key 排在前面的）；详情页写着其它的为什么没有生效。

### 9.2 数据怎么在脚本和内置代码之间传

- **脚本只拿到内置对象的公开字段**：
  - `room`（内置 `room()` 的结果）：`{ roomId, title, cover, userName, userAvatar, online, live, url, introduction,
    notice, isRecord, showTime, builtIn: true }`，**没有** `data`、`danmakuData`：内置的这两个里可能有登录的 Cookie、uid
    （如 B站 的弹幕参数）。脚本要用的签名、token 自己请求。
  - `quality`（没替换 `qualities` 时，内置的清晰度）：`{ name, data, sort, builtIn: true }`，`data` 为内置代码的格式
    （能转成 JSON 时，如 B站 的 qn 数字），不能转的为 null。
- **内置代码从不拿到脚本的数据**：
  - 替换了 `room`、没替换 `qualities` / `playUrls` / 弹幕时，App 在第一次用到时另外调用一次内置的 `room()`，
    把它的结果交给内置代码。所以内置 `room()` 也坏了时，这些要一起替换。
  - 脚本给的清晰度只交给脚本的 `playUrls` / `avPlayerUrls`；要交给内置代码时（失败改用内置、没替换 `avPlayerUrls`）
    按名字换成内置的清晰度（没有同名的用第一个；系统画中画换不了时改用 mpv 画中画）。
  - `qualities` 失败改用了内置的清晰度时，这些清晰度的播放地址也用内置的。
- 弹幕：替换了 `danmaku` 时调用脚本的 `danmaku.start(room, session)`（`room` 同上；斗鱼的内置直播间只有 `roomId`）。
  只替换了 `room` 时弹幕照旧是内置的，参数换成内置 `room()` 的。

### 9.3 失败时改用内置

每个修正有“失败时改用内置”（默认开）。脚本抛错、超时（20 秒，§2）、返回的数据格式不对时，App 写一条日志
（`[哔哩哔哩直播] 直播源修正 xxx 1.0.0 的 playUrls() 出错，改用内置：…`），这一次改用内置代码。
弹幕第一次就没连上（还没就绪过）时换成内置弹幕，聊天区提示一句；连上过之后断开照常按退避重连（§3）。
关掉这个设置时脚本的错误直接显示给用户（调试修正时用）。

### 9.4 安全

- **权限**：`overrides`、`useAccount` 是敏感功能（§8）。安装时确认框写明“这个直播源会替换内置的 哔哩哔哩 的：
  清晰度、播放地址”，用帐号时再写一行（帐号、白名单主机）。更新时多替换了函数、换了平台、新加 `useAccount`
  都要用户确认；只是少替换的直接更新。“全部更新”照旧逐个问扩大了权限的。
- **只装签名的**：修正只能从有签名的订阅安装（§8.2：第一次添加订阅时记下的公钥），也只有签名安装的才生效。
  自己写、测试修正时，在“直播源订阅 → 开发者选项”里打开“允许未签名的内置平台修正（不安全）”（默认关，打开前
  再确认一次）；关掉后未签名的修正马上停用（还在已安装列表里，详情页写着“没有签名，没有生效”）。
- **同步备份**：恢复时不自动装修正（提示“会替换内置平台，需要手动安装”），要用户自己看过确认框。
- **开关**：详情页的“启用”关掉后这个平台全部用内置代码。开关、“失败时改用内置”、开发者选项都只存在本机
  （`live_sources/overrides.json`），不同步。
- **让用户知道**：账号管理里这个平台下面写着“正在使用直播源修正：名字 版本”，进直播间时聊天区也提示一句，
  直播源列表里写着“替换内置的 …（…）· 生效中”。

### 9.5 用内置平台的帐号（useAccount）

内置平台在 App 里登录的 Cookie、令牌**从不交给脚本**：不进脚本引擎，`Http.getCookies` 读不到，也不进这个源的
Cookie 罐。声明 `useAccount = true`（安装时要用户确认）后，App 在这个源的后台 isolate 里给脚本的请求**代为**加上登录
信息，下面的条件全部满足才加：

1. 请求是 https（WebSocket 握手是 wss）；
2. 主机在 App 写死的白名单里（按内置代码实际用到的接口，脚本改不了），而且也在脚本的 `domains` 里；
3. 脚本声明了 `overrides` 和 `useAccount`（后台 isolate 按自己读到的脚本元数据判断）。

| 平台 | 加什么 | 白名单主机 |
|---|---|---|
| `bilibili` | Cookie（SESSDATA 等，App 里登录的） | `api.live.bilibili.com`、`live.bilibili.com`、`api.bilibili.com`、`*.chat.bilibili.com` |
| `douyu` | Cookie | `www.douyu.com`、`m.douyu.com` |
| `douyin` | 用户自己设置的 Cookie（默认的 ttwid 不算） | `live.douyin.com`、`www.douyin.com` |
| `twitch` | `Authorization: OAuth …` | `gql.twitch.tv` |
| `kick` | `Authorization: Bearer …` + Cookie `session_token` | `kick.com` |
| `youtube` | 网页 Cookie + 每次现算的 SAPISIDHASH（`Authorization`、`X-Origin`、`X-Goog-AuthUser`） | `www.youtube.com` |

虎牙在 App 里没有登录，不能用 `useAccount`（加载失败）。

- 登录、刷新 Cookie 的主机（`passport.bilibili.com`、`passport.douyu.com`……）故意不在白名单里；YouTube 只用网页 Cookie，
  不用官方授权的令牌（能做的事太多）。
- 帐号的 Cookie 放在最前面，脚本自己的 Cookie 里同名的去掉（盖不掉，也冒充不了）；`Authorization` 之类由 App 给，
  脚本自己写的被替换。
- 重定向的每一跳重新判断：跳到白名单外的主机就不带。
- 带了帐号的请求：响应的 Set-Cookie 不进脚本的 Cookie 罐，也不出现在 `res.headers` 里（平台刷新的登录 Cookie 脚本拿不到）。
- 还剩下的风险，所以要用户确认：脚本能用这个帐号调用白名单主机上的接口（读帐号信息、领取高清流；B站 需要 csrf 的写操作做
  不了，因为 `bili_jct` 读不到，Twitch / Kick 的令牌能做的事更多）。平台的接口要是把请求的 Cookie 原样写进响应正文，
  脚本能看到——内置代码用到的接口没有这样的。只在需要登录才能用的功能上声明 `useAccount`。

### 9.6 App 侧（Dart）

- `LiveSourceInfo.overrides`、`useAccount`、`isOverride`、`overrideFunctions`；`kBuiltInSiteNames`、
  `kLiveSourceOverridableFunctions`、`kBuiltInAccountHosts`、`describeLiveSourceOverride(...)`、`LiveSourceAccountAuth`。
- `LiveSourceManager`：`platformSites`（普通直播源）、`overrideSites`、`activeOverride(builtInId)`（`LiveSourceOverrideBinding`：
  `site`、`fallback`、`functions`）、`overrideStatus(key)`、`overrideEnabled` / `setOverrideEnabled`、
  `overrideFallback` / `setOverrideFallback`、`allowUnsignedOverrides` / `setAllowUnsignedOverrides`。
- 自带平台用 `OverridableBiliBiliSite`、`OverridableDouyuSite`……（`OverridableLiveSite` mixin）：就是原来的类
  （`is BiliBiliSite`、账号关注都不变），每个 LiveSite 函数先看 `overrideLookup`（App 用 `Sites.bindOverrides` 设成
  `manager.activeOverride`）；`overrideAccountAuth()` 给 `useAccount` 用的帐号；`overrideResolveRoomId`、`overrideSearchAll`
  给搜索直达、综合搜索用。
- `ScriptLiveSite.accountAuth`（只在声明了 `useAccount` 时生效）、`qualitiesFor` / `playUrlsFor` / `avPlayerUrlsFor`（直接传
  脚本的 room、quality）；`scriptBuiltInRoomArg`、`scriptBuiltInQualityArg`、`ScriptQualityData`（脚本给的清晰度）。
- 测试：`ScriptWorkerSettings.accountHostsForTest` 换掉白名单（同时允许 http，本机的假服务器用），App 里永远是 null。

### 9.7 什么能用修正修、什么还要新版 App

能用修正修（脚本更新就行）：

- 上表里函数用到的接口变了：换了地址、参数、返回结构；新的签名算法（斗鱼的 sign、虎牙的 anticode、B站 wbi 之类）；
  新的播放地址格式、CDN 要的请求头；HLS 列表的毛病（`hlsFix`、`hls.rewrite`）；
- 搜索、联想、分类、推荐接口变了；开播状态读错；醒目留言接口变了；
- 弹幕协议变了（只收；用 WebSocket 或轮询，§3）。

还要新版 App：

- 登录、Cookie 的获取和刷新、账号关注同步（这一版修正不能替换）；
- 内置平台的链接识别、界面上的东西（新的按钮、设置）；
- 需要脚本接口没有的能力：新的原生库、播放器参数、解码；JS 引擎做不到的（如 AES-GCM、很重的计算）；
  要访问的主机在 `useAccount` 白名单外而又必须带登录信息的；
- 修正本身的机制（白名单、数据怎么传）要改的。
