import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lan_share/main.dart';
import 'package:lan_share/services/desktop_window_service.dart';

void main() {
  testWidgets('shows a loading indicator while services start up', (WidgetTester tester) async {
    await tester.pumpWidget(LanShareApp(desktopWindow: DesktopWindowService()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
