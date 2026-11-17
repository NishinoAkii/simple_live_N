import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class AppErrorWidget extends StatelessWidget {
  final Function()? onRefresh;
  final String errorMsg;
  const AppErrorWidget({this.errorMsg = "", this.onRefresh, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: () {
          onRefresh?.call();
        },
        child: Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(24),
                child: Icon(
                  Remix.error_warning_line,
                  size: 72,
                  color: Colors.grey,
                ),
              ),
              Text(
                "{errorMsg}\r\n点击刷新".tf({"errorMsg": errorMsg}),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
