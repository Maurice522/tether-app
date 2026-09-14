import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_share/main.dart';

void main() {
  testWidgets('shows a loading indicator while services start up', (WidgetTester tester) async {
    await tester.pumpWidget(const LanShareApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
