package com.xycz.simple_live

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // 引擎没了，Dart 控制不了播放：收起听直播的通知、放掉音频焦点
        BackgroundPlayback.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 听直播：前台服务、媒体通知、音频焦点（BackgroundPlayback.kt）
        BackgroundPlayback.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // 系统网络栈请求：Kick 会按 TLS 指纹拦截 Dart 自带的 HTTP 客户端
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "simple_live/native_http")
            .setMethodCallHandler { call, result ->
                if (call.method != "request") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val method = call.argument<String>("method") ?: "GET"
                val url = call.argument<String>("url") ?: ""
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val body = call.argument<String>("body")
                executor.execute {
                    try {
                        val connection = URL(url).openConnection() as HttpURLConnection
                        connection.requestMethod = method
                        connection.connectTimeout = 20000
                        connection.readTimeout = 20000
                        headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
                        if (body != null) {
                            connection.doOutput = true
                            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                        }
                        val status = connection.responseCode
                        val stream = if (status >= 400) connection.errorStream else connection.inputStream
                        val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
                        connection.disconnect()
                        mainHandler.post { result.success(mapOf("status" to status, "body" to text)) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("HTTP_ERROR", e.message, null) }
                    }
                }
            }
    }
}
