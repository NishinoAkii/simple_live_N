package com.xycz.simple_live

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart 给的通知内容。文字都已经翻译好 */
data class PlaybackInfo(
    val title: String = "",
    val subtitle: String = "",
    /** playing、paused、buffering */
    val state: String = "playing",
    val artwork: Bitmap? = null,
    val channelName: String = "Playback",
    val playLabel: String = "Play",
    val pauseLabel: String = "Pause",
    val stopLabel: String = "Stop",
) {
    val playing: Boolean get() = state != "paused"
}

/**
 * 听直播：Dart 和前台服务、音频焦点之间的通道 simple_live/background_playback。
 * Dart -> 原生：startService、updateService、stopService、audioActive。
 * 原生 -> Dart：onAction（play、pause、stop）、onFocus（gain、loss、lossTransient、duck、noisy）。
 * 只在主线程使用
 */
object BackgroundPlayback {
    private const val TAG = "SimpleLivePlayback"
    const val CHANNEL = "simple_live/background_playback"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    /** 最近一次 Dart 给的内容，服务启动后按它显示 */
    var info = PlaybackInfo()
        private set

    /** Dart 想显示通知。服务还没来得及调用 startForeground 时就被叫停，等它调用完再停 */
    var wanted = false
        private set

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler { call, result -> handle(call, result) }
        channel = ch
    }

    /** Flutter 引擎没了：Dart 不能再控制播放，收起通知、放掉焦点 */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext?.let { AudioFocus.release(it) }
        stopService()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("no_context", "Background playback is not attached", null)
            return
        }
        when (call.method) {
            "startService" -> {
                info = parseInfo(call, info)
                result.success(startService(context))
            }
            "updateService" -> {
                info = parseInfo(call, info)
                PlaybackService.instance?.update(info)
                result.success(null)
            }
            "stopService" -> {
                stopService()
                result.success(null)
            }
            "audioActive" -> {
                val active = call.argument<Boolean>("active") ?: false
                val mix = call.argument<Boolean>("mix") ?: false
                if (active) {
                    AudioFocus.acquire(context, requestFocus = !mix)
                } else {
                    AudioFocus.release(context)
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun parseInfo(call: MethodCall, old: PlaybackInfo): PlaybackInfo {
        val bytes = call.argument<ByteArray>("artwork")
        val artwork = if (bytes != null && bytes.isNotEmpty()) {
            try {
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            } catch (e: Exception) {
                null
            }
        } else {
            null
        }
        return PlaybackInfo(
            title = call.argument<String>("title") ?: "",
            subtitle = call.argument<String>("subtitle") ?: "",
            state = call.argument<String>("state") ?: "playing",
            artwork = artwork,
            channelName = call.argument<String>("channelName") ?: old.channelName,
            playLabel = call.argument<String>("playLabel") ?: old.playLabel,
            pauseLabel = call.argument<String>("pauseLabel") ?: old.pauseLabel,
            stopLabel = call.argument<String>("stopLabel") ?: old.stopLabel,
        )
    }

    /** 启动前台服务。安卓 12 起只能在 App 还在前台时启动，所以由 Dart 在开听直播时调用 */
    private fun startService(context: Context): Boolean {
        wanted = true
        val running = PlaybackService.instance
        if (running != null) {
            running.update(info)
            return true
        }
        val intent = Intent(context, PlaybackService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "start failed", e)
            wanted = false
            false
        }
    }

    private fun stopService() {
        wanted = false
        PlaybackService.instance?.shutdown()
    }

    fun sendAction(action: String) {
        channel?.invokeMethod("onAction", mapOf("action" to action))
    }

    fun sendFocus(event: String) {
        channel?.invokeMethod("onFocus", mapOf("event" to event))
    }
}

/** 音频焦点和拔耳机（ACTION_AUDIO_BECOMING_NOISY）。“与其他应用同时播放”时只听拔耳机 */
private object AudioFocus {
    /** 安卓 8 起的 AudioFocusRequest（存成 Any，安卓 7 上不碰这个类） */
    private var request: Any? = null
    private var holding = false
    private var requested = false
    private var noisyRegistered = false

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        val event = when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> "gain"
            AudioManager.AUDIOFOCUS_LOSS -> "loss"
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "lossTransient"
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "duck"
            else -> null
        }
        if (change == AudioManager.AUDIOFOCUS_LOSS) {
            holding = false
        }
        if (event != null) {
            BackgroundPlayback.sendFocus(event)
        }
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                BackgroundPlayback.sendFocus("noisy")
            }
        }
    }

    fun acquire(context: Context, requestFocus: Boolean) {
        if (!noisyRegistered) {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // 系统广播照样收得到
                context.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(noisyReceiver, filter)
            }
            noisyRegistered = true
        }
        if (!requestFocus) {
            abandon(context)
            return
        }
        if (holding) {
            return
        }
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            requestModern(manager)
        } else {
            requestLegacy(manager)
        }
        requested = true
        holding = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    @SuppressLint("NewApi")
    private fun requestModern(manager: AudioManager): Int {
        val focusRequest = request as? AudioFocusRequest
            ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setOnAudioFocusChangeListener(listener, Handler(Looper.getMainLooper()))
                .build()
        request = focusRequest
        return manager.requestAudioFocus(focusRequest)
    }

    @Suppress("DEPRECATION")
    private fun requestLegacy(manager: AudioManager): Int =
        manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)

    fun release(context: Context) {
        if (noisyRegistered) {
            try {
                context.unregisterReceiver(noisyReceiver)
            } catch (e: Exception) {
                // 已经注销
            }
            noisyRegistered = false
        }
        abandon(context)
    }

    /** 失去焦点（AUDIOFOCUS_LOSS）以后也放一次，系统里不留着这个请求 */
    private fun abandon(context: Context) {
        if (!requested) {
            return
        }
        requested = false
        holding = false
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            abandonModern(manager)
        } else {
            abandonLegacy(manager)
        }
    }

    @SuppressLint("NewApi")
    private fun abandonModern(manager: AudioManager) {
        val focusRequest = request as? AudioFocusRequest
        if (focusRequest != null) {
            manager.abandonAudioFocusRequest(focusRequest)
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonLegacy(manager: AudioManager) {
        manager.abandonAudioFocus(listener)
    }
}

/**
 * 听直播的前台服务（mediaPlayback）：媒体通知和 MediaSession，在播时拿着 WifiLock 和 WakeLock。
 * 播放本身还是 mpv，在 Flutter 那边；这里只让系统知道我们在放媒体，别把进程停掉。
 * 媒体通知不需要通知权限
 */
class PlaybackService : Service() {
    companion object {
        private const val TAG = "SimpleLivePlayback"
        private const val NOTIFICATION_ID = 0x5106
        private const val CHANNEL_ID = "background_playback"
        private const val ACTION_PLAY = "com.xycz.simple_live.playback.PLAY"
        private const val ACTION_PAUSE = "com.xycz.simple_live.playback.PAUSE"
        private const val ACTION_STOP = "com.xycz.simple_live.playback.STOP"
        private const val CUSTOM_STOP = "stop"

        /** 正在运行的服务（主线程用） */
        var instance: PlaybackService? = null
            internal set
    }

    private var session: MediaSession? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onCreate() {
        super.onCreate()
        instance = this
        val mediaSession = MediaSession(this, "SimpleLive")
        mediaSession.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                BackgroundPlayback.sendAction("play")
            }

            override fun onPause() {
                BackgroundPlayback.sendAction("pause")
            }

            override fun onStop() {
                BackgroundPlayback.sendAction("stop")
            }

            override fun onCustomAction(action: String, extras: Bundle?) {
                if (action == CUSTOM_STOP) {
                    BackgroundPlayback.sendAction("stop")
                }
            }
        })
        mediaSession.setSessionActivity(contentIntent())
        mediaSession.isActive = true
        session = mediaSession
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "SimpleLive:playback").apply {
                setReferenceCounted(false)
            }
        } catch (e: Exception) {
            Log.w(TAG, "wifi lock unavailable", e)
        }
        try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SimpleLive:playback").apply {
                setReferenceCounted(false)
            }
        } catch (e: Exception) {
            Log.w(TAG, "wake lock unavailable", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 刚停下又被启动时系统可能还用这个实例
        instance = this
        when (intent?.action) {
            ACTION_PLAY -> BackgroundPlayback.sendAction("play")
            ACTION_PAUSE -> BackgroundPlayback.sendAction("pause")
            ACTION_STOP -> BackgroundPlayback.sendAction("stop")
        }
        // startForegroundService 之后必须马上调用 startForeground
        update(BackgroundPlayback.info)
        if (!BackgroundPlayback.wanted) {
            shutdown()
        }
        return START_NOT_STICKY
    }

    /** 从最近任务里划掉了：Flutter 那边没法再控制播放，连进程一起结束（和没有前台服务时一样） */
    override fun onTaskRemoved(rootIntent: Intent?) {
        shutdown()
        Process.killProcess(Process.myPid())
    }

    override fun onDestroy() {
        releaseLocks()
        session?.isActive = false
        session?.release()
        session = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** 收起通知、停掉服务。之后 Dart 再要显示时重新启动服务 */
    fun shutdown() {
        if (instance === this) instance = null
        releaseLocks()
        if (foreground) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            foreground = false
        }
        stopSelf()
    }

    fun update(info: PlaybackInfo) {
        val mediaSession = session ?: return
        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, info.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, info.subtitle)
        if (info.artwork != null) {
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ART, info.artwork)
        }
        mediaSession.setMetadata(metadata.build())
        val state = when (info.state) {
            "paused" -> PlaybackState.STATE_PAUSED
            "buffering" -> PlaybackState.STATE_BUFFERING
            else -> PlaybackState.STATE_PLAYING
        }
        // 安卓 13 起通知上的按钮按 PlaybackState 来：播放、暂停是标准动作，停止是自定义动作
        mediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP,
                )
                .setState(
                    state,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    if (state == PlaybackState.STATE_PLAYING) 1f else 0f,
                )
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(CUSTOM_STOP, info.stopLabel, R.drawable.ic_playback_stop)
                        .build(),
                )
                .build(),
        )
        val notification = buildNotification(info)
        if (foreground) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, notification)
        } else {
            enterForeground(notification)
        }
        if (info.playing) acquireLocks() else releaseLocks()
    }

    private fun enterForeground(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            foreground = true
        } catch (e: Exception) {
            // 安卓 12 起在后台不让进前台：不显示通知，停掉服务
            Log.w(TAG, "startForeground failed", e)
            stopSelf()
        }
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireLocks() {
        try {
            if (wifiLock?.isHeld == false) wifiLock?.acquire()
            if (wakeLock?.isHeld == false) wakeLock?.acquire()
        } catch (e: Exception) {
            Log.w(TAG, "lock failed", e)
        }
    }

    private fun releaseLocks() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {
            Log.w(TAG, "unlock failed", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(info: PlaybackInfo): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ensureChannel(info.channelName)
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val toggle = if (info.playing) {
            action(R.drawable.ic_playback_pause, info.pauseLabel, ACTION_PAUSE, 1)
        } else {
            action(R.drawable.ic_playback_play, info.playLabel, ACTION_PLAY, 2)
        }
        val style = Notification.MediaStyle().setShowActionsInCompactView(0, 1)
        session?.let { style.setMediaSession(it.sessionToken) }
        builder
            .setSmallIcon(R.drawable.ic_stat_live)
            .setContentTitle(info.title)
            .setContentText(info.subtitle)
            .setContentIntent(contentIntent())
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .addAction(toggle)
            .addAction(action(R.drawable.ic_playback_stop, info.stopLabel, ACTION_STOP, 3))
            .setStyle(style)
        if (info.artwork != null) {
            builder.setLargeIcon(info.artwork)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun ensureChannel(name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 已有时再建一次只会改名字（换了语言）
        val channel = NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
        channel.setShowBadge(false)
        channel.setSound(null, null)
        channel.enableVibration(false)
        manager.createNotificationChannel(channel)
    }

    private fun action(icon: Int, title: String, intentAction: String, requestCode: Int): Notification.Action {
        val intent = Intent(this, PlaybackService::class.java).setAction(intentAction)
        val pending = PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), title, pending).build()
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
