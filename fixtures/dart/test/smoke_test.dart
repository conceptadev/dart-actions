import 'package:test/test.dart';

void main() {
  test('standalone Dart fixture runs', () {
    expect([1, 2, 3].fold<int>(0, (sum, value) => sum + value), 6);
  });
}
