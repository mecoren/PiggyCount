import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'icloud_method_channel_contract.dart';

/// Method Channel for iCloud native communication
class ICloudMethodChannel implements ICloudMethodChannelLike {
  static const MethodChannel _channel =
      MethodChannel('com.piggycount.app/icloud');

  /// P3：method-channel 调用默认 30s 超时；downloadFile 90s ——
  /// 原生侧下载 staging 已有轮询等待 + 大文件传输余量。
  /// 无超时场景下原生挂起会让同步 UI 永久卡死。
  static const _defaultTimeout = Duration(seconds: 30);
  static const _downloadTimeout = Duration(seconds: 90);

  /// 带超时的 method-channel 调用。
  ///
  /// 静态 + @visibleForTesting：单测可用假 MethodChannel（永不回复的
  /// mock handler）验证超时语义；实例方法统一走 [_invoke] 不直接触
  /// _channel，保证超时约束无法被绕过。
  @visibleForTesting
  static Future<T?> invokeWithTimeout<T>(
    MethodChannel channel,
    String method,
    Map<String, dynamic>? args, {
    Duration timeout = _defaultTimeout,
  }) {
    return channel.invokeMethod<T>(method, args).timeout(timeout,
        onTimeout: () => throw TimeoutException(
            'iCloud $method 超时（${timeout.inSeconds}s）'));
  }

  Future<T?> _invoke<T>(String method, Map<String, dynamic>? args,
      {Duration timeout = _defaultTimeout}) {
    return invokeWithTimeout<T>(_channel, method, args, timeout: timeout);
  }

  /// Check if iCloud is available
  /// Returns false if there's any error (including plugin not registered)
  Future<bool> isICloudAvailable() async {
    try {
      final result = await _invoke<bool>('isICloudAvailable', null);
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('iCloud: PlatformException in isICloudAvailable: ${e.message}');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('iCloud: Plugin not registered: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('iCloud: Error in isICloudAvailable: $e');
      return false;
    }
  }

  /// Initialize iCloud container
  /// Throws exception if initialization fails
  Future<void> initializeContainer() async {
    try {
      await _invoke<void>('initializeContainer', null);
    } on PlatformException catch (e) {
      debugPrint('iCloud: PlatformException in initializeContainer: ${e.message}');
      throw Exception('iCloud container initialization failed: ${e.message}');
    } on MissingPluginException catch (e) {
      debugPrint('iCloud: Plugin not registered: ${e.message}');
      throw Exception('iCloud plugin not available: ${e.message}');
    } catch (e) {
      debugPrint('iCloud: Error in initializeContainer: $e');
      throw Exception('iCloud container initialization failed: $e');
    }
  }

  /// Upload file to iCloud
  @override
  Future<void> uploadFile({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    await _invoke<void>('uploadFile', {
      'path': path,
      'data': data,
      'metadata': metadata,
    });
  }

  /// Download file from iCloud
  @override
  Future<String?> downloadFile({required String path}) async {
    return await _invoke<String>('downloadFile', {
      'path': path,
    }, timeout: _downloadTimeout);
  }

  /// Delete file from iCloud
  @override
  Future<void> deleteFile({required String path}) async {
    await _invoke<void>('deleteFile', {
      'path': path,
    });
  }

  /// List files in directory
  @override
  Future<List<Map<String, dynamic>>> listFiles({required String path}) async {
    final result = await _invoke<List>('listFiles', {
      'path': path,
    });
    return result?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ??
        [];
  }

  /// Check if file exists
  ///
  /// ICL-2（2026-09-12 P1）：原生侧容器未初始化/路径校验失败以
  /// FlutterError（code ICLOUD_1001/1002）透传为 PlatformException，
  /// 本方法不捕获——让 ICloudStorageService.exists 的错误分类
  /// （非 NotFound 一律上抛）把环境故障与「文件不存在」区分开。
  /// `result ?? false` 仅兜底原生返回 null 的防御形态。
  @override
  Future<bool> fileExists({required String path}) async {
    final result = await _invoke<bool>('fileExists', {
      'path': path,
    });
    return result ?? false;
  }

  /// Get file metadata
  @override
  Future<Map<String, dynamic>?> getFileMetadata({required String path}) async {
    final result = await _invoke<Map>('getFileMetadata', {
      'path': path,
    });
    return result != null ? Map<String, dynamic>.from(result) : null;
  }

  /// Get iCloud account info
  Future<Map<String, dynamic>?> getICloudAccountInfo() async {
    final result = await _invoke<Map>('getICloudAccountInfo', null);
    return result != null ? Map<String, dynamic>.from(result) : null;
  }

  /// Get detailed iCloud diagnostics
  Future<Map<String, dynamic>> getICloudDiagnostics() async {
    try {
      final result = await _invoke<Map>('getICloudDiagnostics', null);
      return result != null ? Map<String, dynamic>.from(result) : {};
    } on PlatformException catch (e) {
      debugPrint('iCloud: PlatformException in getICloudDiagnostics: ${e.message}');
      return {'error': e.message};
    } on MissingPluginException catch (e) {
      debugPrint('iCloud: Plugin not registered: ${e.message}');
      return {'error': 'Plugin not registered'};
    } catch (e) {
      debugPrint('iCloud: Error in getICloudDiagnostics: $e');
      return {'error': e.toString()};
    }
  }
}
