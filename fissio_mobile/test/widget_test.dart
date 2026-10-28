import 'package:flutter_test/flutter_test.dart';
import 'package:fissio_mobile/main.dart';

void main() {
  testWidgets('App açılır', (tester) async {
    await tester.pumpWidget(const FissioApp());
    expect(find.text('Fissio'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });
}
