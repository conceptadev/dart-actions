import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Flutter fixture renders', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('Verified SDK'),
      ),
    );
    expect(find.text('Verified SDK'), findsOneWidget);
  });
}
