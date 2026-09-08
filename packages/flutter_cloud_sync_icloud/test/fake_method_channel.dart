/// P0-2 单测假桩：按方法注入错误，其余调用透传成功值。
///
/// 测试只关心 ICloudStorageService 的错误分类（_isNotFoundError），
/// 不关心成功路径的返回内容。
library;

import 'package:flutter_cloud_sync_icloud/src/icloud_method_channel_contract.dart';

class FakeICloudMethodChannel implements ICloudMethodChannelLike {
  FakeICloudMethodChannel({
    this.downloadError,
    this.existsError,
    this.uploadError,
    this.listError,
    this.deleteError,
    this.metadataError,
  });

  final Object? downloadError;
  final Object? existsError;
  final Object? uploadError;
  final Object? listError;
  final Object? deleteError;
  final Object? metadataError;

  void _maybeThrow(Object? error) {
    if (error != null) throw error;
  }

  @override
  Future<void> uploadFile({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    _maybeThrow(uploadError);
  }

  @override
  Future<String?> downloadFile({required String path}) async {
    _maybeThrow(downloadError);
    return null;
  }

  @override
  Future<void> deleteFile({required String path}) async {
    _maybeThrow(deleteError);
  }

  @override
  Future<List<Map<String, dynamic>>> listFiles({required String path}) async {
    _maybeThrow(listError);
    return const [];
  }

  @override
  Future<bool> fileExists({required String path}) async {
    _maybeThrow(existsError);
    return true;
  }

  @override
  Future<Map<String, dynamic>?> getFileMetadata({required String path}) async {
    _maybeThrow(metadataError);
    return null;
  }
}
