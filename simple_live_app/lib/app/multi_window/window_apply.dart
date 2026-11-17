import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

/// 主窗口：把副窗口交来的改动存下来，和在主窗口里改的一样（关注会照常同步到账号）
class AppWindowChangeSink implements WindowChangeSink {
  @override
  Future<void> apply(WindowChange change) async {
    switch (change) {
      case FollowAdded(:var user, :var origin):
        await FollowService.instance.follow(user, origin: origin);
        EventBus.instance.emit(Constant.kUpdateFollow, user.id);
      case FollowRemoved(:var user, :var origin, :var localOnly):
        await FollowService.instance
            .unfollow(user, origin: origin, localOnly: localOnly);
        EventBus.instance.emit(Constant.kUpdateFollow, user.id);
      case FollowNotifyChanged(:var id, :var notify):
        var item = DBService.instance.followBox.get(id);
        if (item != null && item.notify != notify) {
          await FollowService.instance.setNotify(item, notify);
        }
      case HistoryPut(:var history):
        await DBService.instance.addOrUpdateHistory(history);
        _historyChanged();
      case HistoryRemoved(:var ids):
        for (var id in ids) {
          await DBService.instance.deleteHistory(id);
        }
        _historyChanged();
      case HistoryCleared(:var live):
        await DBService.instance.clearHistories(live: live);
        _historyChanged();
      case ChatUsersChanged():
        ChatUsersService.instance.applyWindowChange(change);
      case QualityRemembered(:var siteId, :var name, :var index, :var cellular):
        PlayPrefs.instance.storeRemembered(
          siteId,
          RememberedQuality(name, index),
          cellular: cellular,
        );
    }
  }

  void _historyChanged() => EventBus.instance.emit(Constant.kUpdateHistory, 0);
}
