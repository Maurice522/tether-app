package com.mauricerana.tether

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "TetherMainActivity"
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
        private const val QUIT_CHANNEL = "com.mauricerana.tether/quit"
        private const val REVEAL_CHANNEL = "com.mauricerana.tether/reveal"
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
                    stopService(Intent(this, TetherForegroundService::class.java))
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

        // Android has no Finder-style "reveal in folder" — the closest,
        // most reliably useful equivalent is handing the file to whatever
        // app the OS considers the right viewer for it (same behavior as
        // tapping a completed download's notification). A raw file:// path
        // can't be shared with another app under scoped storage, so this
        // goes through FileProvider for a content:// URI instead.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REVEAL_CHANNEL).setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("bad_args", "path required", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "openFile" -> result.success(openWithViewer(File(path), asFolder = false))
                "openFolder" -> result.success(openWithViewer(File(path), asFolder = true))
                else -> result.notImplemented()
            }
        }
    }

    private fun openWithViewer(target: File, asFolder: Boolean): Boolean {
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", target)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                if (asFolder) {
                    setDataAndType(uri, "resource/folder")
                } else {
                    setDataAndType(uri, contentResolver.getType(uri) ?: "*/*")
                }
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.e(TAG, "failed to open $target (asFolder=$asFolder)", e)
            false
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
            ContextCompat.startForegroundService(this, Intent(this, TetherForegroundService::class.java))
        } catch (e: Exception) {
            Log.e(TAG, "failed to start foreground service", e)
        }
    }
}
