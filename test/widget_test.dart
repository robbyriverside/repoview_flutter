// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:repoview_flutter/main.dart';

void main() {
  testWidgets('renders graph canvas with nodes', (WidgetTester tester) async {
    await tester.pumpWidget(const GraphApp());

    expect(find.text('Graph Connectivity Playground'), findsOneWidget);
    expect(find.text('API Gateway'), findsOneWidget);
    expect(find.text('Auth Service'), findsOneWidget);
    expect(find.text('Orders'), findsOneWidget);
  });
}
