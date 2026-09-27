import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tether/main.dart';
import 'package:tether/services/desktop_window_service.dart';

void main() {
  testWidgets('shows a loading indicator while services start up', (WidgetTester tester) async {
    await tester.pumpWidget(TetherApp(desktopWindow: DesktopWindowService()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
