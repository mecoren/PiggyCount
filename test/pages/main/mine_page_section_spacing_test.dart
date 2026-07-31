import 'dart:io';

void main() {
  final source = File('lib/pages/main/mine_page.dart').readAsStringSync();

  _expect(
    RegExp(
      r'const ProfileCard\(\),[\s\S]*?'
      r'child: ListView\(\s*'
      r'padding: EdgeInsets\.fromLTRB\(\s*'
      r'16,\s*PiggyDimens\.p12,\s*16,',
    ).hasMatch(source),
    'the first MinePage section uses the standard 12dp top gap',
  );
}

void _expect(bool condition, String description) {
  if (!condition) {
    throw StateError('Expected $description.');
  }
}
