import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class AppEmptyWidget extends StatelessWidget {
  final Function()? onRefresh;
  const AppEmptyWidget({this.onRefresh, Key? key}) : super(key: key);

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
                child: Icon(Remix.inbox_line, size: 72, color: Colors.grey),
              ),
              Text(
                "这里什么都没有".t,
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
