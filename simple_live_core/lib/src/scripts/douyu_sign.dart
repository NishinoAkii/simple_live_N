import 'package:dart_quickjs/dart_quickjs.dart';
import 'package:simple_live_core/src/scripts/crypto_js.dart' as crypto_js;

class DouyuSign {
  static const String kCryptoJs = crypto_js.kCryptoJs;

  static String getSign(String html, String rid) {
    JsRuntime flutterJs = JsRuntime(
      memoryLimit: 4 * 1024 * 1024,
      maxStackSize: 64 * 1024,
    );

    flutterJs.eval(kCryptoJs);

    var did = "10000000000000000000000000001501";
    var time = (DateTime.now().millisecondsSinceEpoch / 1000).round();
    flutterJs.eval(html);
    var data = flutterJs.eval("ub98484234('$rid','$did','$time')");
    flutterJs.dispose();
    return data;
  }
}
