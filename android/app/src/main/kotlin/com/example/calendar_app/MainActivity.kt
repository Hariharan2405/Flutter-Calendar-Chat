package com.example.calendar_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.calendar_app/system"
    private var pipEnabled = false
    private var ringtone: Ringtone? = null
    private var systemChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        systemChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        systemChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setPipEnabled" -> {
                    pipEnabled = call.arguments as Boolean
                    result.success(null)
                }
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(9, 16))
                            .build()
                        enterPictureInPictureMode(params)
                    }
                    result.success(null)
                }
                "startRingtone" -> {
                    try {
                        val uri = RingtoneManager.getActualDefaultRingtoneUri(
                            this, RingtoneManager.TYPE_RINGTONE
                        )
                        ringtone = RingtoneManager.getRingtone(this, uri)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            ringtone?.isLooping = true
                        }
                        ringtone?.play()
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "stopRingtone" -> {
                    ringtone?.stop()
                    ringtone = null
                    result.success(null)
                }
                "startCallService" -> {
                    val name = call.arguments as? String ?: "Contact"
                    startService(CallForegroundService.startIntent(this, name))
                    result.success(null)
                }
                "stopCallService" -> {
                    startService(CallForegroundService.stopIntent(this))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Forward foreground-service notification tap to Flutter
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == "ACTION_RETURN_TO_CALL") {
            systemChannel?.invokeMethod("returnToCall", null)
        }
    }

    // Notify Flutter when PiP mode changes so it can adjust the UI
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        systemChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }

    // Auto-enter PiP when the user presses home during a video call
    override fun onUserLeaveHint() {
        if (pipEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(9, 16))
                .build()
            enterPictureInPictureMode(params)
        }
    }
}
