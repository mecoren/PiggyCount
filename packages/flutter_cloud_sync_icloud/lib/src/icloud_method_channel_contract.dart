/// P0-2：ICloudStorageService 依赖的 method-channel 方法契约。
///
/// 生产实现为 ICloudMethodChannel（implements 本契约）；测试注入假桩
/// （P0-2 的「不存在」错误分类单测，异常消息内嵌端口号的反例）。
/// 签名与 ICloudMethodChannel 的对应公开方法一致。
library;

abstract class ICloudMethodChannelLike {
  Future<void> uploadFile({
    required String path,
    required String data,
    Map<String, String>? metadata,
  });

  Future<String?> downloadFile({required String path});

  Future<void> deleteFile({required String path});

  Future<List<Map<String, dynamic>>> listFiles({required String path});

  Future<bool> fileExists({required String path});

  Future<Map<String, dynamic>?> getFileMetadata({required String path});
}
