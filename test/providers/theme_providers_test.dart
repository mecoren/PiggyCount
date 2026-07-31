import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/providers/theme_providers.dart';

void main() {
  test('defaults to the original Piggy Pink color', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(primaryColorProvider), const Color(0xFFFF5C8D));
  });
}
