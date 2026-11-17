import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 一个榜单读到的内容
class LiveRankData {
  List<LiveRankItem> items = const [];
  int? total;

  /// 最后一次读成功的时间，从没读成功过时为 null
  DateTime? updatedAt;

  /// 最后一次读失败的原因（读成功后清掉）
  String? error;
  bool loading = false;
}

/// 直播间的“榜单”页：平台的榜单加上本场礼物榜。
///
/// 打开时读一次；下拉或点刷新再读，显示更新时间。平台推送的前几名
/// （[LiveRankUpdate]）并进已经读到的榜单。换直播间时 [reset]
class LiveRankState {
  LiveRankState({
    required this.platformBoards,
    required this.fetch,
    required this.giftRanking,
    this.ready = _always,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static bool _always() => true;

  /// 平台的榜单（没有时为空，只有本场礼物榜）
  final List<LiveRankBoard> Function() platformBoards;

  /// 读平台的一个榜单
  final Future<LiveRankList> Function(String boardId) fetch;

  /// 本场礼物榜（按收到的礼物算）
  final List<LiveRankItem> Function() giftRanking;

  /// 能读了（直播间信息已经读到）。在 Obx 里调用，读到后界面会刷新
  final bool Function() ready;

  final DateTime Function() _now;

  /// 有变化时加一，界面据此刷新
  final version = 0.obs;

  /// 选中的榜单，为空时是第一个
  final selectedId = "".obs;

  /// 只看前十
  final topTen = false.obs;

  /// 只看有粉丝牌的
  final medalOnly = false.obs;

  final Map<String, LiveRankData> _data = {};

  /// 换直播间时加一：读的时候换了直播间，结果不要
  int _generation = 0;

  List<LiveRankBoard> get boards => [...platformBoards(), kGiftRankBoard];

  LiveRankBoard get current {
    var all = boards;
    return all.firstWhere(
      (e) => e.id == selectedId.value,
      orElse: () => all.first,
    );
  }

  LiveRankData dataOf(String boardId) =>
      _data.putIfAbsent(boardId, LiveRankData.new);

  LiveRankData get currentData => dataOf(current.id);

  /// 当前榜单按“只看前十”“只看有粉丝牌”筛过以后的
  List<LiveRankItem> get visible {
    Iterable<LiveRankItem> list = currentData.items;
    if (medalOnly.value) {
      list = list.where((e) => e.hasMedal);
    }
    if (topTen.value) {
      list = list.where((e) => e.rank <= 10);
    }
    return list.toList();
  }

  void _changed() => version.value++;

  void select(String boardId) {
    if (selectedId.value == boardId) {
      return;
    }
    selectedId.value = boardId;
    _changed();
    ensureLoaded();
  }

  /// 当前榜单还没读过（也没有读失败）时读一次
  void ensureLoaded() {
    var data = currentData;
    if (data.updatedAt == null &&
        data.error == null &&
        !data.loading &&
        ready()) {
      refresh();
    }
  }

  /// 重新读当前榜单（本场礼物榜重新算）
  Future<void> refresh() async {
    var board = current;
    var data = dataOf(board.id);
    if (board.id == kGiftRankBoard.id) {
      data
        ..items = giftRanking()
        ..total = null
        ..updatedAt = _now()
        ..error = null;
      _changed();
      return;
    }
    if (data.loading) {
      return;
    }
    var generation = _generation;
    data.loading = true;
    _changed();
    try {
      var list = await fetch(board.id);
      if (generation != _generation) return;
      data
        ..items = list.items
        ..total = list.total
        ..updatedAt = _now()
        ..error = null;
    } catch (e) {
      if (generation != _generation) return;
      data.error = e.toString();
    } finally {
      if (generation == _generation) {
        data.loading = false;
        _changed();
      }
    }
  }

  /// 弹幕连接推送的前几名：这个榜单读到过时并进去（更新时间不变）
  void applyUpdate(LiveRankUpdate update) {
    var data = _data[update.boardId];
    if (data == null || data.updatedAt == null) {
      return;
    }
    data.items = mergeRankTop(data.items, update.items);
    _changed();
  }

  /// 换直播间：清掉读到的内容，回到第一个榜单（筛选保留）
  void reset() {
    _generation++;
    _data.clear();
    selectedId.value = "";
    _changed();
  }
}
