import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexus_hub_app/main.dart';

void main() {
  testWidgets('NexusHubApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: NexusHubApp()),
    );
    // Allow async providers (device load) to settle
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(NexusHubApp), findsOneWidget);
  });
}
