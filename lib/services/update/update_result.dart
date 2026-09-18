/// 更新结果相关的类和枚举
class UpdateResult {
  final bool hasUpdate;
  final bool success;
  final String? message;
  final String? filePath;
  final String? version;
  final String? downloadUrl;
  final String? releaseNotes;
  final UpdateResultType? type;

  UpdateResult({
    this.hasUpdate = false,
    this.success = false,
    this.message,
    this.filePath,
    this.version,
    this.downloadUrl,
    this.releaseNotes,
    this.type,
  });

  /// 私有构造：仅供各 factory 使用，均表示「非版本检查结果」，
  /// 因此 hasUpdate 恒为 false；version/downloadUrl/releaseNotes 保持 null
  /// （由公共构造 [UpdateResult.new] 承载版本检查场景）。
  UpdateResult._({
    required this.success,
    this.message,
    this.filePath,
    required this.type,
  })  : hasUpdate = false,
        version = null,
        downloadUrl = null,
        releaseNotes = null;

  factory UpdateResult.downloadSuccess(String filePath) => UpdateResult._(
        success: true,
        filePath: filePath,
        type: UpdateResultType.downloadSuccess,
      );

  factory UpdateResult.alreadyLatest(String version) => UpdateResult._(
        success: true,
        message: '__UPDATE_ALREADY_LATEST__:$version',
        type: UpdateResultType.alreadyLatest,
      );

  factory UpdateResult.userCancelled() => UpdateResult._(
        success: false,
        message: '__UPDATE_USER_CANCELLED__',
        type: UpdateResultType.userCancelled,
      );

  factory UpdateResult.permissionDenied() => UpdateResult._(
        success: false,
        message: '__UPDATE_PERMISSION_DENIED__',
        type: UpdateResultType.permissionDenied,
      );

  factory UpdateResult.downloadFailed(String error) => UpdateResult._(
        success: false,
        message: '__UPDATE_DOWNLOAD_FAILED__:$error',
        type: UpdateResultType.downloadFailed,
      );

  factory UpdateResult.installFailed(String error) => UpdateResult._(
        success: false,
        message: '__UPDATE_INSTALL_FAILED__:$error',
        type: UpdateResultType.installFailed,
      );

  factory UpdateResult.checkFailed(String error) => UpdateResult._(
        success: false,
        message: '__UPDATE_CHECK_FAILED__:$error',
        type: UpdateResultType.checkFailed,
      );
}

enum UpdateResultType {
  downloadSuccess,
  alreadyLatest,
  userCancelled,
  permissionDenied,
  downloadFailed,
  installFailed,
  checkFailed,
}

/// 应用信息类
class AppInfo {
  final String version;
  final String buildNumber;
  final String? commit;
  final String? buildTime;

  const AppInfo(this.version, this.buildNumber, {this.commit, this.buildTime});
}