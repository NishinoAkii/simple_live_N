// 只给测试用（不发布、不放进 live_sources/）：替换内置哔哩哔哩的“开播状态”，
// 用的接口和内置代码（BiliBiliSite.getLiveStatus）一样，见 doc/live_source_api.md §9
class BilibiliLiveStatusFix extends LiveSource {
  key = "bilibili_live_status_fix"
  name = "哔哩哔哩开播状态修正"
  version = "1.0.0"
  description = "测试用：room/v1/Room/get_info 读开播状态"
  overrides = "bilibili"          // 替换内置的哔哩哔哩；只替换下面实现了的函数
  domains = ["api.live.bilibili.com"]

  async liveStatus(roomId) {
    const res = await Http.get("https://api.live.bilibili.com/room/v1/Room/get_info", {
      query: { room_id: String(roomId) },
      headers: { referer: "https://live.bilibili.com/" },
      responseType: "json",
    })
    const body = res.body
    if (res.status !== 200 || !body || body.code !== 0) {
      throw new Error("读取开播状态失败（" + (body && body.message ? body.message : "HTTP " + res.status) + "）")
    }
    return body.data.live_status === 1
  }
}
