package com.xycz.simple_live

import android.annotation.SuppressLint
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.projection.MediaProjection
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.util.Log
import android.view.Surface
import androidx.annotation.RequiresApi
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

/** 一段录好的视频，交给 Dart（recordStop 的返回值） */
data class RecordingResult(
    val path: String,
    val durationMs: Long,
    val bytes: Long,
    /** 声音轨道真的写进去了 */
    val audio: Boolean,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "path" to path,
        "durationMs" to durationMs,
        "bytes" to bytes,
        "savedToAlbum" to false,
        "audio" to audio,
    )
}

/**
 * 录屏管线：MediaProjection 的虚拟显示器（整个屏幕，和屏幕一样大）画进 SurfaceTexture，
 * OpenGL 只取播放器区域，按 fps 定时画进 H.264 编码器的输入 Surface；
 * App 自己的声音（安卓 10 起）编成 AAC，和画面一起写进 MP4。
 * start 在主线程调用；stop 会阻塞几秒，在后台线程调用。两者不要同时调用
 */
internal class ScreenRecorder(
    private val projection: MediaProjection,
    private val path: String,
    private val displayWidth: Int,
    private val displayHeight: Int,
    private val densityDpi: Int,
    /** 播放器区域，屏幕像素 */
    private val crop: Rect,
    private val fps: Int,
    private val wantAudio: Boolean,
    /** 系统停掉了录屏、画面尺寸变了或编码出错（主线程回调，原因见 ScreenCapture） */
    private val onInterrupted: (String) -> Unit,
) {
    companion object {
        private const val TAG = "SimpleLiveCapture"
        private const val VIDEO_MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val AUDIO_MIME = MediaFormat.MIMETYPE_AUDIO_AAC
        private const val SAMPLE_RATE = 48000
        private const val CHANNELS = 2
        /** 16 位立体声：一帧 4 字节 */
        private const val BYTES_PER_FRAME = 4
        private const val EGL_RECORDABLE_ANDROID = 0x3142
        /** 等声音轨道格式的最长时间，超过就只录画面 */
        private const val AUDIO_WAIT_US = 2_000_000L

        private const val VERTEX_SHADER = """
uniform mat4 uTexMatrix;
attribute vec4 aPosition;
attribute vec4 aTexCoord;
varying vec2 vTexCoord;
void main() {
    gl_Position = aPosition;
    vTexCoord = (uTexMatrix * aTexCoord).xy;
}
"""

        private const val FRAGMENT_SHADER = """
#extension GL_OES_EGL_image_external : require
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
varying vec2 vTexCoord;
uniform samplerExternalOES sTexture;
void main() {
    gl_FragColor = texture2D(sTexture, vTexCoord);
}
"""

        private fun floatBuffer(values: FloatArray): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .apply {
                    put(values)
                    position(0)
                }
    }

    /** 等着写进文件的一段编码数据（轨道还没齐时先存着） */
    private class PendingSample(val video: Boolean, val data: ByteArray, val ptsUs: Long, val flags: Int)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val glThread = HandlerThread("SimpleLiveCaptureGL").apply { start() }
    private val glHandler = Handler(glThread.looper)
    private val codecThread = HandlerThread("SimpleLiveCaptureCodec").apply { start() }
    private val codecHandler = Handler(codecThread.looper)

    // 画面编码
    private var outWidth = 0
    private var outHeight = 0
    private var videoEncoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private val videoDone = CountDownLatch(1)

    // OpenGL：只在 glThread 上用
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texture = 0
    private var aPosition = 0
    private var aTexCoord = 0
    private var uTexMatrix = 0
    private var uTexture = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var displaySurface: Surface? = null
    private val texMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private var hasFrame = false
    private var nextFrameNs = 0L
    private val frameIntervalNs = 1_000_000_000L / fps
    private val vertexBuffer = floatBuffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))

    /** 纹理坐标（左下角为原点）只取播放器区域 */
    private val texCoordBuffer: FloatBuffer = run {
        val left = crop.left.toFloat() / displayWidth
        val right = crop.right.toFloat() / displayWidth
        val top = 1f - crop.top.toFloat() / displayHeight
        val bottom = 1f - crop.bottom.toFloat() / displayHeight
        floatBuffer(floatArrayOf(left, bottom, right, bottom, left, top, right, top))
    }

    private var virtualDisplay: VirtualDisplay? = null
    @Volatile
    private var running = false

    // 写文件：画面编码回调和声音线程都会写，都在 muxerLock 里
    private val muxerLock = Any()
    private var muxer: MediaMuxer? = null
    private var videoTrack = -1
    private var audioTrack = -1
    private var muxerStarted = false
    private var audioExpected = false
    private var waitingSinceUs = -1L
    private val pending = ArrayList<PendingSample>()
    private var firstVideoUs = -1L
    private var lastVideoUs = -1L
    private var lastAudioUs = -1L
    private var audioWritten = false

    // 声音
    private var audioRecord: AudioRecord? = null
    private var audioEncoder: MediaCodec? = null
    private var audioThread: Thread? = null
    @Volatile
    private var audioRunning = false

    // 主线程
    private var contentSize: Pair<Int, Int>? = null
    private var interrupted = false

    private val projectionCallback = object : MediaProjection.Callback() {
        /** 通知栏的录屏标签、锁屏、别的应用开始录屏等：系统停掉了录屏 */
        override fun onStop() {
            interrupt("projection")
        }

        /** 安卓 14 起：开始时报一次大小，之后变了（转屏、折叠屏展开）就停 */
        override fun onCapturedContentResize(width: Int, height: Int) {
            val size = Pair(width, height)
            val first = contentSize
            if (first == null) {
                contentSize = size
            } else if (first != size) {
                interrupt("resize")
            }
        }
    }

    private val videoCallback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            // 输入走 Surface
        }

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            try {
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null) writeSample(true, buffer, info)
                codec.releaseOutputBuffer(index, false)
            } catch (e: Exception) {
                Log.w(TAG, "video output failed", e)
            }
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) videoDone.countDown()
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            Log.w(TAG, "video encoder error", e)
            videoDone.countDown()
            interrupt("error")
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            synchronized(muxerLock) {
                if (!muxerStarted && videoTrack < 0) videoTrack = muxer?.addTrack(format) ?: -1
            }
        }
    }

    /** 定时往编码器送一帧（画面没变时重复上一帧），帧率稳定 */
    private val frameTick = object : Runnable {
        override fun run() {
            if (!running) return
            val now = System.nanoTime()
            if (hasFrame) {
                try {
                    drawFrame(now)
                } catch (e: Exception) {
                    Log.w(TAG, "draw failed", e)
                }
            }
            nextFrameNs += frameIntervalNs
            if (nextFrameNs <= now) nextFrameNs = now + frameIntervalNs
            val delayMs = max(1L, (nextFrameNs - System.nanoTime()) / 1_000_000L)
            glHandler.postDelayed(this, delayMs)
        }
    }

    /** 开始录。失败时抛异常（已经放掉占用的资源，包括 MediaProjection） */
    fun start() {
        try {
            startVideoEncoder()
            val file = File(path)
            file.parentFile?.mkdirs()
            file.delete()
            muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val surface = onGl { setUpGl() }
            // 安卓 14 起必须先注册回调才能建虚拟显示器
            projection.registerCallback(projectionCallback, mainHandler)
            virtualDisplay = projection.createVirtualDisplay(
                "SimpleLiveCapture",
                displayWidth,
                displayHeight,
                densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface,
                null,
                null,
            ) ?: throw IllegalStateException("Cannot create virtual display")
            if (wantAudio && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startAudio()
            }
            running = true
            glHandler.post {
                nextFrameNs = System.nanoTime()
                frameTick.run()
            }
        } catch (e: Exception) {
            releaseAll(deleteFile = true)
            throw e
        }
    }

    /** 停下并写完文件（阻塞，最多几秒）。什么都没录到时抛异常并删掉文件 */
    fun stop(): RecordingResult {
        running = false
        try {
            onGl { glHandler.removeCallbacks(frameTick) }
        } catch (e: Exception) {
            Log.w(TAG, "stop frames failed", e)
        }
        try {
            virtualDisplay?.release()
        } catch (e: Exception) {
            Log.w(TAG, "virtual display release failed", e)
        }
        virtualDisplay = null
        try {
            videoEncoder?.signalEndOfInputStream()
        } catch (e: Exception) {
            Log.w(TAG, "end of stream failed", e)
            videoDone.countDown()
        }
        // 声音：停掉录音让阻塞的 read 返回，线程自己送结束标记、编完剩下的
        audioRunning = false
        try {
            audioRecord?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "audio stop failed", e)
        }
        audioThread?.join(3000)
        if (!videoDone.await(3, TimeUnit.SECONDS)) Log.w(TAG, "video encoder did not finish")
        return finish()
    }

    private fun finish(): RecordingResult {
        var ok = false
        var durationMs = 0L
        var hadAudio = false
        synchronized(muxerLock) {
            val target = muxer
            if (target != null) {
                try {
                    // 录得很短、声音轨道还没来：先把已有的画面写进去
                    if (!muxerStarted && videoTrack >= 0 && pending.isNotEmpty()) {
                        startMuxer(target, 0L, force = true)
                    }
                    if (muxerStarted) {
                        target.stop()
                        ok = firstVideoUs >= 0
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "muxer stop failed", e)
                    ok = false
                }
                try {
                    target.release()
                } catch (e: Exception) {
                    Log.w(TAG, "muxer release failed", e)
                }
            }
            muxer = null
            muxerStarted = false
            if (firstVideoUs >= 0) durationMs = (lastVideoUs - firstVideoUs) / 1000 + 1000L / fps
            hadAudio = audioWritten
        }
        releaseAll(deleteFile = !ok)
        if (!ok) throw IllegalStateException("No video was recorded")
        return RecordingResult(path, durationMs, File(path).length(), hadAudio)
    }

    private fun interrupt(reason: String) {
        mainHandler.post {
            if (!running || interrupted) return@post
            interrupted = true
            onInterrupted(reason)
        }
    }

    // ---- 画面 ----

    private fun startVideoEncoder() {
        val encoder = MediaCodec.createEncoderByType(VIDEO_MIME)
        videoEncoder = encoder
        val caps = encoder.codecInfo.getCapabilitiesForType(VIDEO_MIME).videoCapabilities
        val size = fitSize(caps, crop.width(), crop.height())
        outWidth = size.first
        outHeight = size.second
        val wanted = (outWidth.toDouble() * outHeight * fps * 0.15).toInt().coerceIn(1_500_000, 20_000_000)
        val bitRate = caps.bitrateRange.clamp(wanted)
        val format = MediaFormat.createVideoFormat(VIDEO_MIME, outWidth, outHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        encoder.setCallback(videoCallback, codecHandler)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoderSurface = encoder.createInputSurface()
        encoder.start()
    }

    /** 编码器支持的尺寸：太大就按比例缩小；宽高对齐到编码器要求（至少偶数） */
    private fun fitSize(caps: MediaCodecInfo.VideoCapabilities, width: Int, height: Int): Pair<Int, Int> {
        val widthAlign = max(2, caps.widthAlignment)
        val heightAlign = max(2, caps.heightAlignment)
        var scale = min(
            1.0,
            min(
                caps.supportedWidths.upper.toDouble() / width,
                caps.supportedHeights.upper.toDouble() / height,
            ),
        )
        repeat(20) {
            val w = align(width * scale, widthAlign)
            val h = align(height * scale, heightAlign)
            if (caps.isSizeSupported(w, h)) return Pair(w, h)
            scale *= 0.9
        }
        return Pair(align(width * scale, widthAlign), align(height * scale, heightAlign))
    }

    private fun align(value: Double, alignment: Int): Int = max(alignment, (value.toInt() / alignment) * alignment)

    /** glThread：EGL 画到编码器的输入 Surface；返回给虚拟显示器用的 Surface（SurfaceTexture） */
    private fun setUpGl(): Surface {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "No EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        eglDisplay = display
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "No EGL config"
        }
        val config = configs[0] ?: throw IllegalStateException("No EGL config")
        val context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
            0,
        )
        check(context != null && context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        eglContext = context
        val surface = EGL14.eglCreateWindowSurface(
            display,
            config,
            requireNotNull(encoderSurface),
            intArrayOf(EGL14.EGL_NONE),
            0,
        )
        check(surface != null && surface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }
        eglSurface = surface
        check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent failed" }

        program = buildProgram()
        aPosition = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
        uTexMatrix = GLES20.glGetUniformLocation(program, "uTexMatrix")
        uTexture = GLES20.glGetUniformLocation(program, "sTexture")

        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        texture = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val st = SurfaceTexture(texture)
        st.setDefaultBufferSize(displayWidth, displayHeight)
        // 新画面一来就取走（不让虚拟显示器等），定时器再按 fps 画
        st.setOnFrameAvailableListener({ onFrameAvailable() }, glHandler)
        surfaceTexture = st
        val target = Surface(st)
        displaySurface = target
        return target
    }

    private fun onFrameAvailable() {
        val st = surfaceTexture ?: return
        try {
            st.updateTexImage()
            st.getTransformMatrix(texMatrix)
            hasFrame = true
        } catch (e: Exception) {
            Log.w(TAG, "updateTexImage failed", e)
        }
    }

    private fun drawFrame(timeNs: Long) {
        GLES20.glViewport(0, 0, outWidth, outHeight)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glUniformMatrix4fv(uTexMatrix, 1, false, texMatrix, 0)
        GLES20.glUniform1i(uTexture, 0)
        GLES20.glEnableVertexAttribArray(aPosition)
        GLES20.glVertexAttribPointer(aPosition, 2, GLES20.GL_FLOAT, false, 8, vertexBuffer)
        GLES20.glEnableVertexAttribArray(aTexCoord)
        GLES20.glVertexAttribPointer(aTexCoord, 2, GLES20.GL_FLOAT, false, 8, texCoordBuffer)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPosition)
        GLES20.glDisableVertexAttribArray(aTexCoord)
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, timeNs)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
    }

    private fun buildProgram(): Int {
        val vertex = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fragment = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        val id = GLES20.glCreateProgram()
        GLES20.glAttachShader(id, vertex)
        GLES20.glAttachShader(id, fragment)
        GLES20.glLinkProgram(id)
        val status = IntArray(1)
        GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, status, 0)
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetProgramInfoLog(id)
            GLES20.glDeleteProgram(id)
            throw IllegalStateException("GL link failed: $log")
        }
        return id
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("GL compile failed: $log")
        }
        return shader
    }

    /** glThread：放掉 EGL（不调用 eglTerminate，Flutter 也在用默认的 EGLDisplay） */
    private fun releaseGl() {
        surfaceTexture?.setOnFrameAvailableListener(null)
        surfaceTexture?.release()
        surfaceTexture = null
        displaySurface?.release()
        displaySurface = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                if (program != 0) GLES20.glDeleteProgram(program)
                if (texture != 0) GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
            }
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglReleaseThread()
        }
        program = 0
        texture = 0
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    /** 在 glThread 上执行并等结果 */
    private fun <T> onGl(block: () -> T): T {
        if (Looper.myLooper() == glHandler.looper) return block()
        val latch = CountDownLatch(1)
        var value: T? = null
        var failure: Throwable? = null
        val posted = glHandler.post {
            try {
                value = block()
            } catch (t: Throwable) {
                failure = t
            } finally {
                latch.countDown()
            }
        }
        if (!posted) throw IllegalStateException("GL thread stopped")
        if (!latch.await(5, TimeUnit.SECONDS)) throw IllegalStateException("GL thread timed out")
        failure?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    // ---- 声音（安卓 10 起：只录 App 自己放出来的声音，要 RECORD_AUDIO 权限） ----

    @SuppressLint("MissingPermission")
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startAudio() {
        var record: AudioRecord? = null
        var encoder: MediaCodec? = null
        try {
            val config = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUid(Process.myUid())
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()
            val minBuffer = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val newRecord = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(max(minBuffer * 2, 16384))
                .setAudioPlaybackCaptureConfig(config)
                .build()
            record = newRecord
            check(newRecord.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord not initialized" }
            val aac = MediaFormat.createAudioFormat(AUDIO_MIME, SAMPLE_RATE, CHANNELS).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }
            val newEncoder = MediaCodec.createEncoderByType(AUDIO_MIME)
            encoder = newEncoder
            newEncoder.configure(aac, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            newEncoder.start()
            newRecord.startRecording()
            check(newRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "AudioRecord not recording" }
            synchronized(muxerLock) { audioExpected = true }
            audioRecord = newRecord
            audioEncoder = newEncoder
            audioRunning = true
            audioThread = Thread({ audioLoop(newRecord, newEncoder) }, "SimpleLiveCaptureAudio").apply { start() }
        } catch (e: Exception) {
            // 没有声音也照样录画面（结果里 audio 为 false）
            Log.w(TAG, "app audio capture unavailable", e)
            try {
                record?.release()
            } catch (ignored: Exception) {
            }
            try {
                encoder?.release()
            } catch (ignored: Exception) {
            }
            audioRecord = null
            audioEncoder = null
        }
    }

    private fun audioLoop(record: AudioRecord, encoder: MediaCodec) {
        // 1024 帧 = 一个 AAC 帧
        val chunk = ByteArray(1024 * BYTES_PER_FRAME)
        val info = MediaCodec.BufferInfo()
        var startNs = -1L
        var frames = 0L
        try {
            while (audioRunning) {
                val read = record.read(chunk, 0, chunk.size)
                if (read < 0) {
                    Log.w(TAG, "audio read failed: $read")
                    break
                }
                if (read == 0) continue
                if (startNs < 0) startNs = System.nanoTime() - framesToNs((read / BYTES_PER_FRAME).toLong())
                var offset = 0
                var attempts = 0
                while (offset < read && attempts < 50) {
                    val index = encoder.dequeueInputBuffer(10_000)
                    if (index < 0) {
                        attempts++
                        drainAudio(encoder, info, false)
                        continue
                    }
                    val input = encoder.getInputBuffer(index) ?: break
                    input.clear()
                    val size = min(input.remaining(), read - offset)
                    input.put(chunk, offset, size)
                    encoder.queueInputBuffer(index, 0, size, (startNs + framesToNs(frames)) / 1000, 0)
                    frames += (size / BYTES_PER_FRAME).toLong()
                    offset += size
                }
                drainAudio(encoder, info, false)
            }
            // 收尾：送结束标记，把剩下的编完
            var index = -1
            var attempts = 0
            while (index < 0 && attempts < 50) {
                index = encoder.dequeueInputBuffer(10_000)
                if (index < 0) {
                    attempts++
                    drainAudio(encoder, info, false)
                }
            }
            if (index >= 0) {
                val endUs = (max(startNs, 0L) + framesToNs(frames)) / 1000
                encoder.queueInputBuffer(index, 0, 0, endUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                drainAudio(encoder, info, true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "audio loop failed", e)
        } finally {
            try {
                record.stop()
            } catch (ignored: Exception) {
            }
            try {
                record.release()
            } catch (ignored: Exception) {
            }
            try {
                encoder.stop()
            } catch (ignored: Exception) {
            }
            try {
                encoder.release()
            } catch (ignored: Exception) {
            }
        }
    }

    private fun drainAudio(encoder: MediaCodec, info: MediaCodec.BufferInfo, untilEnd: Boolean) {
        var idle = 0
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, if (untilEnd) 10_000L else 0L)
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!untilEnd || ++idle > 100) return
            } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                synchronized(muxerLock) {
                    if (!muxerStarted && audioTrack < 0) audioTrack = muxer?.addTrack(encoder.outputFormat) ?: -1
                }
            } else if (index >= 0) {
                val buffer = encoder.getOutputBuffer(index)
                if (buffer != null) writeSample(false, buffer, info)
                encoder.releaseOutputBuffer(index, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
            }
        }
    }

    private fun framesToNs(frames: Long): Long = frames * 1_000_000_000L / SAMPLE_RATE

    // ---- 写文件 ----

    private fun writeSample(video: Boolean, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (info.size <= 0 || (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) return
        synchronized(muxerLock) {
            val target = muxer ?: return
            val pts = info.presentationTimeUs
            if (video) {
                if (firstVideoUs < 0) firstVideoUs = pts
                lastVideoUs = max(lastVideoUs, pts)
            } else {
                // 第一帧画面之前的声音不要；声音时间戳必须递增
                if (firstVideoUs < 0 || pts < firstVideoUs || pts <= lastAudioUs) return
                lastAudioUs = pts
            }
            if (!muxerStarted && !startMuxer(target, pts, force = false)) {
                pending.add(PendingSample(video, copyOf(buffer, info), pts, info.flags))
                return
            }
            val track = if (video) videoTrack else audioTrack
            if (track < 0) return
            target.writeSampleData(track, buffer, info)
            if (!video) audioWritten = true
        }
    }

    /** muxerLock 里调用：画面轨道（和要录的声音轨道）都有了才开始写；声音一直不来就只录画面 */
    private fun startMuxer(target: MediaMuxer, nowUs: Long, force: Boolean): Boolean {
        if (videoTrack < 0) return false
        if (audioExpected && audioTrack < 0) {
            if (!force) {
                if (waitingSinceUs < 0) waitingSinceUs = nowUs
                if (nowUs - waitingSinceUs < AUDIO_WAIT_US) return false
                Log.w(TAG, "no audio format, recording video only")
            }
            audioExpected = false
            audioRunning = false
        }
        target.start()
        muxerStarted = true
        val info = MediaCodec.BufferInfo()
        for (sample in pending) {
            val track = if (sample.video) videoTrack else audioTrack
            if (track < 0) continue
            info.set(0, sample.data.size, sample.ptsUs, sample.flags)
            target.writeSampleData(track, ByteBuffer.wrap(sample.data), info)
            if (!sample.video) audioWritten = true
        }
        pending.clear()
        return true
    }

    private fun copyOf(buffer: ByteBuffer, info: MediaCodec.BufferInfo): ByteArray {
        val data = ByteArray(info.size)
        val view = buffer.duplicate()
        view.clear()
        view.limit(info.offset + info.size)
        view.position(info.offset)
        view.get(data)
        return data
    }

    // ---- 收尾 ----

    /** 放掉所有资源（包括 MediaProjection）。可以重复调用 */
    private fun releaseAll(deleteFile: Boolean) {
        running = false
        audioRunning = false
        try {
            virtualDisplay?.release()
        } catch (e: Exception) {
            Log.w(TAG, "virtual display release failed", e)
        }
        virtualDisplay = null
        val thread = audioThread
        if (thread != null) {
            try {
                audioRecord?.stop()
            } catch (ignored: Exception) {
            }
            thread.join(1000)
        } else {
            try {
                audioRecord?.release()
            } catch (ignored: Exception) {
            }
            try {
                audioEncoder?.release()
            } catch (ignored: Exception) {
            }
        }
        audioThread = null
        audioRecord = null
        audioEncoder = null
        try {
            videoEncoder?.stop()
        } catch (ignored: Exception) {
        }
        try {
            videoEncoder?.release()
        } catch (ignored: Exception) {
        }
        videoEncoder = null
        if (glThread.isAlive) {
            try {
                onGl { releaseGl() }
            } catch (e: Exception) {
                Log.w(TAG, "GL release failed", e)
            }
        }
        try {
            encoderSurface?.release()
        } catch (ignored: Exception) {
        }
        encoderSurface = null
        synchronized(muxerLock) {
            try {
                muxer?.release()
            } catch (ignored: Exception) {
            }
            muxer = null
        }
        try {
            projection.unregisterCallback(projectionCallback)
        } catch (ignored: Exception) {
        }
        try {
            projection.stop()
        } catch (ignored: Exception) {
        }
        glThread.quitSafely()
        codecThread.quitSafely()
        if (deleteFile) File(path).delete()
    }
}
