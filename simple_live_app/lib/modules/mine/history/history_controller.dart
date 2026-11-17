import 'dart:async';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 观看记录变了（同步写入、删除），让列表刷新
void notifyHistoryChanged() {
  EventBus.instance.emit(Constant.kUpdateHistory, 0);
}

/// 同步（WebDAV/局域网/远程房间）写入观看记录后刷新列表
mixin _RefreshOnHistorySync<T> on BasePageController<T> {
  StreamSubscription<dynamic>? _historySubscription;

  @override
  void onInit() {
    _historySubscription = EventBus.instance.listen(
      Constant.kUpdateHistory,
      (_) => refreshData(),
    );
    super.onInit();
  }

  @override
  void onClose() {
    _historySubscription?.cancel();
    super.onClose();
  }
}

class HistoryController extends BasePageController<History>
    with _RefreshOnHistorySync<History> {
  @override
  Future<List<History>> getData(int page, int pageSize) {
    if (page > 1) {
      return Future.value([]);
    }
    return Future.value(DBService.instance.getHistores());
  }

  void clean() async {
    var result = await Utils.showAlertDialog("确定要清空观看记录吗？".t, title: "清空观看记录".t);
    if (!result) {
      return;
    }
    await DBService.instance.clearHistories();
    notifyHistoryChanged();
  }

  void removeItem(History item) async {
    list.remove(item);
    await DBService.instance.deleteHistory(item.id);
    notifyHistoryChanged();
  }
}
