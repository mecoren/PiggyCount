import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';

class SplashPage extends ConsumerWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 在主色背景上展示，文字与图标均使用 onPrimary（白色）
    final onPrimary = PiggyTokens.textOnPrimary(context);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: PiggyTokens.primary(context),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // Logo区域
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: PiggyTokens.cardBackgroundLightStatic,
                  borderRadius: BorderRadius.circular(PiggyDimens.radius3xl),
                  boxShadow: [
                    BoxShadow(
                      // 阴影色保留黑色（不应随主题切换）
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Image.asset(
                    'assets/logo2.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // 应用名称
              Text(
                AppLocalizations.of(context).splashAppName,
                style: textTheme.headlineMedium?.copyWith(
                  color: onPrimary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),

              const SizedBox(height: 16),

              // Slogan
              Text(
                AppLocalizations.of(context).splashSlogan,
                style: textTheme.titleMedium?.copyWith(
                  color: onPrimary.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w500,
                ),
              ),

              const Spacer(flex: 3),

              // 数据安全说明
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  // 装饰性半透明白色，保留为字面量（不属于语义色 Token 范畴）
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.security_outlined,
                          color: onPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.of(context).splashSecurityTitle,
                          style: textTheme.titleSmall?.copyWith(
                            color: onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${AppLocalizations.of(context).splashSecurityFeature1}\n'
                      '${AppLocalizations.of(context).splashSecurityFeature2}\n'
                      '${AppLocalizations.of(context).splashSecurityFeature3}',
                      style: textTheme.bodyMedium?.copyWith(
                        color: onPrimary.withValues(alpha: 0.9),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // 加载指示器
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(onPrimary),
                  strokeWidth: 2,
                ),
              ),

              const SizedBox(height: 16),

              Text(
                AppLocalizations.of(context).splashInitializing,
                style: textTheme.bodyMedium?.copyWith(
                  color: onPrimary.withValues(alpha: 0.8),
                ),
              ),

              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }
}
