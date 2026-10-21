import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/ai/providers/ai_provider_config.dart';
import 'package:piggycount/ai/providers/ai_provider_manager.dart';
import 'package:piggycount/services/export/config_export_service.dart';

const _yaml = '''
ai:
  ai_glm_api_key: "sk-test-import"
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AIProviderManager.testSecureStore = {};
  });

  tearDown(() {
    AIProviderManager.testSecureStore = null;
  });

  test('导入 AI 配置时 apiKey 进安全存储，不落明文 prefs', () async {
    await ConfigExportService.importFromYaml(_yaml);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ai_glm_api_key'), isNull);

    final providers = await AIProviderManager.getProviders();
    final zhipu = providers.firstWhere((p) => p.id == 'zhipu_glm');
    expect(zhipu.apiKey, 'sk-test-import');
    expect(AIProviderManager.testSecureStore!['ai_providers_v2'],
        contains('sk-test-import'));
  });

  test('已有智谱 Key 时导入值覆盖安全存储中的旧值', () async {
    await AIProviderManager.updateProvider(
      AIServiceProviderConfig.zhipuDefault.copyWith(apiKey: 'sk-test-old'),
    );

    await ConfigExportService.importFromYaml(_yaml);

    final providers = await AIProviderManager.getProviders();
    final zhipu = providers.firstWhere((p) => p.id == 'zhipu_glm');
    expect(zhipu.apiKey, 'sk-test-import');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ai_glm_api_key'), isNull);
  });
}
