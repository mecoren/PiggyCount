import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/ai/providers/ai_provider_config.dart';
import 'package:piggycount/ai/providers/ai_provider_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AIProviderManager.testSecureStore = {};
  });

  tearDown(() {
    AIProviderManager.testSecureStore = null;
  });

  test('保存服务商后 apiKey 进安全存储，prefs 无残留', () async {
    final providers = [
      AIServiceProviderConfig.zhipuDefault.copyWith(apiKey: 'sk-test-123'),
    ];
    // 经公开链路写入：添加自定义服务商会触发 _saveProviders
    await AIProviderManager.addProvider(
      name: '测试服务商',
      apiKey: 'sk-custom-456',
      baseUrl: 'https://example.com/v1',
    );
    // 再覆盖为确定性数据
    await AIProviderManager.updateProvider(providers.first);

    final stored = AIProviderManager.testSecureStore!['ai_providers_v2'];
    expect(stored, isNotNull);
    expect(stored, contains('sk-test-123'));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ai_providers_v2'), isNull);

    final loaded = await AIProviderManager.getProviders();
    expect(loaded.any((p) => p.apiKey == 'sk-test-123'), isTrue);
  });

  test('旧明文服务商配置读时迁移到安全存储', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'ai_providers_v2',
      '[{"id":"zhipu_glm","name":"智谱GLM","isBuiltIn":true,'
          '"apiKey":"sk-legacy","baseUrl":"https://open.bigmodel.cn/api/paas/v4",'
          '"textModel":"glm-4-flash","visionModel":"glm-4v-flash",'
          '"audioModel":"glm-4-voice","createdAt":"2024-01-01T00:00:00.000"}]',
    );

    final loaded = await AIProviderManager.getProviders();
    expect(loaded.any((p) => p.apiKey == 'sk-legacy'), isTrue);
    expect(AIProviderManager.testSecureStore!['ai_providers_v2'], isNotNull);
    expect(prefs.getString('ai_providers_v2'), isNull);
  });

  test('旧单 key 配置迁移后清理明文残留', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_glm_api_key', 'sk-old-single');
    await prefs.setString('ai_glm_model', 'glm-4-flash');

    await AIProviderManager.migrateFromOldConfig();

    final loaded = await AIProviderManager.getProviders();
    expect(loaded.any((p) => p.apiKey == 'sk-old-single'), isTrue);
    expect(prefs.getString('ai_glm_api_key'), isNull);
    expect(prefs.getString('ai_glm_model'), isNull);
  });
}
