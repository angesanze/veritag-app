import 'package:arttrust_mobile/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('home is the scanner; artists get an organic entry', (tester) async {
    SharedPreferences.setMockInitialValues({}); // no stored identity
    await tester.pumpWidget(const ArtTrustApp());
    // let the async identity load resolve
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 360));

    expect(find.text('ArtTrust'), findsOneWidget);
    expect(find.text('Hold near an artwork'), findsOneWidget);      // the universal gesture
    expect(find.text('Are you an artist?'), findsOneWidget);        // the studio invitation
    expect(find.text('Artist'), findsNothing);                      // no more hard duality
    expect(find.text('Visitor'), findsNothing);

    // Unmount so the health-poll timer is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
