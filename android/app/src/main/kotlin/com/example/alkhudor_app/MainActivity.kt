package com.example.alkhudor_app

import android.os.Environment
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.khdr/downloader",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Returns all WebView cookies for the given URL as a Cookie header string.
                // The WebView's cookie store is always current; the session_id stored in
                // SharedPreferences can be stale if Odoo refreshed the session.
                "getCookies" -> {
                    val url = call.argument<String>("url") ?: ""
                    result.success(CookieManager.getInstance().getCookie(url) ?: "")
                }
                // Returns the path of the public Downloads folder so Dart can write there
                // directly without going through DownloadManager.
                "getPublicDownloadsPath" -> {
                    val dir = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS,
                    )
                    result.success(dir.absolutePath)
                }
                else -> result.notImplemented()
            }
        }
    }
}
