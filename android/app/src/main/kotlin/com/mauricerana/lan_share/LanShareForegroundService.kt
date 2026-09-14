package com.mauricerana.lan_share

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Holds foreground-service privilege for the whole app process so Android
 * doesn't freeze it (and with it, the Dart isolate running discovery, the
 * transfer server, and clipboard sync) shortly after the window is
 * backgrounded. Runs no code of its own beyond the required notification —
 * all real work stays in the existing Flutter engine/isolate exactly as
 * before; this only changes whether Android considers the process
 * background-idle or actively doing user-visible work.
 */
class LanShareForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "lan_share_running"
        private const val NOTIFICATION_ID = 1
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("LAN Share")
            .setContentText("Running in the background so nearby devices can still reach you")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "LAN Share background service",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps device discovery and transfers working while the app is backgrounded"
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
