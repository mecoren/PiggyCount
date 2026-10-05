/// SQLCipher 能力探测（测试侧入口）：**当前构建拿到的 native SQLite 支不支持整库加密**。
///
/// 为什么测试要先探测再跑：同一个仓库在不同平台/构建下拿到的库不同 ——
/// 实测（见 `pubspec.yaml` 的 hooks 注释）Windows 单测能拿到 SQLCipher，
/// 而 Android 产物里 hook 的 `libsqlcipher.so` **没有被复制进 APK**。
/// 依赖加密语义的测试因此必须"能跑才跑，不能跑就**带原因**跳过"，
/// 绝不允许假装通过（那会把"没加密"验成"加密了"）。
///
/// 判据直接复用生产代码的 [SqlCipherCapability]：**测试跳过与生产拒绝必须同一
/// 个判据**，否则会出现"测试跳过说没能力、生产却以为有能力"的错位。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/data/encryption/sqlcipher_capability.dart';

bool get isSqlCipherAvailable => SqlCipherCapability.isSupported;

/// 跳过原因（写成一句能直接看懂的话，不要只说 "skipped"）。
String get sqlCipherSkipReason =>
    '当前 native SQLite 不是 SQLCipher 构建（PRAGMA cipher_version 为空）：'
    '本机 hook 未提供加密版，实测引擎自述「${SqlCipherCapability.describe()}」。'
    '见 pubspec.yaml 的 hooks 注释与 prd/sqlcipher_db_encryption/design.md §7。';

/// 需要 SQLCipher 的用例：不支持时按 [sqlCipherSkipReason] 跳过。
void sqlCipherTest(String description, dynamic Function() body) =>
    test(description, body,
        skip: isSqlCipherAvailable ? null : sqlCipherSkipReason);
