import 'dart:io';

void main() {
  final source = File('lib/pages/main/home_page.dart').readAsStringSync();

  _expect(
    RegExp(
      r'return PiggyHeader\(\s*'
      r'child: Column\([\s\S]*?'
      r'SizedBox\(\s*height: 56,\s*child: Row\([\s\S]*?'
      r'const SizedBox\(height: 12\),\s*'
      r'// 第二行 - 月份显示和统计\s*'
      r'Padding\(\s*padding: const EdgeInsets\.only\(\s*'
      r'left: PiggyDimens\.p12,\s*'
      r'right: PiggyDimens\.p12,\s*'
      r'bottom: 14,',
    ).hasMatch(source),
    'approved toolbar and monthly summary spacing',
  );

  stdout.writeln('Home header spacing contract passed.');
}

void _expect(bool condition, String description) {
  if (!condition) {
    throw StateError('Expected $description.');
  }
}
