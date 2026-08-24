import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/providers/theme_providers.dart';

void main() {
  test('defaults to the blue primary color #497FF8 (2026-08 改版)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(primaryColorProvider), const Color(0xFF497FF8));
  });
}
