import 'package:flutter/widgets.dart';

/// 搜索以后光标留在输入框里，可以接着输入。
///
/// 输入框没有 onEditingComplete 时，按回车（手机上的搜索键）以后会失去焦点，
/// 手机上键盘也会收起。把它交给 [TextField.onEditingComplete] 就不会，
/// 输入法正在拼的字照样先上屏
VoidCallback keepTyping(TextEditingController text) => text.clearComposing;
