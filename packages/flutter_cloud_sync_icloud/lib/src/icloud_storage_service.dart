import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 'icloud_method_channel_contract.dart';

/// iCloud storage service implementation
///
/// P0-2 测试注入口：[_methodChannel] 的类型放宽为 method 兼容契约
/// （生产恒传 ICloudMethodChannel，测试注入 FakeICloudMethodChannel），
/// 使 _isNotFoundError 的错误分类可单测。
class ICloudStorageService implements CloudStorageService {
  final ICloudMethodChannelLike _methodChannel;

  ICloudStorageService(this._methodChannel);

  /// Safely convert a dynamic map to Map<String, dynamic>
  Map<String, dynamic>? _convertToStringDynamicMap(dynamic value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  /// 判断异常是否表示「文件/目录不存在」
  ///
  /// 优先检查 [PlatformException.code]（原生层返回的结构化错误码），
  /// 其次检查 message 中的关键词（兼容未规范 code 的原生实现）。
  /// 命中返回 true，调用方据此返回 null / 空列表 / false（幂等语义）；
  /// 未命中时调用方应抛出异常，避免把网络中断、权限不足误判为「不存在」。
  ///
  /// P0-2 修复（对齐 WebDAV WD-M3 审计口径）：此前 message 兜底含
  /// `contains('404')` 纯数字子串匹配 —— 异常消息内嵌 host:port
  /// （如 `:8404`）或对象名含 "404" 时，**任何网络/权限错误都会被误判
  /// 为「不存在」** → exists()=false → 调用方触发覆盖上传，静默盖掉云端
  /// 数据。WebDAV 侧同款问题已修（有结构化信息只看状态码；无结构化信息
  /// 仅措辞匹配、绝不做数字子串匹配），iCloud 侧同步收口：
  /// - code 判定收紧为精确值（原生侧约定错误码枚举），不再 contains；
  /// - message 兜底删除全部数字子串，仅保留明确的「不存在」措辞。
  bool _isNotFoundError(Object e) {
    if (e is PlatformException) {
      final code = e.code.toLowerCase();
      const notFoundCodes = {
        '404',
        'notfound',
        'not_found',
        'no_such_file',
        'file_not_found',
        'filenotfound',
        'nsfilenosuchfileerror',
        'nsfilereadnosuchfileerror',
      };
      if (notFoundCodes.contains(code)) {
        return true;
      }
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('nsfilereadnosuchfileerror') ||
        msg.contains('nsfilenosuchfileerror');
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    try {
      // Encode data as Base64 to avoid JSON escape issues
      final encodedData = base64Encode(utf8.encode(data));

      await _methodChannel.uploadFile(
        path: path,
        data: encodedData,
        metadata: metadata,
      );
    } catch (e) {
      throw CloudStorageException('Upload failed: $e', e);
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      final encodedData = await _methodChannel.downloadFile(path: path);

      if (encodedData == null) {
        return null;
      }

      // Decode Base64 data
      final bytes = base64Decode(encodedData);
      return utf8.decode(bytes);
    } catch (e) {
      // 文件不存在时返回 null（幂等语义），其他错误抛出
      if (_isNotFoundError(e)) {
        return null;
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<void> delete({required String path}) async {
    try {
      await _methodChannel.deleteFile(path: path);
    } catch (e) {
      // 忽略「文件不存在」错误（幂等删除），其他错误抛出
      if (!_isNotFoundError(e)) {
        throw CloudStorageException('Delete failed: $e', e);
      }
    }
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      final files = await _methodChannel.listFiles(path: path);
      return files.map((fileInfo) {
        return CloudFile(
          name: fileInfo['name'] as String,
          path: fileInfo['path'] as String,
          size: fileInfo['size'] as int?,
          lastModified: fileInfo['lastModified'] != null
              ? DateTime.tryParse(fileInfo['lastModified'] as String)
              : null,
          metadata: _convertToStringDynamicMap(fileInfo['metadata']),
        );
      }).toList();
    } catch (e) {
      // 目录不存在时返回空列表（幂等语义），其他错误抛出
      if (_isNotFoundError(e)) {
        return [];
      }
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    try {
      return await _methodChannel.fileExists(path: path);
    } catch (e) {
      // 仅在文件不存在（404/NSFileNoSuchFileError）时返回 false；
      // 其他错误（网络中断、iCloud 未启用等）必须抛出，避免调用方
      // 误判文件不存在而触发覆盖上传等危险操作。
      if (_isNotFoundError(e)) {
        return false;
      }
      throw CloudStorageException('Failed to check file existence: $e', e);
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      final metadata = await _methodChannel.getFileMetadata(path: path);
      if (metadata == null) {
        return null;
      }

      return CloudFile(
        name: metadata['name'] as String,
        path: metadata['path'] as String,
        size: metadata['size'] as int?,
        lastModified: metadata['lastModified'] != null
            ? DateTime.tryParse(metadata['lastModified'] as String)
            : null,
        metadata: _convertToStringDynamicMap(metadata['customMetadata']),
      );
    } catch (e) {
      if (_isNotFoundError(e)) {
        return null;
      }
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }
}
