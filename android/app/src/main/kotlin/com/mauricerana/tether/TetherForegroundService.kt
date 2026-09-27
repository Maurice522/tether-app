package com.mauricerana.tether

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Holds foreground-service privilege for the whole app process so Android
 * doesn't freeze it (and with it, the Dart isolate running discovery, the
 * transfer server, and clipboard sync) shortly after the window is
 * backgrounded. Also holds a Wi-Fi multicast lock for as long as it runs:
 * without one, Android can silently drop the UDP broadcast packets
 * discovery depends on once the radio enters a power-save state — sending
 * and receiving both look fine locally, the packets just never arrive
 * over the air. Everything here is best-effort and wrapped so a failure
 * in any of it can never crash the app; all real work stays in the
 * existing Flutter engine/isolate exactly as before.
 */
class TetherForegroundService : Service() {
    companion object {
        private const val TAG = "TetherFgService"
        private const val CHANNEL_ID = "tether_running"
        private const val NOTIFICATION_ID = 1
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            createNotificationChannel()

            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            val contentIntent = launchIntent?.let {
                PendingIntent.getActivity(
                    this, 0, it,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Tether")
                .setContentText("Running in the background so nearby devices can still reach you")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()

            startForeground(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "failed to start foreground notification", e)
        }

        acquireMulticastLock()
        return START_STICKY
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = wifi.createMulticastLock("tether_discovery")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
        } catch (e: Exception) {
            Log.e(TAG, "failed to acquire multicast lock", e)
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.e(TAG, "failed to release multicast lock", e)
        }
        multicastLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Tether background service",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps device discovery and transfers working while the app is backgrounded"
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
