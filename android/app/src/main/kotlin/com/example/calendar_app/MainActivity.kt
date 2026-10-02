package com.example.calendar_app

import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.Intent
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
                // Copy a temp audio file into the public Music folder so it
                // shows up in the file manager and music apps. Returns the saved
                // public path/URI string, or an error on failure.
                "saveAudioToMusic" -> {
                    val args = call.arguments as? Map<*, *>
                    val srcPath = args?.get("path") as? String
                    val name = args?.get("name") as? String ?: "audio"
                    val mime = args?.get("mime") as? String ?: "audio/mpeg"
                    if (srcPath == null) {
                        result.error("NO_PATH", "Missing source path", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val saved = try {
                            saveAudioToMusic(srcPath, name, mime)
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread {
                            if (saved != null) result.success(saved)
                            else result.error("SAVE_FAILED", "Could not save file", null)
                        }
                    }.start()
                }
                // Save an image/video/audio file into the appropriate public
                // MediaStore collection (Pictures/Movies/Music, /Calendar) and
                // return the content URI so its later existence can be checked.
                "saveMediaToStore" -> {
                    val args = call.arguments as? Map<*, *>
                    val srcPath = args?.get("path") as? String
                    val name = args?.get("name") as? String ?: "file"
                    val mime = args?.get("mime") as? String ?: "application/octet-stream"
                    val kind = args?.get("kind") as? String ?: "image"
                    if (srcPath == null) {
                        result.error("NO_PATH", "Missing source path", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val savedUri = try {
                            saveMediaToStore(srcPath, name, mime, kind)
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread {
                            if (savedUri != null) result.success(savedUri)
                            else result.error("SAVE_FAILED", "Could not save file", null)
                        }
                    }.start()
                }
                // True if the MediaStore row for [uri] still exists (i.e. the user
                // hasn't deleted the saved file from the device).
                "mediaUriExists" -> {
                    val uriStr = call.arguments as? String
                    result.success(mediaUriExists(uriStr))
                }
                "startCallService" -> {
                    val args = call.arguments as? Map<*, *>
                    val name = args?.get("name") as? String ?: "Contact"
                    val isVideo = args?.get("isVideo") as? Boolean ?: false
                    val intent = CallForegroundService.startIntent(this, name, isVideo)
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
                // Launch the system package installer for a downloaded APK.
                "installApk" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.error("NO_PATH", "Missing APK path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        val uri = FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", e.message, null)
                    }
                }
                // Opens the system text-to-speech screen so the user can
                // install a missing language (e.g. Tamil) or switch engine.
                "openTtsSettings" -> {
                    try {
                        val intent = Intent("com.android.settings.TTS_SETTINGS").apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // Copies [srcPath] into the public Music/Calendar folder. Uses MediaStore on
    // API 29+ (scoped storage) and a direct file write on older versions.
    // Returns a human-readable destination string.
    private fun saveAudioToMusic(srcPath: String, name: String, mime: String): String {
        val src = File(srcPath)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                put(MediaStore.Audio.Media.MIME_TYPE, mime)
                put(MediaStore.Audio.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_MUSIC + "/Calendar")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("insert failed")
            resolver.openOutputStream(uri).use { out ->
                src.inputStream().use { input -> input.copyTo(out!!) }
            }
            values.clear()
            values.put(MediaStore.Audio.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Music/Calendar/$name"
        } else {
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_MUSIC), "Calendar")
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, name)
            src.inputStream().use { input ->
                dest.outputStream().use { out -> input.copyTo(out) }
            }
            return dest.absolutePath
        }
    }

    // Saves [srcPath] into the public MediaStore collection for [kind]
    // (image → Pictures/Calendar, video → Movies/Calendar, audio → Music/Calendar).
    // Returns the content URI string so existence can be verified later.
    private fun saveMediaToStore(
        srcPath: String, name: String, mime: String, kind: String,
    ): String {
        val src = File(srcPath)
        val (collection, relPath) = when (kind) {
            "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI to
                (Environment.DIRECTORY_MOVIES + "/Calendar")
            "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to
                (Environment.DIRECTORY_MUSIC + "/Calendar")
            else -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI to
                (Environment.DIRECTORY_PICTURES + "/Calendar")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("insert failed")
            resolver.openOutputStream(uri).use { out ->
                src.inputStream().use { input -> input.copyTo(out!!) }
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val baseDir = when (kind) {
                "video" -> Environment.DIRECTORY_MOVIES
                "audio" -> Environment.DIRECTORY_MUSIC
                else -> Environment.DIRECTORY_PICTURES
            }
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(baseDir), "Calendar")
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, name)
            src.inputStream().use { input ->
                dest.outputStream().use { out -> input.copyTo(out) }
            }
            // Make it visible to the gallery/media scanner.
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DATA, dest.absolutePath)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
            }
            val uri = contentResolver.insert(collection, values)
            return uri?.toString() ?: dest.absolutePath
        }
    }

    // Returns true if the MediaStore row for [uriStr] still resolves to a file.
    private fun mediaUriExists(uriStr: String?): Boolean {
        if (uriStr.isNullOrEmpty()) return false
        return try {
            val uri = Uri.parse(uriStr)
            if (uri.scheme == "content") {
                contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID),
                    null, null, null)?.use { it.count > 0 } ?: false
            } else {
                File(uri.path ?: uriStr).exists()
            }
        } catch (_: Exception) {
            false
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
