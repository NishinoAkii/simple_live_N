import 'dart:convert';

import 'package:simple_live_app/services/sync_lan_crypto.dart';

T? asT<T>(dynamic value) {
  if (value is T) {
    return value;
  }
  return null;
}

class SyncClientInfoModel {
  SyncClientInfoModel({
    required this.name,
    required this.version,
    required this.address,
    required this.port,
    required this.type,
    this.extSites = const [],
    this.features = const [],
    this.encKey,
  });

  factory SyncClientInfoModel.fromJson(Map<String, dynamic> json) =>
      SyncClientInfoModel(
        type: asT<String>(json['type'])!,
        name: asT<String>(json['name'])!,
        version: asT<String>(json['version'])!,
        address: asT<String>(json['address'])!,
        port: asT<int>(json['port'])!,
        extSites: (asT<List>(json['extSites']) ?? [])
            .map((e) => e.toString())
            .toList(),
        features: (asT<List>(json['features']) ?? [])
            .map((e) => e.toString())
            .toList(),
        encKey:
            (asT<List>(json['features']) ?? []).contains(LanSyncCrypto.feature)
                ? asT<String>(json[LanSyncCrypto.infoKey])
                : null,
      );
  String type;
  String name;
  String version;
  String address;
  int port;

  /// 对方支持的新平台；官方版为空
  List<String> extSites;

  /// 对方支持的附加同步内容（如 live_sources）；官方版和旧版为空
  List<String> features;

  /// 对方的公钥：有时发送的内容加密（[LanSyncCrypto]）；官方版和旧版为 null，发明文
  String? encKey;

  @override
  String toString() {
    return jsonEncode(this);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'version': version,
        'address': address,
        'port': port,
        'type': type,
      };
}
