package com.mauricerana.tether

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Process
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
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
                "publishToDownloads" -> {
                    val fileName = call.argument<String>("fileName")
                    if (fileName == null) {
                        result.error("bad_args", "fileName required", null)
                        return@setMethodCallHandler
                    }
                    result.success(publishToDownloads(File(path), fileName))
                }
                else -> result.notImplemented()
            }
        }
    }

    // Transfers are actually saved under the app's own external-files tree
    // (see defaultDownloadDir() on the Dart side) — invisible from the
    // Files app and other apps' pickers on modern Android, and the only
    // storage location reachable without a MANAGE_EXTERNAL_STORAGE grant
    // the user has to approve by hand. This publishes a copy of [source]
    // into the public MediaStore Downloads collection too, purely so a
    // completed transfer shows up where a user would actually look for
    // it — the app's own folder stays the source of truth Browse/resume
    // read from, this is additive and best-effort, never load-bearing.
    private fun publishToDownloads(source: File, displayName: String): Boolean {
        return try {
            val extension = displayName.substringAfterLast('.', "").lowercase()
            val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "application/octet-stream"
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Tether")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val itemUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
            val wrote = resolver.openOutputStream(itemUri)?.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
                true
            } ?: false
            if (!wrote) {
                resolver.delete(itemUri, null, null)
                return false
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(itemUri, values, null, null)
            true
        } catch (e: Exception) {
            Log.e(TAG, "failed to publish $displayName to Downloads", e)
            false
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

    // receive_sharing_intent (the share-sheet plugin — see
    // lib/main.dart's _initShareIntent) reads whatever Intent this
    // Activity currently holds, both here at cold start and via
    // onNewIntent below for a warm one, and has no defense of its own
    // against a SEND intent whose stream URI it can't actually read: that
    // throws an uncaught SecurityException deep in its native code,
    // before Dart ever gets a chance to see it, crashing the app —
    // confirmed live (a share whose grant hadn't propagated cleanly hit
    // this exact path). Worse, a crashed Activity's launch intent is often
    // replayed on the next start, turning one bad share into a crash loop
    // only a full data wipe would clear. Sanitizing the intent here before
    // the Flutter engine (and so the plugin) ever sees it closes both: a
    // share that can't actually be read is silently dropped instead of
    // taking the whole app down with it.
    override fun onCreate(savedInstanceState: Bundle?) {
        dropUnreadableShareIntent()
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

    // The warm-start counterpart to onCreate's check above — a share
    // arriving while the app is already running comes through here
    // instead, and would otherwise reach the same crashing plugin code.
    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        dropUnreadableShareIntent()
        super.onNewIntent(getIntent())
    }

    // If the current intent is a SEND/SEND_MULTIPLE whose stream URI(s)
    // can't actually be opened, replaces it with an inert one so neither
    // this nor a future cold start hands it to the share-intent plugin.
    private fun dropUnreadableShareIntent() {
        val current = intent ?: return
        if (current.action != Intent.ACTION_SEND && current.action != Intent.ACTION_SEND_MULTIPLE) return

        val uris = mutableListOf<Uri>()
        if (current.action == Intent.ACTION_SEND) {
            current.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        } else {
            current.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        }
        if (uris.isEmpty()) return

        val unreadable = uris.filterNot { isReadable(it) }
        if (unreadable.isEmpty()) return

        Log.w(TAG, "dropping share intent — can't read: $unreadable")
        setIntent(Intent(Intent.ACTION_MAIN))
    }

    private fun isReadable(uri: Uri): Boolean {
        return try {
            contentResolver.openInputStream(uri)?.use { }
            true
        } catch (e: Exception) {
            false
        }
    }
}
