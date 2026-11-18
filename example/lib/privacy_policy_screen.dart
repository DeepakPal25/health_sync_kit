import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Channel MainActivity uses to tell Flutter that Health Connect opened the
/// app to show its privacy policy (ACTION_SHOW_PERMISSIONS_RATIONALE on
/// Android 13 and below, VIEW_PERMISSION_USAGE on Android 14+).
const launchChannel = MethodChannel('health_sync_kit_example/launch');

/// Whether this launch came from Health Connect's "privacy policy" link.
/// Returns false where there is no native side (iOS, tests).
Future<bool> launchedForPrivacyPolicy() async {
  try {
    return await launchChannel.invokeMethod<bool>('launchedForPrivacyPolicy') ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Minimal privacy policy for the example app. A real app should link to its
/// published policy (see PRIVACY.md in the plugin repository for a template).
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String s) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Text(s, style: theme.textTheme.titleMedium),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy policy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'health_sync_kit demo is a sample app. It reads health data only '
              'to show it on this screen.'),
          heading('What we read'),
          const Text('Steps, active and total calories, basal metabolic rate, '
              'distance, exercise, heart rate, resting heart rate, heart rate '
              'variability and sleep. Nothing is written.'),
          heading('How it is used'),
          const Text('Data is processed on this device to show activity, '
              'sleep and readiness summaries. It is not stored by the app, '
              'not sent to any server, not shared with third parties, and not '
              'used for advertising.'),
          heading('Your choices'),
          const Text('You can revoke access at any time in Health Connect '
              '(Android) or the Health app (iOS). The app keeps working with '
              'demo data.'),
        ],
      ),
    );
  }
}
