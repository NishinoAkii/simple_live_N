import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

/// 卡住 20 秒时：数据还在进来就再等等（最多再等 40 秒），没数据或者读不到速度就重连
void main() {
  const wait = LiveRoomController.keepWaitingForSlowNetwork;

  test('数据还在进来：再等', () {
    expect(wait(200 * 1024, const Duration(seconds: 20)), isTrue);
    expect(wait(16 * 1024, const Duration(seconds: 50)), isTrue);
  });

  test('没有数据、太慢或者读不到速度：重连', () {
    expect(wait(0, const Duration(seconds: 20)), isFalse);
    expect(wait(8 * 1024, const Duration(seconds: 20)), isFalse);
    expect(wait(null, const Duration(seconds: 20)), isFalse);
  });

  test('最多再等 40 秒', () {
    expect(wait(500 * 1024, const Duration(seconds: 59)), isTrue);
    expect(wait(500 * 1024, const Duration(seconds: 60)), isFalse);
  });
}
