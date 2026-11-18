// C2: the privacy policy screen Health Connect opens through MainActivity.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_sync_kit_example/main.dart';
import 'package:health_sync_kit_example/privacy_policy_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockLaunch(Object? Function(MethodCall) reply) {
    messenger.setMockMethodCallHandler(launchChannel, (c) async => reply(c));
    addTearDown(() => messenger.setMockMethodCallHandler(launchChannel, null));
  }

  group('launchedForPrivacyPolicy()', () {
    test('true when MainActivity reports a rationale intent', () async {
      final calls = <String>[];
      mockLaunch((c) {
        calls.add(c.method);
        return true;
      });
      expect(await launchedForPrivacyPolicy(), isTrue);
      expect(calls, ['launchedForPrivacyPolicy']);
    });

    test('false for a normal launch', () async {
      mockLaunch((_) => false);
      expect(await launchedForPrivacyPolicy(), isFalse);
    });

    test('false without a native side (iOS, tests)', () async {
      expect(await launchedForPrivacyPolicy(), isFalse);
    });

    test('false when the native side errors', () async {
      mockLaunch((_) => throw PlatformException(code: 'x'));
      expect(await launchedForPrivacyPolicy(), isFalse);
    });
  });

  testWidgets('starts on the policy when launched for it', (tester) async {
    await tester.pumpWidget(const HealthDemoApp(showPrivacyPolicy: true));
    expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
    expect(find.text('What we read'), findsOneWidget);
    expect(find.text('Health'), findsNothing, reason: 'no dashboard behind it');
  });

  testWidgets('showPrivacyPolicy from MainActivity pushes the policy',
      (tester) async {
    await tester.pumpWidget(const HealthDemoApp());
    expect(find.byType(PrivacyPolicyScreen), findsNothing);

    await messenger.handlePlatformMessage(
      launchChannel.name,
      launchChannel.codec
          .encodeMethodCall(const MethodCall('showPrivacyPolicy')),
      (_) {},
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PrivacyPolicyScreen), findsOneWidget);

    // Back returns to the dashboard.
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PrivacyPolicyScreen), findsNothing);
    expect(find.byType(DashboardPage), findsOneWidget);
  });

  testWidgets('the app bar button opens the policy', (tester) async {
    await tester.pumpWidget(const HealthDemoApp());
    await tester.tap(find.byTooltip('Privacy policy'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
  });
}
