package com.example.calendar_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.calendar_app/system"
    private var pipEnabled = false
    private var ringtone: Ringtone? = null
    private var notifTone: Ringtone? = null
    private var systemChannel: MethodChannel? = null

    // Holds the pending result while the ringtone picker activity is open
    private var ringtonePickerResult: MethodChannel.Result? = null
    private val ringtonePickerRequestCode = 1001

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
                // Open Android's ringtone picker; returns the selected URI string (or null)
                "pickNotifSound" -> {
                    try {
                        val currentUri = (call.arguments as? String)?.let { Uri.parse(it) }
                        val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                            putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_NOTIFICATION)
                            putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                            putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, true)
                            putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "Notification Sound")
                            if (currentUri != null) {
                                putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, currentUri)
                            }
                        }
                        ringtonePickerResult = result
                        startActivityForResult(intent, ringtonePickerRequestCode)
                    } catch (e: Exception) {
                        result.error("PICK_FAILED", e.message, null)
                    }
                }
                // Play a notification sound by URI (or default if null/empty)
                "playNotifSound" -> {
                    try {
                        notifTone?.stop()
                        val uriStr = call.arguments as? String
                        val uri = if (!uriStr.isNullOrEmpty())
                            Uri.parse(uriStr)
                        else
                            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                        notifTone = RingtoneManager.getRingtone(this, uri)
                        notifTone?.play()
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "stopNotifSound" -> {
                    notifTone?.stop()
                    notifTone = null
                    result.success(null)
                }
                "startCallService" -> {
                    val name = call.arguments as? String ?: "Contact"
                    val intent = CallForegroundService.startIntent(this, name)
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "startCameraShareService" -> {
                    val intent = CallForegroundService.startSilentIntent(this)
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "stopCallService" -> {
                    // stopService() works from any app state; startService() with a stop
                    // action fails from background (Android 8+ background service restriction).
                    try {
                        stopService(Intent(this, CallForegroundService::class.java))
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "closePip" -> {
                    // Dismiss the system PiP window by moving the task to background.
                    // This is the correct way to close PiP on Android without
                    // bringing the activity back to full-screen first.
                    moveTaskToBack(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // Receive the ringtone picker result and forward it to Flutter
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ringtonePickerRequestCode) {
            val pending = ringtonePickerResult ?: return
            ringtonePickerResult = null
            val uri: Uri? = data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            // null means "Silent" was selected; empty string signals that to Dart
            pending.success(uri?.toString())
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
