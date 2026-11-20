package io.github.kenjiiida_commits.mandelbrot_drift

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var recorder: VideoRecorder? = null
    @Volatile private var lastShare: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 眺めている間に画面が消えないようにする
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 録画：アプリ（Dart）から1コマずつ画像を受け取り、動画ファイルにする
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mandelbrot_drift/recorder").setMethodCallHandler { call, result ->
            when (call.method) {
                "fitSize" -> work(result) {
                    VideoRecorder.fitSize(call.argument<Int>("width") ?: 1080, call.argument<Int>("height") ?: 1920).toList()
                }
                "start" -> work(result) {
                    val r = VideoRecorder(applicationContext)
                    recorder = r
                    r.start(
                        call.argument<Int>("width") ?: 1080,
                        call.argument<Int>("height") ?: 1920,
                        call.argument<Int>("fps") ?: 30,
                        call.argument<Int>("bitrate") ?: 12_000_000,
                        call.argument<ByteArray>("pcm"),
                        call.argument<Int>("sampleRate") ?: 44100,
                    )
                    null
                }
                "frame" -> work(result) {
                    recorder?.encodeFrame(call.arguments as ByteArray)
                    null
                }
                "finish" -> work(result) {
                    val r = recorder
                    recorder = null
                    val path = r?.finish(call.argument<Boolean>("cancel") ?: false, call.argument<String>("name") ?: "video.mp4")
                    lastShare = r?.shareIntent()
                    path
                }
                "share" -> {
                    val i = lastShare
                    if (i != null) startActivity(Intent.createChooser(i, "動画を共有"))
                    result.success(i != null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 重い処理は別の流れで行い、終わったら結果を返す（画面を止めないため） */
    private fun work(result: MethodChannel.Result, job: () -> Any?) {
        worker.execute {
            try {
                val v = job()
                mainHandler.post { result.success(v) }
            } catch (e: Exception) {
                mainHandler.post { result.error("REC", e.toString(), null) }
            }
        }
    }
}
