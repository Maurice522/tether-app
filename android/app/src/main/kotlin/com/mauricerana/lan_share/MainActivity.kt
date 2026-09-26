package com.mauricerana.lan_share

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "LanShareMainActivity"
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
    }

    // Best-effort only: neither the permission prompt nor starting the
    // foreground service should ever be able to take the whole app down.
    // Without the service the app still runs fine in the foreground; it
    // just loses the background-survival guarantee, which is a much
    // better failure mode than not launching at all.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE,
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "failed to request notification permission", e)
        }

        try {
            ContextCompat.startForegroundService(this, Intent(this, LanShareForegroundService::class.java))
        } catch (e: Exception) {
            Log.e(TAG, "failed to start foreground service", e)
        }
    }
}
