import Foundation
import Flutter

/// 简单的日志工具，通过 NotificationCenter 发送日志到主 App
class ICloudLogger {
    static func log(_ message: String) {
        print("iCloud: \(message)")
        // 通过 NotificationCenter 发送日志，AppDelegate 中的 LoggerPlugin 可以接收
        NotificationCenter.default.post(
            name: NSNotification.Name("ICloudLog"),
            object: nil,
            userInfo: ["message": message]
        )
    }
}

class ICloudManager {
    private let fileManager = FileManager.default
    // 用串行队列保护 containerURL 的读写，避免 initializeContainer 写入与
    // 文件操作读取之间的数据竞争（Swift 默认不保证属性访问线程安全）。
    private let containerQueue = DispatchQueue(label: "com.piggycount.icloud.container")
    private var _containerURL: URL?
    private var containerURL: URL? {
        get { containerQueue.sync { _containerURL } }
        set { containerQueue.sync { _containerURL = newValue } }
    }

    // iCloud container identifier - must match entitlements
    private let containerIdentifier = "iCloud.com.wait.piggycount"

    // 复用 ISO8601DateFormatter，避免在 listFiles/getFileMetadata 等高频路径重复创建
    private lazy var isoFormatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    // MARK: - Initialization

    func isICloudAvailable() -> Bool {
        ICloudLogger.log("检查 iCloud 可用性...")
        ICloudLogger.log("Container ID: \(containerIdentifier)")
        ICloudLogger.log("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")

        // 检查 ubiquityIdentityToken
        let token = fileManager.ubiquityIdentityToken
        ICloudLogger.log("ubiquityIdentityToken: \(token != nil ? "存在" : "nil")")

        // 即使 token 为 nil，也尝试获取容器（某些情况下可能仍然可用）
        ICloudLogger.log("尝试获取容器 URL...")
        if let url = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) {
            ICloudLogger.log("✅ 容器可用: \(url)")
            return true
        }

        // 如果指定容器失败，尝试获取默认容器
        ICloudLogger.log("指定容器失败，尝试默认容器...")
        if let defaultUrl = fileManager.url(forUbiquityContainerIdentifier: nil) {
            ICloudLogger.log("✅ 默认容器可用: \(defaultUrl)")
            // 注意：默认容器可用但指定容器不可用，可能是容器 ID 配置问题
            return false // 仍然返回 false，因为我们需要指定的容器
        }

        ICloudLogger.log("❌ 容器不可用")
        return false
    }

    /// 异步检查 iCloud 可用性（推荐使用）
    func checkICloudAvailabilityAsync(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false, "self is nil") }
                return
            }

            var messages: [String] = []
            messages.append("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
            messages.append("Target Container: \(self.containerIdentifier)")

            // 检查 token
            let token = self.fileManager.ubiquityIdentityToken
            messages.append("ubiquityIdentityToken: \(token != nil ? "存在" : "nil")")

            // 尝试获取容器
            if let url = self.fileManager.url(forUbiquityContainerIdentifier: self.containerIdentifier) {
                messages.append("✅ 容器 URL: \(url.path)")
                DispatchQueue.main.async { completion(true, messages.joined(separator: "\n")) }
                return
            }

            messages.append("❌ 指定容器不可用")

            // 尝试默认容器
            if let defaultUrl = self.fileManager.url(forUbiquityContainerIdentifier: nil) {
                messages.append("⚠️ 默认容器可用: \(defaultUrl.path)")
                messages.append("这说明 iCloud 本身可用，但指定的容器 ID 可能不正确")
            } else {
                messages.append("❌ 默认容器也不可用")
                messages.append("可能原因:")
                messages.append("1. 设备未登录 iCloud")
                messages.append("2. iCloud Drive 未开启")
                messages.append("3. App 的 iCloud 权限被限制")
                messages.append("4. Provisioning Profile 未包含 iCloud 权限")
            }

            DispatchQueue.main.async { completion(false, messages.joined(separator: "\n")) }
        }
    }

    /// 获取详细的 iCloud 诊断信息（不使用 CloudKit，仅检查 iCloud Documents）
    func getDiagnostics(completion: @escaping ([String: Any]) -> Void) {
        // 在后台线程执行，因为首次访问 iCloud 容器可能会阻塞
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var diagnostics: [String: Any] = [:]
            diagnostics["containerIdentifier"] = self.containerIdentifier

            // 获取 Bundle ID
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            diagnostics["bundleIdentifier"] = bundleId

            // 检查是否是模拟器
            #if targetEnvironment(simulator)
            diagnostics["isSimulator"] = true
            #else
            diagnostics["isSimulator"] = false
            #endif

            // 检查 ubiquityIdentityToken（表示用户是否登录 iCloud）
            let token = self.fileManager.ubiquityIdentityToken
            diagnostics["ubiquityIdentityToken"] = token != nil ? "存在" : "nil"
            diagnostics["userSignedIn"] = token != nil

            if let token = token {
                // 打印 token 的描述信息（不是敏感数据，只是一个标识符）
                diagnostics["tokenDescription"] = String(describing: token)
            }

            // 尝试获取指定容器 URL（这个调用可能会阻塞）
            ICloudLogger.log("正在尝试获取容器 URL（后台线程）...")
            if let url = self.fileManager.url(forUbiquityContainerIdentifier: self.containerIdentifier) {
                ICloudLogger.log("✅ 后台线程获取容器成功: \(url)")
                diagnostics["containerURL"] = url.absoluteString
                diagnostics["containerAvailable"] = true
            } else {
                ICloudLogger.log("❌ 后台线程获取容器失败")
                diagnostics["containerURL"] = "nil"
                diagnostics["containerAvailable"] = false
            }

            // 尝试获取默认容器（使用 nil）
            ICloudLogger.log("正在尝试获取默认容器...")
            if let defaultUrl = self.fileManager.url(forUbiquityContainerIdentifier: nil) {
                ICloudLogger.log("✅ 默认容器可用: \(defaultUrl)")
                diagnostics["defaultContainerURL"] = defaultUrl.absoluteString
            } else {
                ICloudLogger.log("❌ 默认容器不可用")
                diagnostics["defaultContainerURL"] = "nil"
            }

            // 检查 entitlements 中的 iCloud 配置
            if let entitlements = Bundle.main.infoDictionary {
                diagnostics["hasInfoPlist"] = true
            }

            // 尝试读取 embedded.mobileprovision 中的信息
            if let provisionPath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") {
                diagnostics["hasEmbeddedProvision"] = true
            } else {
                diagnostics["hasEmbeddedProvision"] = false
            }

            // 直接返回结果
            DispatchQueue.main.async {
                completion(diagnostics)
            }
        }
    }

    func initializeContainer(completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Get iCloud container URL with specific identifier
            if let url = self.fileManager.url(forUbiquityContainerIdentifier: self.containerIdentifier) {
                self.containerURL = url.appendingPathComponent("Documents/PiggyCount")
                print("iCloud: Initialized container at \(self.containerURL!)")

                // Create base directory if needed
                self.createDirectoryIfNeeded(at: self.containerURL!) { error in
                    DispatchQueue.main.async {
                        completion(error)
                    }
                }
            } else {
                print("iCloud: Failed to get container URL for \(self.containerIdentifier)")
                DispatchQueue.main.async {
                    completion(NSError(
                        domain: "ICloudManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "iCloud container not available. Please ensure iCloud Drive is enabled in Settings."]
                    ))
                }
            }
        }
    }

    // MARK: - File Operations

    func uploadFile(
        path: String,
        base64Data: String,
        metadata: [String: String]?,
        completion: @escaping (Error?) -> Void
    ) {
        guard containerURL != nil else {
            completion(NSError(
                domain: "ICloudManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Container not initialized"]
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Decode Base64 data
                guard let data = Data(base64Encoded: base64Data) else {
                    throw NSError(
                        domain: "ICloudManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid Base64 data"]
                    )
                }

                // Build file URL（safeURL 校验路径遍历）
                let fileURL = try self.safeURL(for: path)

                // Create parent directory if needed
                let parentURL = fileURL.deletingLastPathComponent()
                try self.fileManager.createDirectory(
                    at: parentURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                // Write file using NSFileCoordinator for safe concurrent access
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinatorError: NSError?
                var writeError: Error?

                coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
                    do {
                        try data.write(to: url, options: .atomic)

                        // Store metadata if provided
                        if let metadata = metadata {
                            self.storeMetadata(metadata, for: url)
                        }
                    } catch {
                        writeError = error
                    }
                }

                DispatchQueue.main.async {
                    completion(coordinatorError ?? writeError)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(error)
                }
            }
        }
    }

    func downloadFile(path: String, completion: @escaping (String?, Error?) -> Void) {
        guard containerURL != nil else {
            completion(nil, NSError(
                domain: "ICloudManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Container not initialized"]
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fileURL: URL
            do {
                fileURL = try self.safeURL(for: path)
            } catch {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }

            // Check if file exists
            guard self.fileManager.fileExists(atPath: fileURL.path) else {
                DispatchQueue.main.async {
                    completion(nil, NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileReadNoSuchFileError,
                        userInfo: [NSLocalizedDescriptionKey: "File not found"]
                    ))
                }
                return
            }

            // 触发 iCloud 下载并等待完成，避免 startDownloadingUbiquitousItem
            // 异步返回导致后续读到空文件或残缺数据。
            self.downloadAndWaitIfNeeded(fileURL) { waitError in
                if let waitError = waitError {
                    DispatchQueue.main.async { completion(nil, waitError) }
                    return
                }
                // Read file using NSFileCoordinator
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinatorError: NSError?
                var base64Data: String?
                var readError: Error?

                coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordinatorError) { url in
                    do {
                        let data = try Data(contentsOf: url)
                        base64Data = data.base64EncodedString()
                    } catch {
                        readError = error
                    }
                }

                DispatchQueue.main.async {
                    completion(base64Data, coordinatorError ?? readError)
                }
            }
        }
    }

    func deleteFile(path: String, completion: @escaping (Error?) -> Void) {
        guard containerURL != nil else {
            completion(NSError(
                domain: "ICloudManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Container not initialized"]
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fileURL: URL
            do {
                fileURL = try self.safeURL(for: path)
            } catch {
                DispatchQueue.main.async { completion(error) }
                return
            }

            // Delete using NSFileCoordinator
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinatorError: NSError?
            var deleteError: Error?

            coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
                do {
                    try self.fileManager.removeItem(at: url)

                    // Also delete metadata file if exists
                    let metadataURL = self.metadataURL(for: url)
                    if self.fileManager.fileExists(atPath: metadataURL.path) {
                        try? self.fileManager.removeItem(at: metadataURL)
                    }
                } catch {
                    deleteError = error
                }
            }

            DispatchQueue.main.async {
                completion(coordinatorError ?? deleteError)
            }
        }
    }

    func listFiles(at path: String, completion: @escaping ([[String: Any]]?, Error?) -> Void) {
        guard containerURL != nil else {
            completion(nil, NSError(
                domain: "ICloudManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Container not initialized"]
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let directoryURL: URL
            do {
                directoryURL = try self.safeURL(for: path)
            } catch {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }

            // Return empty array if directory doesn't exist
            guard self.fileManager.fileExists(atPath: directoryURL.path) else {
                DispatchQueue.main.async {
                    completion([], nil)
                }
                return
            }

            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                let files = fileURLs
                    .filter { !$0.lastPathComponent.hasSuffix(".metadata.json") }
                    .compactMap { url -> [String: Any]? in
                        guard let attributes = try? self.fileManager.attributesOfItem(atPath: url.path) else {
                            return nil
                        }

                        var fileInfo: [String: Any] = [
                            "name": url.lastPathComponent,
                            "path": path.isEmpty ? url.lastPathComponent : "\(path)/\(url.lastPathComponent)",
                        ]

                        if let size = attributes[.size] as? Int {
                            fileInfo["size"] = size
                        }

                        if let modDate = attributes[.modificationDate] as? Date {
                            fileInfo["lastModified"] = self.isoFormatter.string(from: modDate)
                        }

                        // 加载自定义元数据（若存在），便于下游直接使用
                        if let customMetadata = self.loadMetadata(for: url) {
                            fileInfo["customMetadata"] = customMetadata
                        }

                        return fileInfo
                    }

                DispatchQueue.main.async {
                    completion(files, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    /// ICL-2（2026-09-12 P1）：错误透传签名。
    ///
    /// 旧实现 `try? safeURL(...)` 把容器未初始化（1001）与路径校验失败
    /// （1002）静默压成 false —— 调用方（exists 探测锚点/上传冲突仲裁）
    /// 会把环境故障误判为「文件不存在」进而触发覆盖上传。现改为 throws，
    /// 两类失败均以 NSError 上抛，由插件层转 FlutterError 透传给 Dart。
    /// 文件真实不存在时仍返回 false（正常语义不受影响）。
    func fileExists(at path: String) throws -> Bool {
        let fileURL = try safeURL(for: path)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    func getFileMetadata(at path: String, completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard containerURL != nil else {
            completion(nil, NSError(
                domain: "ICloudManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Container not initialized"]
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fileURL: URL
            do {
                fileURL = try self.safeURL(for: path)
            } catch {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }

            guard self.fileManager.fileExists(atPath: fileURL.path) else {
                DispatchQueue.main.async {
                    completion(nil, NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileReadNoSuchFileError,
                        userInfo: [NSLocalizedDescriptionKey: "File not found"]
                    ))
                }
                return
            }

            do {
                let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
                var metadata: [String: Any] = [
                    "name": fileURL.lastPathComponent,
                    "path": path,
                ]

                if let size = attributes[.size] as? Int {
                    metadata["size"] = size
                }

                if let modDate = attributes[.modificationDate] as? Date {
                    metadata["lastModified"] = self.isoFormatter.string(from: modDate)
                }

                // Load custom metadata if exists
                if let customMetadata = self.loadMetadata(for: fileURL) {
                    metadata["customMetadata"] = customMetadata
                }

                DispatchQueue.main.async {
                    completion(metadata, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }

    // MARK: - Account Info

    /// 获取 iCloud 账户信息（基于 iCloud Documents，不使用 CloudKit）
    func getAccountInfo(completion: @escaping ([String: Any]?, Error?) -> Void) {
        var accountInfo: [String: Any] = [:]

        // 通过 ubiquityIdentityToken 检查用户是否登录 iCloud
        if let token = fileManager.ubiquityIdentityToken {
            // 用户已登录
            accountInfo["status"] = "available"
            // 使用 token 的 hash 作为匿名 ID
            accountInfo["accountId"] = "icloud-\(token.hash)"

            // 检查容器是否可用
            if fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) != nil {
                accountInfo["containerAvailable"] = true
            } else {
                accountInfo["containerAvailable"] = false
            }
        } else {
            // 用户未登录
            accountInfo["status"] = "noAccount"
            accountInfo["containerAvailable"] = false
        }

        DispatchQueue.main.async {
            completion(accountInfo, nil)
        }
    }

    // MARK: - Helper Methods

    /// 安全拼接路径并校验是否仍在容器目录内，防止 .. 路径遍历逃逸。
    /// 所有外部传入的 path 都必须经此方法拼接，禁止直接 appendingPathComponent。
    private func safeURL(for path: String) throws -> URL {
        guard let containerURL = self.containerURL else {
            throw NSError(domain: "ICloudManager", code: 1001,
                          userInfo: [NSLocalizedDescriptionKey: "Container not initialized"])
        }
        let fileURL = containerURL.appendingPathComponent(path)
        let standardized = fileURL.standardizedFileURL
        let containerStandardized = containerURL.standardizedFileURL
        // 标准化后校验是否仍在容器目录内，拒绝逃逸路径（如 ../etc/passwd）
        guard standardized.path.hasPrefix(containerStandardized.path) else {
            throw NSError(domain: "ICloudManager", code: 1002,
                          userInfo: [NSLocalizedDescriptionKey: "Path traversal detected: \(path)"])
        }
        return standardized
    }

    private func createDirectoryIfNeeded(at url: URL, completion: @escaping (Error?) -> Void) {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                completion(nil)
            } catch {
                completion(error)
            }
        } else {
            completion(nil)
        }
    }

    private func metadataURL(for fileURL: URL) -> URL {
        return fileURL.deletingPathExtension().appendingPathExtension("metadata.json")
    }

    private func storeMetadata(_ metadata: [String: String], for fileURL: URL) {
        let metadataURL = metadataURL(for: fileURL)

        let metadataDict: [String: Any] = [
            "metadata": metadata,
            "updatedAt": isoFormatter.string(from: Date())
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: metadataDict, options: .prettyPrinted)
            try jsonData.write(to: metadataURL, options: .atomic)
        } catch {
            // 元数据是辅助数据，写入失败不阻塞主流程，但记录 warning 便于排查
            ICloudLogger.log("Warning: failed to store metadata at \(metadataURL.path): \(error.localizedDescription)")
        }
    }

    private func loadMetadata(for fileURL: URL) -> [String: Any]? {
        let metadataURL = metadataURL(for: fileURL)

        guard let jsonData = try? Data(contentsOf: metadataURL),
              let metadataDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let metadata = metadataDict["metadata"] as? [String: Any] else {
            return nil
        }

        return metadata
    }

    /// 触发 iCloud 下载并等待完成，解决 startDownloadingUbiquitousItem 异步返回
    /// 导致读到空文件或残缺数据的问题。轮询 ubiquitousItemDownloadingStatus，
    /// 最长等待 30 秒后超时返回错误。
    private func downloadAndWaitIfNeeded(_ fileURL: URL, completion: @escaping (Error?) -> Void) {
        startDownloadIfNeeded(fileURL)
        let deadline = Date().addingTimeInterval(30)
        // 递归轮询下载状态：当前状态为 .current 即完成，否则 0.5s 后重试
        func check() {
            if Date() > deadline {
                completion(NSError(domain: "ICloudManager", code: 1003,
                                   userInfo: [NSLocalizedDescriptionKey: "Download timeout"]))
                return
            }
            do {
                let vals = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if vals.ubiquitousItemDownloadingStatus == .current {
                    completion(nil)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: check)
                }
            } catch {
                completion(error)
            }
        }
        check()
    }

    private func startDownloadIfNeeded(_ fileURL: URL) {
        do {
            // Check if file needs to be downloaded from iCloud
            let resourceValues = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus,
               downloadStatus == .notDownloaded {
                try fileManager.startDownloadingUbiquitousItem(at: fileURL)
            }
        } catch {
            // 下载触发失败可能是文件已在本地，记录 warning 便于排查而非完全静默
            ICloudLogger.log("Warning: startDownloadIfNeeded failed for \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
