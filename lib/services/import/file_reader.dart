import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:gbk_codec/gbk_codec.dart';

/// 文件读取进度回调
typedef ProgressCallback = void Function(double progress);

/// 文件读取服务
class FileReaderService {
  /// 读取文件内容为文本
  ///
  /// 支持:
  /// - CSV 文件 (自动检测编码: UTF-8, GBK, UTF-16)
  /// - XLSX 文件 (需要提供 xlsxConverter)
  ///
  /// [file] 要读取的文件
  /// [onProgress] 进度回调 (0.0 - 1.0)
  /// [xlsxConverter] XLSX 转 CSV 的转换器函数
  static Future<String> readFile(
    PlatformFile file, {
    ProgressCallback? onProgress,
    String Function(Uint8List)? xlsxConverter,
  }) async {
    // 检查文件扩展名
    final fileName = file.name.toLowerCase();
    final isXlsx = fileName.endsWith('.xlsx');

    // 读取文件字节
    final Uint8List bytes;
    if (file.path == null || file.path!.isEmpty) {
      // file_picker 12+ 去掉了 withData / PlatformFile.bytes，
      // 无本地路径（web / blob / 沙盒）时按需读取；读失败按空文件处理。
      Uint8List? inMemory;
      try {
        inMemory = await file.readAsBytes();
      } catch (_) {
        inMemory = null;
      }
      bytes = inMemory ?? Uint8List(0);
      if (bytes.isEmpty) return '';
    } else {
      bytes = await _readFileWithProgress(
        file.path!,
        onProgress: onProgress,
      );
    }

    if (bytes.isEmpty) return '';

    // 转换为文本
    if (isXlsx) {
      if (xlsxConverter == null) {
        throw ArgumentError('xlsxConverter is required for XLSX files');
      }
      return xlsxConverter(bytes);
    } else {
      return decodeBytes(bytes);
    }
  }

  /// 流式读取文件并显示进度
  ///
  /// 直接 readInto 一块预分配的 `Uint8List`：10MB 文件 = 10MB 峰值。
  /// 旧实现是分块存进 `List<List<int>>` 再 `addAll` 到 `List<int>`，
  /// Dart 的 `List<int>` 每元素占 8 字节（Smi），同样的 10MB 文件要吃 ~80MB
  /// 外加倍增冗余 + 分块本身，峰值约 9 倍。
  static Future<Uint8List> _readFileWithProgress(
    String filePath, {
    ProgressCallback? onProgress,
  }) async {
    final file = File(filePath);
    final exists = await file.exists();
    if (!exists) return Uint8List(0);

    final length = await file.length();
    if (length == 0) return Uint8List(0);
    final raf = await file.open();

    try {
      final buffer = Uint8List(length);
      int offset = 0;

      while (offset < length) {
        final read = await raf.readInto(buffer, offset, length);
        if (read <= 0) break;
        offset += read;

        if (onProgress != null) {
          onProgress(offset / length);
        }

        await Future<void>.delayed(Duration.zero);
      }

      return offset == length
          ? buffer
          : Uint8List.sublistView(buffer, 0, offset);
    } finally {
      await raf.close();
    }
  }

  /// 解码字节为文本，自动识别编码
  ///
  /// 支持的编码:
  /// - UTF-16 (LE/BE with BOM)
  /// - UTF-8 (with/without BOM)
  /// - GBK (中文)
  /// - Latin1 (兜底)
  static String decodeBytes(List<int> bytes) {
    if (bytes.length >= 2) {
      // UTF-16 LE BOM FF FE
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        try {
          final codeUnits = <int>[];
          for (int i = 2; i + 1 < bytes.length; i += 2) {
            codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
          }
          return String.fromCharCodes(codeUnits);
        } catch (_) {
          // 解码失败回退后续编码探测（UTF-8/GBK/Latin1 兜底）
        }
      }
      // UTF-16 BE BOM FE FF
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        try {
          final codeUnits = <int>[];
          for (int i = 2; i + 1 < bytes.length; i += 2) {
            codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
          }
          return String.fromCharCodes(codeUnits);
        } catch (_) {
          // 解码失败回退后续编码探测（UTF-8/GBK/Latin1 兜底）
        }
      }
    }

    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }

    // 尝试 UTF-8 解码
    try {
      final utfText = utf8.decode(bytes, allowMalformed: false);
      // 检测是否有乱码字符 (Unicode replacement character U+FFFD)
      if (!utfText.contains('\uFFFD')) {
        return utfText;
      }
    } catch (_) {
      // UTF-8 解码失败，继续尝试 GBK
    }

    // 尝试 GBK 解码（支付宝旧版本 Windows 导出常用）
    try {
      final gbkText = gbk_bytes.decode(bytes);
      // F1:走到 GBK 分支说明 UTF-8 已失败或含乱码标记。GBK 解码成功且
      // 无 U+FFFD 即采用 —— 不再强制要求"含中文",否则含全角标点/智能
      // 引号等非 CJK 字符的 GBK 文件会被误判、退回 allowMalformed UTF-8 乱码。
      if (!gbkText.contains('\uFFFD')) {
        return gbkText;
      }
    } catch (_) {
      // GBK 解码失败
    }

    // 兜底：使用 allowMalformed 的 UTF-8
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      // 最后的兜底 latin1
      return latin1.decode(bytes);
    }
  }
}
