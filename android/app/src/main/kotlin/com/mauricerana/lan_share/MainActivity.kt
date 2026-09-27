package com.mauricerana.lan_share

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "LanShareMainActivity"
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
        private const val QUIT_CHANNEL = "com.mauricerana.lan_share/quit"
    }

    // The Dart side stops discovery/the transfer server first (so peers
    // get a clean "bye" instead of just timing out), then calls this to
    // finish the job: stop the foreground service that's deliberately
    // keeping this process alive, and actually terminate it. Without an
    // explicit quit, backgrounding the app never truly ends it — that's
    // the whole point of the foreground service — so "close the app" and
    // "quit the app" need to be two different, separately available
    // actions, same as the desktop tray's Show/Quit split.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, QUIT_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "quit") {
                try {
                    stopService(Intent(this, LanShareForegroundService::class.java))
                } catch (e: Exception) {
                    Log.e(TAG, "failed to stop foreground service on quit", e)
                }
                result.success(null)
                finishAndRemoveTask()
                Process.killProcess(Process.myPid())
            } else {
                result.notImplemented()
            }
        }
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
