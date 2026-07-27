import 'package:meta/meta.dart';

/// 加密配置状态
///
/// 不可变值对象，用于 Riverpod provider 暴露加密状态给 UI。
/// 修改状态通过 [EncryptionService] 的方法完成。
@immutable
class EncryptionSettings {
  /// 加密功能是否已开启
  final bool isEnabled;

  /// 当前是否有可用密钥（已开启加密且 secure storage 中存在密钥）
  final bool hasActiveKey;

  const EncryptionSettings({
    required this.isEnabled,
    required this.hasActiveKey,
  });

  /// 初始状态：未开启、无密钥
  static const EncryptionSettings initial = EncryptionSettings(
    isEnabled: false,
    hasActiveKey: false,
  );

  /// 已开启且密钥可用
  static const EncryptionSettings active = EncryptionSettings(
    isEnabled: true,
    hasActiveKey: true,
  );

  EncryptionSettings copyWith({
    bool? isEnabled,
    bool? hasActiveKey,
  }) {
    return EncryptionSettings(
      isEnabled: isEnabled ?? this.isEnabled,
      hasActiveKey: hasActiveKey ?? this.hasActiveKey,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EncryptionSettings &&
          runtimeType == other.runtimeType &&
          isEnabled == other.isEnabled &&
          hasActiveKey == other.hasActiveKey;

  @override
  int get hashCode => Object.hash(isEnabled, hasActiveKey);

  @override
  String toString() =>
      'EncryptionSettings(isEnabled: $isEnabled, hasActiveKey: $hasActiveKey)';
}
