// 测试用直播源：弹幕会话（本地 WebSocket 和轮询）
const BASE = "{{BASE}}";

class DanmakuTest extends LiveSource {
  key = "test_danmaku";
  name = "弹幕测试";
  version = "1.0.0";
  domains = ["127.0.0.1"];

  async room(roomId) {
    return {
      roomId, title: "弹幕房间", cover: "", userName: "主播", userAvatar: "", online: 0, live: true, url: "",
      danmakuData: { mode: roomId.startsWith("poll") ? "poll" : "ws", ws: BASE.replace("http://", "ws://") + "/ws/" + roomId },
    };
  }

  async getStopped() { return (await Storage.get("stopped")) || 0; }

  danmaku = {
    async start(room, session) {
      const d = room.danmakuData;
      session.data.count = 0;
      if (d.mode === "poll") {
        session.ready();
        let n = 0;
        session.setInterval(async () => {
          n++;
          const r = await Http.get(BASE + "/rooms", { query: { page: n }, responseType: "json" });
          session.emit([{ type: "chat", user: "轮询", text: "第" + n + "次 " + r.body.rooms[0].roomId }]);
        }, 40);
        return;
      }
      const ws = await session.websocket(d.ws, { headers: { "X-Room": room.roomId } });
      // 先等一下再设置 onMessage：期间到达的消息会先缓存
      await new Promise((r) => setTimeout(r, 30));
      ws.onMessage = (data) => {
        if (typeof data === "string") {
          const m = JSON.parse(data);
          if (m.cmd === "hello") {
            session.ready();
            ws.send("join:" + room.roomId);
          } else if (m.cmd === "chat") {
            session.emit([{ type: "chat", user: m.user, text: m.text, color: 0x0000ff, face: "https://example.com/f.png" }]);
          } else if (m.cmd === "fail") {
            session.fail("服务器要求断开");
          } else if (m.cmd === "sys") {
            session.emit({ type: "system", text: m.text });
          }
        } else {
          const p = Proto.decode(data);
          session.emit([
            { type: "online", online: Proto.num(p[1]) },
            { type: "superChat", user: Proto.str(p[2]), text: Proto.str(p[3]), price: 30, startTime: 1700000000000, endTime: 1700000060000, id: "sc" + Proto.num(p[1]) },
          ]);
        }
      };
      ws.onClose = (code, reason) => { log("连接关闭", code, reason); };
      session.setInterval(() => ws.send(new Proto.Writer().varint(1, ++session.data.count).finish()), 50);
    },
    async stop(session) {
      await Storage.set("stopped", ((await Storage.get("stopped")) || 0) + 1);
    },
  };
}
