package com.deepakpal.health_sync_kit_example

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Health Connect opens this activity to show the app's privacy policy:
 * ACTION_SHOW_PERMISSIONS_RATIONALE (Android 13 and below) or, through the
 * ViewPermissionUsageActivity alias, VIEW_PERMISSION_USAGE (Android 14+).
 * Flutter asks for the launch reason once at startup; a later intent (the
 * activity is singleTop) is pushed to Flutter with "showPrivacyPolicy".
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchedForPrivacyPolicy" -> result.success(isPrivacyIntent(intent))
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isPrivacyIntent(intent)) channel?.invokeMethod("showPrivacyPolicy", null)
    }

    private fun isPrivacyIntent(i: Intent?): Boolean = i?.action in PRIVACY_ACTIONS

    private companion object {
        const val CHANNEL = "health_sync_kit_example/launch"
        val PRIVACY_ACTIONS = setOf(
            "androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE",
            "android.intent.action.VIEW_PERMISSION_USAGE",
        )
    }
}
