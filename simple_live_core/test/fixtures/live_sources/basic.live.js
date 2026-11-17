// 测试用直播源：BASE 在测试里替换为本地服务器地址
const BASE = "{{BASE}}";

class TestLive extends LiveSource {
  key = "test_basic";
  name = "测试直播";
  version = "1.2.3";
  apiVersion = 1;
  url = "{{BASE}}/sources/basic.live.js";
  description = "运行时测试用";
  domains = ["127.0.0.1", "*.example.com"];
  links = ["test\\.example\\.com/(\\d+)"];

  async recommend(page) {
    const r = await Http.get(BASE + "/rooms", { query: { page }, responseType: "json" });
    return { hasMore: r.body.hasMore, rooms: r.body.rooms };
  }

  async categories() {
    return [{ id: "game", name: "游戏", children: [{ id: "lol", name: "英雄联盟", pic: "https://example.com/lol.png" }] }];
  }

  async categoryRooms(category, page) {
    return { hasMore: false, rooms: [{ roomId: category.parentId + "-" + category.id, title: category.name, cover: "", userName: "u", online: page }] };
  }

  async search(keyword, page) {
    return { hasMore: page < 2, rooms: [{ roomId: "s1", title: "搜索：" + keyword, cover: "", userName: "主播", online: 7n }] };
  }

  async searchAnchors(keyword, page) {
    return { hasMore: false, anchors: [{ roomId: "a1", userName: keyword, avatar: "https://example.com/a.png", live: true }] };
  }

  async room(roomId) {
    if (roomId === "missing") throw new Error("房间不存在");
    return {
      roomId, title: "房间" + roomId, cover: "https://example.com/c.jpg", userName: "主播" + roomId,
      userAvatar: "https://example.com/a.jpg", online: 1234, live: roomId !== "off", introduction: "简介",
      url: "https://test.example.com/" + roomId, data: { rid: roomId, n: 1 }, danmakuData: { ws: BASE.replace("http", "ws") + "/ws/" + roomId },
      extra: "保留字段",
    };
  }

  async qualities(room) {
    return [
      { name: "原画", data: { q: "origin", rid: room.data.rid, extra: room.extra } },
      { name: "高清", data: { q: "hd" }, sort: 1 },
    ];
  }

  async playUrls(room, quality) {
    return { urls: ["https://cdn.example.com/live/" + room.roomId + "_" + quality.data.q + ".flv?token=abc"], headers: { referer: "https://test.example.com/" } };
  }

  async superChats(roomId) {
    return [{ user: "老板", text: "加油", price: 30, startTime: 1700000000000, endTime: 1700000060000, backgroundColor: "#EDF5FF", id: "sc1" }];
  }

  // ---- 以下是测试专用的方法，App 不会调用 ----
  echo(...args) { return args; }
  utf8() { return { name: this.name, len: "直播😀".length, bytes: Bytes.toHex(Bytes.fromUtf8("直播😀")), back: Bytes.toUtf8(Bytes.fromUtf8("直播😀")) }; }
  never() { return new Promise(() => {}); }
  spin() { while (true) {} }
  boom() { throw new Error("脚本出错了"); }
  big() { return { v: 12345678901234567890n, s: 5n }; }
}
