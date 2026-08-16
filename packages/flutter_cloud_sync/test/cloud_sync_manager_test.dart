import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

// Manual mocks (simpler than using mockito code generation)
class MockCloudProvider implements CloudProvider {
  final MockCloudAuthService _auth = MockCloudAuthService();
  final MockCloudStorageService _storage = MockCloudStorageService();

  @override
  CloudAuthService get auth => _auth;

  @override
  CloudStorageService get storage => _storage;

  @override
  String get providerId => 'mock';

  @override
  String get providerName => 'Mock Provider';

  @override
  Future<void> initialize(Map<String, dynamic> config) async {}

  @override
  bool validateConfig(Map<String, dynamic> config) => true;

  @override
  Future<void> dispose() async {}
}

class MockCloudAuthService implements CloudAuthService {
  CloudUser? _currentUser;

  void setCurrentUser(CloudUser? user) {
    _currentUser = user;
  }

  @override
  Future<CloudUser?> get currentUser async => _currentUser;

  @override
  Stream<CloudUser?> get authStateChanges => Stream.value(_currentUser);

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}

  @override
  Future<void> resendEmailVerification({required String email}) async {}
}

class MockCloudStorageService implements CloudStorageService {
  final Map<String, _StoredFile> _files = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    _files[path] = _StoredFile(data, metadata);
  }

  @override
  Future<String?> download({required String path}) async {
    return _files[path]?.data;
  }

  @override
  Future<void> delete({required String path}) async {
    _files.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return _files.keys
        .where((key) => key.startsWith(path))
        .map((key) => CloudFile(
              name: key.split('/').last,
              path: key,
              metadata: _files[key]?.metadata,
            ))
        .toList();
  }

  @override
  Future<bool> exists({required String path}) async {
    return _files.containsKey(path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    final file = _files[path];
    if (file == null) return null;
    return CloudFile(
      name: path.split('/').last,
      path: path,
      metadata: file.metadata,
    );
  }

  /// 模拟 S3 兼容网关原样返回 'b64:' 包装 metadata（存储层解码未生效）：
  /// 把已存储的每个 metadata 值 base64 包装，复刻线上
  /// '386c...' vs 'b64:Mzg2...' 永不相等的故障形态
  void wrapMetadataInBase64(String path) {
    final file = _files[path];
    if (file?.metadata == null) return;
    final wrapped = <String, String>{
      for (final e in file!.metadata!.entries)
        e.key: 'b64:${base64.encode(utf8.encode(e.value))}',
    };
    _files[path] = _StoredFile(file.data, wrapped);
  }
}

class _StoredFile {
  final String data;
  final Map<String, String>? metadata;

  _StoredFile(this.data, this.metadata);
}

class MockDataSerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async {
    return jsonEncode({'id': data});
  }

  @override
  Future<int> deserialize(String data) async {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return json['id'] as int;
  }

  @override
  String fingerprint(String data) {
    return sha256.convert(utf8.encode(data)).toString();
  }
}

void main() {
  late CloudSyncManager<int> syncManager;
  late MockCloudProvider mockProvider;
  late MockCloudAuthService mockAuth;
  late MockCloudStorageService mockStorage;
  late MockDataSerializer mockSerializer;

  setUp(() {
    mockProvider = MockCloudProvider();
    mockAuth = mockProvider.auth as MockCloudAuthService;
    mockStorage = mockProvider.storage as MockCloudStorageService;
    mockSerializer = MockDataSerializer();

    syncManager = CloudSyncManager<int>(
      provider: mockProvider,
      serializer: mockSerializer,
      logger: CloudSyncLogger(onLog: (level, msg) {
        // ignore: avoid_print
        print('[$level] $msg');
      }),
    );
  });

  group('CloudSyncManager - upload', () {
    test('should throw CloudNotAuthenticatedException when not authenticated',
        () async {
      // Arrange
      mockAuth.setCurrentUser(null);

      // Act & Assert
      expect(
        () => syncManager.upload(data: 123, path: 'test.json'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });

    test('should upload data successfully when authenticated', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123', email: 'test@example.com');
      const testData = 123;
      const testPath = 'ledgers/123.json';

      mockAuth.setCurrentUser(testUser);

      // Act
      await syncManager.upload(data: testData, path: testPath);

      // Assert
      final exists = await mockStorage.exists(path: testPath);
      expect(exists, isTrue);

      final metadata = await mockStorage.getMetadata(path: testPath);
      expect(metadata, isNotNull);
      expect(metadata!.metadata!['userId'], equals(testUser.id));
      expect(metadata.metadata!['fingerprint'], isNotNull);
    });

    test('should include custom metadata in upload', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      mockAuth.setCurrentUser(testUser);

      // Act
      await syncManager.upload(
        data: 123,
        path: 'test.json',
        metadata: {'version': '1.0', 'app': 'PiggyCount'},
      );

      // Assert
      final metadata = await mockStorage.getMetadata(path: 'test.json');
      expect(metadata!.metadata!['version'], equals('1.0'));
      expect(metadata.metadata!['app'], equals('PiggyCount'));
      expect(metadata.metadata!['fingerprint'], isNotNull);
    });
  });

  group('CloudSyncManager - download', () {
    test('should throw CloudNotAuthenticatedException when not authenticated',
        () async {
      // Arrange
      mockAuth.setCurrentUser(null);

      // Act & Assert
      expect(
        () => syncManager.download(path: 'test.json'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });

    test('should return null when file does not exist', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      mockAuth.setCurrentUser(testUser);

      // Act
      final result = await syncManager.download(path: 'nonexistent.json');

      // Assert
      expect(result, isNull);
    });

    test('should download and deserialize data successfully', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'ledgers/123.json';

      mockAuth.setCurrentUser(testUser);

      // Upload first
      await syncManager.upload(data: testData, path: testPath);

      // Act
      final result = await syncManager.download(path: testPath);

      // Assert
      expect(result, equals(testData));
    });
  });

  group('CloudSyncManager - getStatus', () {
    test('should return notAuthenticated when user not authenticated',
        () async {
      // Arrange
      mockAuth.setCurrentUser(null);

      // Act
      final status = await syncManager.getStatus(path: 'test.json');

      // Assert
      expect(status.state, equals(SyncState.notAuthenticated));
      expect(status.message, equals('User not authenticated'));
    });

    test('should return localOnly when cloud file does not exist', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const localData = 123;

      mockAuth.setCurrentUser(testUser);

      // Act
      final status =
          await syncManager.getStatus(data: localData, path: 'test.json');

      // Assert
      expect(status.state, equals(SyncState.localOnly));
      expect(status.localFingerprint, isNotNull);
      expect(status.cloudFingerprint, isNull);
    });

    test('should return synced when fingerprints match', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);

      // Upload first
      await syncManager.upload(data: testData, path: testPath);

      // Act
      final status =
          await syncManager.getStatus(data: testData, path: testPath);

      // Assert
      expect(status.state, equals(SyncState.synced));
      expect(status.localFingerprint, equals(status.cloudFingerprint));
    });

    test('should return outOfSync when fingerprints differ', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const uploadedData = 123;
      const localData = 456;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);

      // Upload with one data
      await syncManager.upload(data: uploadedData, path: testPath);

      // Check status with different local data
      final status =
          await syncManager.getStatus(data: localData, path: testPath);

      // Assert
      expect(status.state, equals(SyncState.outOfSync));
      expect(status.localFingerprint, isNot(equals(status.cloudFingerprint)));
    });

    test('should use cache when not expired', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);
      await syncManager.upload(data: testData, path: testPath);

      // Act - first call
      await syncManager.getStatus(data: testData, path: testPath);

      // Manually modify cloud data to verify cache is used
      await mockStorage.upload(
        path: testPath,
        data: '{"id": 999}',
        metadata: {'fingerprint': 'different'},
      );

      // Second call should use cache and not see the new fingerprint
      final status =
          await syncManager.getStatus(data: testData, path: testPath);

      // Assert - should still show synced because of cache
      expect(status.state, equals(SyncState.synced));
    });

    test('should refresh cache when forceRefresh is true', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);
      await syncManager.upload(data: testData, path: testPath);

      // First call to populate cache
      await syncManager.getStatus(data: testData, path: testPath);

      // Modify cloud data
      await mockStorage.upload(
        path: testPath,
        data: '{"id": 999}',
        metadata: {'fingerprint': 'different'},
      );

      // Act - force refresh should see the change
      final status = await syncManager.getStatus(
        data: testData,
        path: testPath,
        forceRefresh: true,
      );

      // Assert - should detect out of sync
      expect(status.state, equals(SyncState.outOfSync));
    });

    // sync_convergence_fix 回归：S3 存储层上传时对 metadata 值统一加
    // 'b64:' base64 包装（RFC 7230 头值安全），部分 S3 兼容网关会原样
    // 返回包装值导致指纹比较变成 '386c...' vs 'b64:Mzg2...' 永不相等
    // → 永远 outOfSync → 每次启动都弹「云端有更新」死循环。
    // getStatus 消费点必须做防御性归一化。
    test('metadata 带 b64 包装时指纹仍应判定 synced（网关不解码场景）',
        () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);
      await syncManager.upload(data: testData, path: testPath);

      // 模拟网关原样返回 b64 包装的 metadata
      mockStorage.wrapMetadataInBase64(testPath);

      // Act
      final status = await syncManager.getStatus(
        data: testData,
        path: testPath,
        forceRefresh: true,
      );

      // Assert：归一化后指纹一致 → synced，而非 outOfSync
      expect(status.state, equals(SyncState.synced));
      expect(status.cloudFingerprint, equals(status.localFingerprint));
    });

    test('metadata b64 包装值缺 padding（网关剥离 = ）时仍可归一化', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);
      await syncManager.upload(data: testData, path: testPath);

      // 包装后剥离 padding，模拟部分网关对头值的规范化处理
      mockStorage.wrapMetadataInBase64(testPath);
      final file = mockStorage._files[testPath]!;
      final stripped = <String, String>{
        for (final e in file.metadata!.entries)
          e.key: e.value.replaceAll('=', ''),
      };
      mockStorage._files[testPath] = _StoredFile(file.data, stripped);

      // Act
      final status = await syncManager.getStatus(
        data: testData,
        path: testPath,
        forceRefresh: true,
      );

      // Assert：容错补 padding 解码，指纹一致 → synced
      expect(status.state, equals(SyncState.synced));
      expect(status.cloudFingerprint, equals(status.localFingerprint));
    });
  });

  group('CloudSyncManager - deleteRemote', () {
    test('should throw CloudNotAuthenticatedException when not authenticated',
        () async {
      // Arrange
      mockAuth.setCurrentUser(null);

      // Act & Assert
      expect(
        () => syncManager.deleteRemote(path: 'test.json'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });

    test('should delete file successfully', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'ledgers/123.json';

      mockAuth.setCurrentUser(testUser);

      // Upload first
      await syncManager.upload(data: testData, path: testPath);
      expect(await mockStorage.exists(path: testPath), isTrue);

      // Act
      await syncManager.deleteRemote(path: testPath);

      // Assert
      expect(await mockStorage.exists(path: testPath), isFalse);
    });
  });

  group('CloudSyncManager - cache management', () {
    test('should clear all cached status', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);
      await syncManager.upload(data: testData, path: testPath);

      // Build cache
      await syncManager.getStatus(data: testData, path: testPath);

      // Modify cloud data
      await mockStorage.upload(
        path: testPath,
        data: '{"id": 999}',
        metadata: {'fingerprint': 'different'},
      );

      // Should use cache (synced)
      var status = await syncManager.getStatus(data: testData, path: testPath);
      expect(status.state, equals(SyncState.synced));

      // Clear cache
      syncManager.clearCache();

      // Should detect out of sync after cache clear
      status = await syncManager.getStatus(data: testData, path: testPath);
      expect(status.state, equals(SyncState.outOfSync));
    });

    test('should invalidate cache after upload', () async {
      // Arrange
      const testUser = CloudUser(id: 'user123');
      const testData = 123;
      const testPath = 'test.json';

      mockAuth.setCurrentUser(testUser);

      // Upload and build cache
      await syncManager.upload(data: testData, path: testPath);
      await syncManager.getStatus(data: testData, path: testPath);

      // Upload again (invalidates cache)
      await syncManager.upload(data: testData, path: testPath);

      // Cache should be invalidated, status check should work correctly
      final status =
          await syncManager.getStatus(data: testData, path: testPath);
      expect(status.state, equals(SyncState.synced));
    });
  });
}
