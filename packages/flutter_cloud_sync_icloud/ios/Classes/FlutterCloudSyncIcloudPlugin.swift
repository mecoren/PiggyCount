import Flutter
import UIKit

public class FlutterCloudSyncIcloudPlugin: NSObject, FlutterPlugin {
    private let icloudManager = ICloudManager()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.piggycount.app/icloud",
            binaryMessenger: registrar.messenger()
        )
        let instance = FlutterCloudSyncIcloudPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isICloudAvailable":
            // 派发到后台队列，避免首次访问 iCloud 容器阻塞主线程（Flutter UI 线程）
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let available = self?.icloudManager.isICloudAvailable() ?? false
                DispatchQueue.main.async { result(available) }
            }

        case "getICloudDiagnostics":
            handleGetICloudDiagnostics(result: result)

        case "initializeContainer":
            handleInitializeContainer(result: result)

        case "uploadFile":
            handleUploadFile(call: call, result: result)

        case "downloadFile":
            handleDownloadFile(call: call, result: result)

        case "deleteFile":
            handleDeleteFile(call: call, result: result)

        case "listFiles":
            handleListFiles(call: call, result: result)

        case "fileExists":
            handleFileExists(call: call, result: result)

        case "getFileMetadata":
            handleGetFileMetadata(call: call, result: result)

        case "getICloudAccountInfo":
            handleGetICloudAccountInfo(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Handler Methods

    private func handleInitializeContainer(result: @escaping FlutterResult) {
        icloudManager.initializeContainer { error in
            if let error = error {
                result(FlutterError(
                    code: "INIT_ERROR",
                    message: "Failed to initialize iCloud container",
                    details: error.localizedDescription
                ))
            } else {
                result(nil)
            }
        }
    }

    private func handleUploadFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let data = args["data"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing path or data",
                details: nil
            ))
            return
        }

        let metadata = args["metadata"] as? [String: String]

        icloudManager.uploadFile(path: path, base64Data: data, metadata: metadata) { error in
            if let error = error {
                result(FlutterError(
                    code: "UPLOAD_ERROR",
                    message: "Failed to upload file",
                    details: error.localizedDescription
                ))
            } else {
                result(nil)
            }
        }
    }

    private func handleDownloadFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing path",
                details: nil
            ))
            return
        }

        icloudManager.downloadFile(path: path) { base64Data, error in
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                    // 返回结构化 NOT_FOUND 错误码，Dart 侧 _isNotFoundError 据此识别并返回 null
                    result(FlutterError(
                        code: "NOT_FOUND",
                        message: "File not found",
                        details: path
                    ))
                } else {
                    result(FlutterError(
                        code: "DOWNLOAD_ERROR",
                        message: "Failed to download file",
                        details: error.localizedDescription
                    ))
                }
            } else {
                result(base64Data)
            }
        }
    }

    private func handleDeleteFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing path",
                details: nil
            ))
            return
        }

        icloudManager.deleteFile(path: path) { error in
            if let error = error {
                let nsError = error as NSError
                // Ignore "file not found" errors (idempotent delete)
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                    // 返回结构化 NOT_FOUND 错误码，Dart 侧识别后按幂等删除处理
                    result(FlutterError(
                        code: "NOT_FOUND",
                        message: "File not found",
                        details: path
                    ))
                } else {
                    result(FlutterError(
                        code: "DELETE_ERROR",
                        message: "Failed to delete file",
                        details: error.localizedDescription
                    ))
                }
            } else {
                result(nil)
            }
        }
    }

    private func handleListFiles(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing path",
                details: nil
            ))
            return
        }

        icloudManager.listFiles(at: path) { files, error in
            if let error = error {
                result(FlutterError(
                    code: "LIST_ERROR",
                    message: "Failed to list files",
                    details: error.localizedDescription
                ))
            } else {
                result(files)
            }
        }
    }

    private func handleFileExists(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing path",
                details: nil
            ))
            return
        }

        // ICL-2：fileExists 现为 throws——容器未初始化/路径校验失败
        // 以 FlutterError 透传（Dart 侧转 PlatformException 上抛），
        // 不再压成 false 诱发调用方覆盖上传
        do {
            let exists = try icloudManager.fileExists(at: path)
            result(exists)
        } catch let error as NSError {
            result(FlutterError(
                code: "ICLOUD_\(error.code)",
                message: error.localizedDescription,
                details: nil
            ))
        } catch {
            result(FlutterError(
                code: "ICLOUD_UNKNOWN",
                message: "\(error)",
                details: nil
            ))
        }
    }

    private func handleGetFileMetadata(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "Missing path",
                details: nil
            ))
            return
        }

        icloudManager.getFileMetadata(at: path) { metadata, error in
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                    // 返回结构化 NOT_FOUND 错误码，Dart 侧识别后返回 null
                    result(FlutterError(
                        code: "NOT_FOUND",
                        message: "File not found",
                        details: path
                    ))
                } else {
                    result(FlutterError(
                        code: "METADATA_ERROR",
                        message: "Failed to get file metadata",
                        details: error.localizedDescription
                    ))
                }
            } else {
                result(metadata)
            }
        }
    }

    private func handleGetICloudAccountInfo(result: @escaping FlutterResult) {
        // 派发到后台：getAccountInfo 内部访问 ubiquityIdentityToken 与容器 URL，
        // 首次访问可能阻塞，避免卡住 Flutter 主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.icloudManager.getAccountInfo { accountInfo, error in
                // getAccountInfo 的 completion 已派发到主线程
                if let error = error {
                    result(FlutterError(
                        code: "ACCOUNT_ERROR",
                        message: "Failed to get iCloud account info",
                        details: error.localizedDescription
                    ))
                } else {
                    result(accountInfo)
                }
            }
        }
    }

    private func handleGetICloudDiagnostics(result: @escaping FlutterResult) {
        icloudManager.getDiagnostics { diagnostics in
            result(diagnostics)
        }
    }
}
