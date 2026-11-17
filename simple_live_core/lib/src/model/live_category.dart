import 'dart:convert';

class LiveCategory {
  final String name;
  final String id;
  final List<LiveSubCategory> children;
  LiveCategory({
    required this.id,
    required this.name,
    required this.children,
  });

  @override
  String toString() {
    return json.encode({
      "name": name,
      "id": id,
      "children": children,
    });
  }
}

class LiveSubCategory {
  final String name;
  final String? pic;
  final String id;
  final String parentId;

  /// 下一层分类（抖音的分类可以有好几层），没有时为空
  final List<LiveSubCategory> children;
  LiveSubCategory({
    required this.id,
    required this.name,
    required this.parentId,
    this.pic,
    this.children = const [],
  });

  bool get hasChildren => children.isNotEmpty;

  Map<String, dynamic> toJson() => {
        "name": name,
        "id": id,
        "parentId": parentId,
        "pic": pic,
        if (children.isNotEmpty) "children": children,
      };

  @override
  String toString() {
    return json.encode(toJson());
  }
}
