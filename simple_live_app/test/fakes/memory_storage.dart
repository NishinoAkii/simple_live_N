import 'package:get/get.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 只放在内存里的设置。控件测试（testWidgets）里写 Hive 的操作完成不了，
/// 之后关盒子时会一直等着；改设置的控件测试用这个
class MemoryStorage extends LocalStorageService {
  final Map<dynamic, dynamic> values = {};

  @override
  T getValue<T>(dynamic key, T defaultValue) {
    var value = values[key];
    return value is T ? value : defaultValue;
  }

  @override
  Future setValue<T>(dynamic key, T value) async {
    values[key] = value;
  }

  @override
  Future removeValue<T>(dynamic key) async {
    values.remove(key);
  }

  static MemoryStorage install() {
    var storage = MemoryStorage();
    Get.put<LocalStorageService>(storage);
    return storage;
  }
}
