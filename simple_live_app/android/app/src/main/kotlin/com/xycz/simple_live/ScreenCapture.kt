package com.xycz.simple_live

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Point
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.View
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * 录屏和复制截图：通道 simple_live/capture（和 Windows 同一套）。
 * Dart -> 原生：recordStart、recordStop、recordActive、copyImage、copyGif、copyFiles（安卓不支持，返回 false）。
 * 原生 -> Dart：onRecordStopped（自动停下时：转屏、窗口大小变了、切到后台、系统停止录屏、
 * 通知上点了停止、到了时长上限）。Dart 没接这个回调时，下一次 recordStop 返回这次的结果。
 * 流程：（要录声音时先要录音权限）→ 系统的录屏确认框 → 前台服务（mediaProjection）→ ScreenRecorder。
 * 只在主线程使用
 */
object ScreenCapture {
    private const val TAG = "SimpleLiveCapture"
    const val CHANNEL = "simple_live/capture"
    private const val REQUEST_CAPTURE = 0x5C01
    private const val REQUEST_AUDIO = 0x5C02
    /** 安全上限：时长由 Dart 管，原生只在 maxSeconds 之后再多等 30 秒；没设时长时 4 小时 */
    private const val CAP_EXTRA_MS = 30_000L
    private const val CAP_DEFAULT_MS = 4 * 3600 * 1000L

    private class Request(
        val result: MethodChannel.Result,
        val path: String,
        val x: Int,
        val y: Int,
        val width: Int,
        val height: Int,
        val fps: Int,
        var audio: Boolean,
        val capMs: Long,
    )

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()

    /** 正在问权限或等确认框、前台服务 */
    private var request: Request? = null
    private var consentCode = 0
    private var consentData: Intent? = null
    private var recorder: ScreenRecorder? = null
    private var stopping = false
    private val stopWaiters = mutableListOf<MethodChannel.Result>()
    /** 自动停下、Dart 没接 onRecordStopped 时留着，下一次 recordStop 返回 */
    private var lastResult: Map<String, Any>? = null
    /** 开始录时的方向和窗口大小：变了裁剪位置就不对了，停下 */
    private var startOrientation = Configuration.ORIENTATION_UNDEFINED
    private var startWidthDp = 0
    private var startHeightDp = 0

    /** 通知文字：Dart 可以在 recordStart 里给翻译好的（notificationTitle、stopLabel、channelName） */
    var notificationTitle = "正在录屏"
        private set
    var stopLabel = "停止"
        private set
    var channelName = "录屏"
        private set

    private val capReached = Runnable { finishRecording("limit") }

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        appContext = activity.applicationContext
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler { call, result -> handle(call, result) }
        channel = ch
    }

    /** Flutter 引擎没了：停下并写完文件，不再通知 Dart */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        request = null
        consentData = null
        finishRecording("closed")
        activity = null
    }

    val isRecording: Boolean get() = recorder != null && !stopping

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recordStart" -> start(call, result)
            "recordStop" -> stop(result)
            "recordActive" -> result.success(isRecording)
            "copyImage" -> copyImage(call, result)
            "copyGif" -> copyGif(call, result)
            "copyFiles" -> result.success(false)
            else -> result.notImplemented()
        }
    }

    private fun MethodCall.int(key: String, fallback: Int): Int =
        (argument<Any>(key) as? Number)?.toInt() ?: fallback

    // ---- 开始 ----

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val host = activity
        if (host == null) {
            result.error("no_activity", "Capture is not attached", null)
            return
        }
        if (request != null || recorder != null) {
            result.error("busy", "Already recording", null)
            return
        }
        val path = call.argument<String>("path")
        val width = call.int("width", 0)
        val height = call.int("height", 0)
        if (path.isNullOrEmpty() || width < 2 || height < 2) {
            result.error("bad_args", "Missing path or empty area", null)
            return
        }
        call.argument<String>("notificationTitle")?.let { notificationTitle = it }
        call.argument<String>("stopLabel")?.let { stopLabel = it }
        call.argument<String>("channelName")?.let { channelName = it }
        val maxSeconds = call.int("maxSeconds", 0)
        val capMs = if (maxSeconds > 0) maxSeconds * 1000L + CAP_EXTRA_MS else CAP_DEFAULT_MS
        lastResult = null
        val req = Request(
            result = result,
            path = path,
            x = call.int("x", 0),
            y = call.int("y", 0),
            width = width,
            height = height,
            fps = call.int("fps", 30).coerceIn(1, 60),
            audio = call.argument<Boolean>("audio") == true,
            capMs = capMs,
        )
        request = req
        // App 自己的声音：安卓 10 起才能录，还要录音权限（不给就只录画面）
        if (req.audio) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                req.audio = false
            } else if (host.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                host.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_AUDIO)
                return
            }
        }
        askConsent(host)
    }

    /** MainActivity.onRequestPermissionsResult 转过来 */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_AUDIO) return false
        val req = request ?: return true
        val host = activity
        if (host == null) {
            request = null
            return true
        }
        req.audio = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        askConsent(host)
        return true
    }

    private fun askConsent(host: Activity) {
        val req = request ?: return
        try {
            val manager = host.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            // 安卓 14 起确认框可以选“单个应用”；这里固定录整个屏幕，播放器区域的坐标才对得上
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
            } else {
                manager.createScreenCaptureIntent()
            }
            host.startActivityForResult(intent, REQUEST_CAPTURE)
        } catch (e: Exception) {
            Log.w(TAG, "consent failed", e)
            request = null
            req.result.error("consent_failed", e.message ?: "Cannot ask for screen capture", null)
        }
    }

    /** MainActivity.onActivityResult 转过来：用户在确认框里的选择 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CAPTURE) return false
        val req = request ?: return true
        val context = appContext
        if (resultCode != Activity.RESULT_OK || data == null || context == null) {
            // 用户点了取消
            request = null
            req.result.success(false)
            return true
        }
        consentCode = resultCode
        consentData = data
        // 安卓 14 起：先进前台服务（mediaProjection），再拿 MediaProjection（onServiceReady）
        try {
            val intent = Intent(context, ScreenCaptureService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "service start failed", e)
            request = null
            consentData = null
            req.result.error("service_failed", e.message ?: "Cannot start capture service", null)
        }
        return true
    }

    /** 前台服务已经调用了 startForeground */
    internal fun onServiceReady(service: ScreenCaptureService) {
        val req = request
        val data = consentData
        if (req == null || data == null) {
            if (recorder == null) service.shutdown()
            return
        }
        request = null
        consentData = null
        var projection: MediaProjection? = null
        try {
            val manager = service.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val newProjection = manager.getMediaProjection(consentCode, data)
                ?: throw IllegalStateException("No media projection")
            projection = newProjection
            val host = activity ?: throw IllegalStateException("App window is gone")
            val geometry = Geometry.of(host)
            val rec = ScreenRecorder(
                projection = newProjection,
                path = req.path,
                displayWidth = geometry.width,
                displayHeight = geometry.height,
                densityDpi = geometry.densityDpi,
                crop = geometry.crop(req),
                fps = req.fps,
                wantAudio = req.audio,
            ) { reason -> finishRecording(reason) }
            rec.start()
            recorder = rec
            val config = host.resources.configuration
            startOrientation = config.orientation
            startWidthDp = config.screenWidthDp
            startHeightDp = config.screenHeightDp
            mainHandler.postDelayed(capReached, req.capMs)
            req.result.success(true)
        } catch (e: Exception) {
            Log.w(TAG, "start failed", e)
            try {
                projection?.stop()
            } catch (ignored: Exception) {
            }
            service.shutdown()
            req.result.error("start_failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** 前台服务没能进前台 */
    internal fun onServiceFailed(e: Exception) {
        val req = request ?: return
        request = null
        consentData = null
        req.result.error("service_failed", e.message ?: "Cannot start capture service", null)
    }

    // ---- 自动停下 ----

    /** MainActivity.onConfigurationChanged：转屏、小窗、分屏改大小 */
    fun onHostConfigurationChanged(config: Configuration) {
        if (!isRecording) return
        if (config.orientation != startOrientation) {
            finishRecording("rotation")
        } else if (config.screenWidthDp != startWidthDp || config.screenHeightDp != startHeightDp) {
            finishRecording("resize")
        }
    }

    /** MainActivity.onStop：切到后台后播放器不在屏幕上了 */
    fun onHostStopped() {
        if (isRecording) finishRecording("background")
    }

    internal fun stopFromNotification() {
        finishRecording("notification")
    }

    /** 从最近任务里划掉了：尽量写完文件 */
    internal fun onTaskRemoved() {
        finishRecording("closed")
    }

    // ---- 停止 ----

    private fun stop(result: MethodChannel.Result) {
        if (recorder == null) {
            val last = lastResult
            if (last != null) {
                lastResult = null
                result.success(last)
            } else {
                result.error("not_recording", "Not recording", null)
            }
            return
        }
        stopWaiters.add(result)
        finishRecording("user")
    }

    /** 停下并在后台线程写完文件，然后回复 recordStop，或者通知 Dart */
    private fun finishRecording(reason: String) {
        val rec = recorder ?: return
        if (stopping) return
        stopping = true
        mainHandler.removeCallbacks(capReached)
        executor.execute {
            val outcome: Pair<Map<String, Any>?, String?> = try {
                Pair(rec.stop().toMap(), null)
            } catch (e: Exception) {
                Log.w(TAG, "stop failed", e)
                Pair(null, e.message ?: e.javaClass.simpleName)
            }
            mainHandler.post { onFinished(reason, outcome.first, outcome.second) }
        }
    }

    private fun onFinished(reason: String, map: Map<String, Any>?, failure: String?) {
        recorder = null
        stopping = false
        ScreenCaptureService.instance?.shutdown()
        val waiters = stopWaiters.toList()
        stopWaiters.clear()
        if (waiters.isNotEmpty()) {
            for (waiter in waiters) {
                if (map != null) waiter.success(map) else waiter.error("stop_failed", failure, null)
            }
            return
        }
        val ch = channel ?: return
        lastResult = map
        val args = HashMap<String, Any?>()
        if (map != null) args.putAll(map)
        args["reason"] = reason
        if (failure != null) args["error"] = failure
        ch.invokeMethod("onRecordStopped", args, object : MethodChannel.Result {
            override fun success(result: Any?) {
                // Dart 接了：不再留给 recordStop
                if (lastResult === map) lastResult = null
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

            override fun notImplemented() {}
        })
    }

    // ---- 复制截图 ----

    /** PNG 存进缓存目录的 capture 文件夹，经 UpdateFileProvider 放进剪贴板 */
    private fun copyImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("png")
        val context = appContext
        if (bytes == null || bytes.isEmpty() || context == null) {
            result.error("bad_args", "Missing image", null)
            return
        }
        copyToClip(context, result, "png") { it.writeBytes(bytes) }
    }

    /**
     * GIF 复制一份到同一个文件夹，同样放进剪贴板（扩展名 .gif，类型是 image/gif）。
     * 粘贴出来是不是动图看目标 App 支不支持。没有文件时返回 false，不碰剪贴板
     */
    private fun copyGif(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val context = appContext
        val source = if (path.isNullOrEmpty()) null else File(path)
        if (source == null || !source.isFile || context == null) {
            result.success(false)
            return
        }
        copyToClip(context, result, "gif") { source.copyTo(it, overwrite = true) }
    }

    private fun copyToClip(context: Context, result: MethodChannel.Result, extension: String, write: (File) -> Unit) {
        executor.execute {
            try {
                val dir = File(context.cacheDir, "capture").apply { mkdirs() }
                // 剪贴板里只放最新的一张，旧的删掉
                dir.listFiles()?.forEach { if (it.name.startsWith("clip_")) it.delete() }
                val file = File(dir, "clip_${System.currentTimeMillis()}.$extension")
                write(file)
                val uri = FileProvider.getUriForFile(context, context.packageName + ".update_provider", file)
                mainHandler.post {
                    try {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "Simple Live", uri))
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(TAG, "clipboard failed", e)
                        result.error("copy_failed", e.message ?: "Clipboard failed", null)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "copy image failed", e)
                mainHandler.post { result.error("copy_failed", e.message ?: "Cannot save image", null) }
            }
        }
    }

    /** 屏幕大小（当前方向）和 Flutter 画面在屏幕上的位置 */
    private class Geometry(
        val width: Int,
        val height: Int,
        val densityDpi: Int,
        val offsetX: Int,
        val offsetY: Int,
    ) {
        /** Dart 给的是 Flutter 画面里的物理像素，换成屏幕像素，并限制在屏幕内 */
        fun crop(req: Request): Rect {
            val left = (req.x + offsetX).coerceIn(0, width - 2)
            val top = (req.y + offsetY).coerceIn(0, height - 2)
            val right = (req.x + offsetX + req.width).coerceIn(left + 2, width)
            val bottom = (req.y + offsetY + req.height).coerceIn(top + 2, height)
            return Rect(left, top, right, bottom)
        }

        companion object {
            fun of(activity: Activity): Geometry {
                val size = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val bounds = activity.windowManager.maximumWindowMetrics.bounds
                    Point(bounds.width(), bounds.height())
                } else {
                    legacyRealSize(activity)
                }
                val location = IntArray(2)
                activity.findViewById<View>(android.R.id.content)?.getLocationOnScreen(location)
                return Geometry(
                    size.x,
                    size.y,
                    activity.resources.configuration.densityDpi,
                    location[0],
                    location[1],
                )
            }

            @Suppress("DEPRECATION")
            private fun legacyRealSize(activity: Activity): Point {
                val point = Point()
                activity.windowManager.defaultDisplay.getRealSize(point)
                return point
            }
        }
    }
}

/**
 * 录屏的前台服务（mediaProjection）：安卓 14 起拿 MediaProjection 之前必须先进前台。
 * 通知“正在录屏”上有停止按钮
 */
class ScreenCaptureService : Service() {
    companion object {
        private const val TAG = "SimpleLiveCapture"
        private const val NOTIFICATION_ID = 0x5C10
        private const val CHANNEL_ID = "screen_capture"
        private const val ACTION_STOP = "com.xycz.simple_live.capture.STOP"

        /** 正在运行的服务（主线程用） */
        var instance: ScreenCaptureService? = null
            internal set
    }

    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        if (intent?.action == ACTION_STOP) {
            if (ScreenCapture.isRecording) {
                ScreenCapture.stopFromNotification()
            } else if (!foreground) {
                stopSelf()
            }
            return START_NOT_STICKY
        }
        if (!foreground) {
            try {
                val notification = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                foreground = true
            } catch (e: Exception) {
                Log.w(TAG, "startForeground failed", e)
                ScreenCapture.onServiceFailed(e)
                shutdown()
                return START_NOT_STICKY
            }
        }
        ScreenCapture.onServiceReady(this)
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        ScreenCapture.onTaskRemoved()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    fun shutdown() {
        if (instance === this) instance = null
        if (foreground) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            foreground = false
        }
        stopSelf()
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ensureChannel()
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ScreenCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        builder
            .setSmallIcon(R.drawable.ic_stat_live)
            .setContentTitle(ScreenCapture.notificationTitle)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_playback_stop),
                    ScreenCapture.stopLabel,
                    stop,
                ).build(),
            )
        contentIntent()?.let { builder.setContentIntent(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(CHANNEL_ID, ScreenCapture.channelName, NotificationManager.IMPORTANCE_LOW)
        channel.setShowBadge(false)
        channel.setSound(null, null)
        channel.enableVibration(false)
        manager.createNotificationChannel(channel)
    }

    /** 点通知回到 App */
    private fun contentIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
