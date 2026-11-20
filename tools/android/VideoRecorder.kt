package PACKAGE_NAME

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * アプリから送られてくる1コマずつの画像（RGBA）と音（PCM）を、
 * H.264（映像）と AAC（音）の MP4 動画にして、ギャラリーに保存する。
 */
class VideoRecorder(private val context: Context) {
    companion object {
        /** この機種の動画変換器が扱える大きさに直す（扱えないときは少しずつ小さくする） */
        fun fitSize(w0: Int, h0: Int): IntArray {
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            try {
                val caps = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
                var w = w0
                var h = h0
                var scale = 1.0
                var tries = 0
                while (!caps.isSizeSupported(w, h) && tries < 30) {
                    scale *= 0.92
                    w = maxOf(16, (w0 * scale).toInt() / 16 * 16)
                    h = maxOf(16, (h0 * scale).toInt() / 16 * 16)
                    tries++
                }
                return intArrayOf(w, h)
            } finally {
                codec.release()
            }
        }
    }

    private var video: MediaCodec? = null
    private var audio: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var videoTrack = -1
    private var audioTrack = -1
    private var started = false
    private var width = 0
    private var height = 0
    private var fps = 30
    private var frameIndex = 0L
    private var pcm: ShortArray? = null
    private var pcmPos = 0
    private var sampleRate = 44100
    private val pending = ArrayList<Triple<Boolean, ByteBuffer, MediaCodec.BufferInfo>>()
    private val info = MediaCodec.BufferInfo()
    private lateinit var outFile: File
    private var savedUri: Uri? = null

    fun start(w: Int, h: Int, fps: Int, bitrate: Int, pcmBytes: ByteArray?, sampleRate: Int) {
        width = w
        height = h
        this.fps = fps
        frameIndex = 0
        outFile = File(context.cacheDir, "record_${System.currentTimeMillis()}.mp4")
        muxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val vf = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h)
        vf.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        vf.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        vf.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        vf.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        val v = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        v.configure(vf, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        v.start()
        video = v

        if (pcmBytes != null && pcmBytes.isNotEmpty()) {
            val sb = ByteBuffer.wrap(pcmBytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            val arr = ShortArray(sb.remaining())
            sb.get(arr)
            pcm = arr
            pcmPos = 0
            this.sampleRate = sampleRate
            val af = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
            af.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            af.setInteger(MediaFormat.KEY_BIT_RATE, 160000)
            af.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            val a = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            a.configure(af, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            a.start()
            audio = a
        }
    }

    /** 1コマ分の画像（幅×高さ×4バイトのRGBA）を動画に加える */
    fun encodeFrame(rgba: ByteArray) {
        val v = video ?: return
        var idx = v.dequeueInputBuffer(10_000)
        var tries = 0
        while (idx < 0 && tries < 500) {
            drain(v, true, false)
            idx = v.dequeueInputBuffer(10_000)
            tries++
        }
        if (idx < 0) throw IllegalStateException("動画の変換が止まりました")
        val image = v.getInputImage(idx) ?: throw IllegalStateException("画像の入れ物を取れませんでした")
        fillYuv(image, rgba)
        val pts = frameIndex * 1_000_000L / fps
        v.queueInputBuffer(idx, 0, width * height * 3 / 2, pts, 0)
        frameIndex++
        drain(v, true, false)
        feedAudio(pts, false)
    }

    /** RGBA を、動画の形式（YUV420：明るさ1枚＋色の差2枚）に変える */
    private fun fillYuv(image: Image, rgba: ByteArray) {
        val w = width
        val h = height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val yRow = yPlane.rowStride
        val yPix = yPlane.pixelStride
        val uRow = uPlane.rowStride
        val uPix = uPlane.pixelStride
        val vRow = vPlane.rowStride
        val vPix = vPlane.pixelStride
        for (y in 0 until h) {
            var i = y * w * 4
            val yo = y * yRow
            val evenRow = (y and 1) == 0
            for (x in 0 until w) {
                val r = rgba[i].toInt() and 0xFF
                val g = rgba[i + 1].toInt() and 0xFF
                val b = rgba[i + 2].toInt() and 0xFF
                yBuf.put(yo + x * yPix, (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte())
                if (evenRow && (x and 1) == 0) {
                    val cu = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val cv = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    uBuf.put((y / 2) * uRow + (x / 2) * uPix, cu.toByte())
                    vBuf.put((y / 2) * vRow + (x / 2) * vPix, cv.toByte())
                }
                i += 4
            }
        }
    }

    /** 映像の時刻 ptsUs までの音を、音の変換器に入れる */
    private fun feedAudio(ptsUs: Long, endOfStream: Boolean) {
        val a = audio ?: return
        val data = pcm ?: return
        val target = if (endOfStream) data.size else minOf(data.size.toLong(), ptsUs * sampleRate / 1_000_000L).toInt()
        var tries = 0
        while (pcmPos < target && tries < 2000) {
            val idx = a.dequeueInputBuffer(10_000)
            if (idx < 0) {
                drain(a, false, false)
                tries++
                continue
            }
            val buf = a.getInputBuffer(idx) ?: continue
            buf.clear()
            buf.order(ByteOrder.LITTLE_ENDIAN)
            val n = minOf(target - pcmPos, buf.remaining() / 2)
            for (k in 0 until n) buf.putShort(data[pcmPos + k])
            a.queueInputBuffer(idx, 0, n * 2, pcmPos.toLong() * 1_000_000L / sampleRate, 0)
            pcmPos += n
            drain(a, false, false)
        }
        if (endOfStream) {
            var idx = a.dequeueInputBuffer(10_000)
            var t = 0
            while (idx < 0 && t < 200) {
                drain(a, false, false)
                idx = a.dequeueInputBuffer(10_000)
                t++
            }
            if (idx >= 0) {
                a.queueInputBuffer(idx, 0, 0, pcmPos.toLong() * 1_000_000L / sampleRate, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
        }
    }

    /** 変換し終わったデータを取り出して、MP4 ファイルに書く */
    private fun drain(codec: MediaCodec, isVideo: Boolean, endOfStream: Boolean) {
        var waits = 0
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
            if (idx == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream || waits > 300) return
                waits++
            } else if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val t = muxer!!.addTrack(codec.outputFormat)
                if (isVideo) videoTrack = t else audioTrack = t
                tryStart()
            } else if (idx >= 0) {
                val buf = codec.getOutputBuffer(idx)
                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) info.size = 0
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    if (started) {
                        muxer!!.writeSampleData(if (isVideo) videoTrack else audioTrack, buf, info)
                    } else {
                        val copy = ByteBuffer.allocate(info.size)
                        copy.put(buf)
                        copy.flip()
                        val ci = MediaCodec.BufferInfo()
                        ci.set(0, info.size, info.presentationTimeUs, info.flags)
                        pending.add(Triple(isVideo, copy, ci))
                    }
                }
                val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                codec.releaseOutputBuffer(idx, false)
                if (eos) return
            }
        }
    }

    /** 映像と音の両方の形式がわかったら、ファイルへの書き込みを始める */
    private fun tryStart() {
        if (started || videoTrack < 0 || (audio != null && audioTrack < 0)) return
        muxer!!.start()
        started = true
        for ((isVideo, b, i) in pending) {
            muxer!!.writeSampleData(if (isVideo) videoTrack else audioTrack, b, i)
        }
        pending.clear()
    }

    /** 書き出しを終えてギャラリーに保存する。保存した場所を返す（取り消しのときは null） */
    fun finish(cancel: Boolean, name: String): String? {
        try {
            val v = video
            if (v != null) {
                var idx = v.dequeueInputBuffer(10_000)
                var t = 0
                while (idx < 0 && t < 200) {
                    drain(v, true, false)
                    idx = v.dequeueInputBuffer(10_000)
                    t++
                }
                if (idx >= 0) {
                    v.queueInputBuffer(idx, 0, 0, frameIndex * 1_000_000L / fps, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
                drain(v, true, true)
            }
            if (audio != null) {
                feedAudio(frameIndex * 1_000_000L / fps, true)
                drain(audio!!, false, true)
            }
        } finally {
            try { video?.stop() } catch (e: Exception) {}
            try { video?.release() } catch (e: Exception) {}
            try { audio?.stop() } catch (e: Exception) {}
            try { audio?.release() } catch (e: Exception) {}
            try { if (started) muxer?.stop() } catch (e: Exception) {}
            try { muxer?.release() } catch (e: Exception) {}
            video = null
            audio = null
            muxer = null
        }
        if (cancel || !started) {
            outFile.delete()
            return null
        }
        return saveToGallery(name)
    }

    private fun saveToGallery(name: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues()
            values.put(MediaStore.Video.Media.DISPLAY_NAME, name)
            values.put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            values.put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/MandelbrotDrift")
            values.put(MediaStore.Video.Media.IS_PENDING, 1)
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("ギャラリーに保存できませんでした")
            resolver.openOutputStream(uri)?.use { out -> outFile.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            outFile.delete()
            savedUri = uri
            return "Movies/MandelbrotDrift/$name"
        }
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_MOVIES), "MandelbrotDrift")
        dir.mkdirs()
        val f = File(dir, name)
        outFile.copyTo(f, true)
        outFile.delete()
        return f.absolutePath
    }

    /** 保存した動画を、YouTube などのアプリに渡すための指示 */
    fun shareIntent(): Intent? {
        val uri = savedUri ?: return null
        val i = Intent(Intent.ACTION_SEND)
        i.type = "video/mp4"
        i.putExtra(Intent.EXTRA_STREAM, uri)
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return i
    }
}
