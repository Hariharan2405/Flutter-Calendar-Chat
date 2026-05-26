package com.example.calendar_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class CallForegroundService : Service() {

    companion object {
        const val ACTION_START = "ACTION_START_CALL"
        const val ACTION_STOP = "ACTION_STOP_CALL"
        const val EXTRA_NAME = "otherUserName"
        private const val CHANNEL_ID = "tn_calendar_call_service"
        private const val NOTIFICATION_ID = 301

        fun startIntent(context: Context, name: String): Intent =
            Intent(context, CallForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_NAME, name)
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
                ensureChannel()
                startForeground(NOTIFICATION_ID, buildNotification(name))
            }
            ACTION_STOP -> stopGracefully()
        }
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
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

    private fun buildNotification(otherUserName: String): android.app.Notification {
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
        // User swiped the app from recents — process will be killed; clean up notification
        stopGracefully()
    }
}
