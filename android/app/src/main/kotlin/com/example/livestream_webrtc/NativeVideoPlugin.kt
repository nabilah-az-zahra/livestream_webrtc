package com.example.livestream_webrtc

import android.content.Context
import android.graphics.*
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.EventChannel.StreamHandler
import java.io.ByteArrayOutputStream
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.security.SecureRandom
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.*

class NativeVideoPlugin: FlutterPlugin, MethodCallHandler, StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventSink? = null
    
    private val mainHandler = Handler(Looper.getMainLooper())
    private val videoProcessor = Executors.newSingleThreadExecutor()
    private val encryptionProcessor = Executors.newFixedThreadPool(2)

    private var isStreaming = false
    private var targetFPS = 30
    
    private val keyCache = ConcurrentHashMap<String, ByteArray>()
    private var currentStreamId: String? = null
    private var connectedViewers = mutableSetOf<String>()
    
    private var framesSent = 0
    private val fpsMonitor = Executors.newSingleThreadScheduledExecutor()
    
    private var totalFrames = 0
    private var fpsSamples = 0
    
    data class FrameData(
        val width: Int,
        val height: Int,
        val yPlane: ByteArray,
        val uPlane: ByteArray,
        val vPlane: ByteArray,
        val yRowStride: Int,
        val uvRowStride: Int,
        val uvPixelStride: Int,
        val timestamp: Long,
        val frameId: Long = System.nanoTime()
    )

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "native_video_plugin")
        channel.setMethodCallHandler(this)
        
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "native_video_plugin/stream")
        eventChannel.setStreamHandler(this)
        
        startFpsMonitoring()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startVideoStream" -> {
                startVideoStream(call, result)
            }
            "stopVideoStream" -> {
                stopVideoStream(result)
            }
            "addViewer" -> {
                addViewer(call, result)
            }
            "removeViewer" -> {
                removeViewer(call, result)
            }
            "updateViewerKey" -> {
                updateViewerKey(call, result)
            }
            "processFrame" -> {
                processFrame(call, result)
            }
            "setTargetFPS" -> {
                val fps = call.argument<Int>("fps") ?: 30
                setTargetFPS(fps, result)
            }
            "convertYUV420ToJPEG" -> {
                GlobalScope.launch(Dispatchers.IO) {
                    try {
                        val jpegBytes = convertYUV420ToJPEG(call)
                        launch(Dispatchers.Main) {
                            result.success(jpegBytes)
                        }
                    } catch (e: Exception) {
                        launch(Dispatchers.Main) {
                            result.error("CONVERSION_ERROR", e.message, null)
                        }
                    }
                }
            }
            "compressImage" -> {
                GlobalScope.launch(Dispatchers.IO) {
                    try {
                        val compressedBytes = compressImage(call)
                        launch(Dispatchers.Main) {
                            result.success(compressedBytes)
                        }
                    } catch (e: Exception) {
                        launch(Dispatchers.Main) {
                            result.error("COMPRESSION_ERROR", e.message, null)
                        }
                    }
                }
            }
            "encryptFrame" -> {
                GlobalScope.launch(Dispatchers.IO) {
                    try {
                        val encryptedBytes = encryptFrame(call)
                        launch(Dispatchers.Main) {
                            result.success(encryptedBytes)
                        }
                    } catch (e: Exception) {
                        launch(Dispatchers.Main) {
                            result.error("ENCRYPTION_ERROR", e.message, null)
                        }
                    }
                }
            }
            "decryptFrame" -> {
                GlobalScope.launch(Dispatchers.IO) {
                    try {
                        val decryptedBytes = decryptFrame(call)
                        launch(Dispatchers.Main) {
                            result.success(decryptedBytes)
                        }
                    } catch (e: Exception) {
                        launch(Dispatchers.Main) {
                            result.error("DECRYPTION_ERROR", e.message, null)
                        }
                    }
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun processFrameInternal(frameData: FrameData) {
        try {
            val processingId = frameData.frameId
            
            val jpegBytes = convertYUV420ToJPEGInternal(frameData)
            val compressedBytes = compressImageInternal(jpegBytes, 426, 240, 80)
            
            val encryptJobs = connectedViewers.map { viewerId ->
                CompletableDeferred<Unit>().also { job ->
                    encryptionProcessor.execute {
                        try {
                            val aesKey = keyCache[viewerId]
                            if (aesKey != null && currentStreamId != null) {
                                val encryptedPayload = encryptFrameInternal(
                                    compressedBytes, aesKey, currentStreamId!!, frameData.timestamp.toInt(), processingId
                                )
                                
                                mainHandler.post {
                                    try {
                                        eventSink?.success(mapOf(
                                            "type" to "encrypted_frame",
                                            "viewerId" to viewerId,
                                            "data" to encryptedPayload,
                                            "timestamp" to frameData.timestamp,
                                            "frameId" to processingId
                                        ))
                                        
                                        framesSent++
                                    } catch (e: Exception) {
                                        Log.e("E2EE_ERROR", "Failed to send frame $processingId to $viewerId: $e")
                                    }
                                }
                            }
                            job.complete(Unit)
                        } catch (e: Exception) {
                            Log.e("E2EE_ERROR", "Encryption failed for frame $processingId, viewer $viewerId: $e")
                            job.complete(Unit)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("E2EE_ERROR", "Critical error processing frame ${frameData.frameId}: $e")
        }
    }

    private fun processFrame(call: MethodCall, result: Result) {
        if (!isStreaming || connectedViewers.isEmpty()) {
            result.success(false)
            return
        }

        val captureTimestamp = System.currentTimeMillis()
        val frameId = System.nanoTime()

        val frameData = FrameData(
            width = call.argument<Int>("width")!!,
            height = call.argument<Int>("height")!!,
            yPlane = call.argument<ByteArray>("yPlane")!!,
            uPlane = call.argument<ByteArray>("uPlane")!!,
            vPlane = call.argument<ByteArray>("vPlane")!!,
            yRowStride = call.argument<Int>("yRowStride") ?: call.argument<Int>("width")!!,
            uvRowStride = call.argument<Int>("uvRowStride") ?: call.argument<Int>("width")!!,
            uvPixelStride = call.argument<Int>("uvPixelStride") ?: 1,
            timestamp = captureTimestamp,
            frameId = frameId 
        )

        videoProcessor.execute {
            processFrameInternal(frameData)
        }

        result.success(true)
    }

    private fun encryptFrameInternal(frameBytes: ByteArray, aesKey: ByteArray, streamId: String, timestamp: Int, frameId: Long): ByteArray {
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)

        val safeTimestamp = timestamp and 0x7FFFFFFF
        val aad = "$streamId:$safeTimestamp".toByteArray(Charsets.UTF_8)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val keySpec = SecretKeySpec(aesKey, "AES")
        val gcmSpec = GCMParameterSpec(128, nonce)
        
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, gcmSpec)
        cipher.updateAAD(aad)

        val encrypted = cipher.doFinal(frameBytes)
        val payload = ByteArray(nonce.size + encrypted.size + 4 + 8)
        var offset = 0
        
        System.arraycopy(nonce, 0, payload, offset, nonce.size)
        offset += nonce.size
        
        System.arraycopy(encrypted, 0, payload, offset, encrypted.size)
        offset += encrypted.size
        
        val timestampBuffer = ByteBuffer.allocate(4)
        timestampBuffer.putInt(safeTimestamp)
        System.arraycopy(timestampBuffer.array(), 0, payload, offset, 4)
        offset += 4
        
        val frameIdBuffer = ByteBuffer.allocate(8)
        frameIdBuffer.putLong(frameId)
        System.arraycopy(frameIdBuffer.array(), 0, payload, offset, 8)

        return payload
    }

    private fun convertYUV420ToJPEGInternal(frameData: FrameData): ByteArray {
        val bitmap = Bitmap.createBitmap(frameData.width, frameData.height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(frameData.width * frameData.height)

        for (y in 0 until frameData.height) {
            val yRowOffset = y * frameData.yRowStride
            val uvRowOffset = (y / 2) * frameData.uvRowStride
            
            for (x in 0 until frameData.width) {
                val yIndex = yRowOffset + x
                val uvIndex = uvRowOffset + (x / 2) * frameData.uvPixelStride

                if (yIndex < frameData.yPlane.size && uvIndex < frameData.uPlane.size && uvIndex < frameData.vPlane.size) {
                    val yValue = (frameData.yPlane[yIndex].toInt() and 0xFF)
                    val uValue = (frameData.uPlane[uvIndex].toInt() and 0xFF) - 128
                    val vValue = (frameData.vPlane[uvIndex].toInt() and 0xFF) - 128

                    val r = ((yValue shl 10) + (1436 * vValue)) shr 10
                    val g = ((yValue shl 10) - (352 * uValue) - (731 * vValue)) shr 10
                    val b = ((yValue shl 10) + (1814 * uValue)) shr 10

                    pixels[y * frameData.width + x] = Color.rgb(
                        r.coerceIn(0, 255),
                        g.coerceIn(0, 255),
                        b.coerceIn(0, 255)
                    )
                }
            }
        }

        bitmap.setPixels(pixels, 0, frameData.width, 0, 0, frameData.width, frameData.height)

        val matrix = Matrix().apply { postRotate(-90f) }
        val rotatedBitmap = Bitmap.createBitmap(bitmap, 0, 0, frameData.width, frameData.height, matrix, true)

        val outputStream = ByteArrayOutputStream(frameData.width * frameData.height / 4)
        rotatedBitmap.compress(Bitmap.CompressFormat.JPEG, 80, outputStream)

        bitmap.recycle()
        rotatedBitmap.recycle()

        return outputStream.toByteArray()
    }

    private fun compressImageInternal(imageBytes: ByteArray, targetWidth: Int, targetHeight: Int, quality: Int): ByteArray {
        val options = BitmapFactory.Options().apply {
            inSampleSize = 1
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        
        val originalBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, options)
            ?: throw Exception("Failed to decode image bytes")

        val scaledBitmap = Bitmap.createScaledBitmap(originalBitmap, targetWidth, targetHeight, true)

        val outputStream = ByteArrayOutputStream(targetWidth * targetHeight / 2)
        scaledBitmap.compress(Bitmap.CompressFormat.JPEG, quality, outputStream)

        originalBitmap.recycle()
        scaledBitmap.recycle()

        return outputStream.toByteArray()
    }

    private fun startVideoStream(call: MethodCall, result: Result) {
        currentStreamId = call.argument<String>("streamId")!!
        val viewers = call.argument<List<String>>("viewers") ?: emptyList()
        
        connectedViewers.clear()
        connectedViewers.addAll(viewers)
        
        isStreaming = true
        
        Log.d("NativeVideoPlugin", "Started video stream for ${connectedViewers.size} viewers")
        result.success(true)
    }

    private fun stopVideoStream(result: Result) {
        isStreaming = false
        connectedViewers.clear()
        keyCache.clear()
        
        Log.d("NativeVideoPlugin", "Stopped video stream")
        result.success(true)
    }

    private fun addViewer(call: MethodCall, result: Result) {
        val viewerId = call.argument<String>("viewerId")!!
        val aesKey = call.argument<ByteArray>("aesKey")
        
        connectedViewers.add(viewerId)
        if (aesKey != null) {
            keyCache[viewerId] = aesKey
        }
        
        Log.d("NativeVideoPlugin", "Added viewer: $viewerId")
        result.success(true)
    }

    private fun removeViewer(call: MethodCall, result: Result) {
        val viewerId = call.argument<String>("viewerId")!!
        
        connectedViewers.remove(viewerId)
        keyCache.remove(viewerId)
        
        Log.d("NativeVideoPlugin", "Removed viewer: $viewerId")
        result.success(true)
    }

    private fun updateViewerKey(call: MethodCall, result: Result) {
        val viewerId = call.argument<String>("viewerId")!!
        val aesKey = call.argument<ByteArray>("aesKey")!!
        
        keyCache[viewerId] = aesKey
        
        Log.d("NativeVideoPlugin", "Updated key for viewer: $viewerId")
        result.success(true)
    }

    private fun setTargetFPS(fps: Int, result: Result) {
        targetFPS = fps.coerceIn(15, 60)
        Log.d("NativeVideoPlugin", "Target FPS set to: $targetFPS")
        result.success(true)
    }

    private fun startFpsMonitoring() {
        fpsMonitor.scheduleAtFixedRate({
            if (framesSent > 0) {
                totalFrames += framesSent
                fpsSamples++

                val avg = totalFrames.toDouble() / fpsSamples
                
                mainHandler.post {
                    try {
                        eventSink?.success(mapOf(
                            "type" to "fps_update",
                            "fps" to framesSent,
                            "timestamp" to System.currentTimeMillis()
                        ))
                    } catch (e: Exception) {
                        Log.e("NativeVideoPlugin", "Error sending FPS update", e)
                    }
                }
                
                framesSent = 0
            }
        }, 1, 1, TimeUnit.SECONDS)
    }

    private fun convertYUV420ToJPEG(call: MethodCall): ByteArray {
        val frameData = FrameData(
            width = call.argument<Int>("width")!!,
            height = call.argument<Int>("height")!!,
            yPlane = call.argument<ByteArray>("yPlane")!!,
            uPlane = call.argument<ByteArray>("uPlane")!!,
            vPlane = call.argument<ByteArray>("vPlane")!!,
            yRowStride = call.argument<Int>("yRowStride") ?: call.argument<Int>("width")!!,
            uvRowStride = call.argument<Int>("uvRowStride") ?: call.argument<Int>("width")!!,
            uvPixelStride = call.argument<Int>("uvPixelStride") ?: 1,
            timestamp = System.currentTimeMillis()
        )
        return convertYUV420ToJPEGInternal(frameData)
    }

    private fun compressImage(call: MethodCall): ByteArray {
        val imageBytes = call.argument<ByteArray>("imageBytes")!!
        val targetWidth = call.argument<Int>("targetWidth")!!
        val targetHeight = call.argument<Int>("targetHeight")!!
        val quality = call.argument<Int>("quality")!!
        return compressImageInternal(imageBytes, targetWidth, targetHeight, quality)
    }

    private fun encryptFrame(call: MethodCall): ByteArray {
        val frameBytes = call.argument<ByteArray>("frameBytes")!!
        val aesKey = call.argument<ByteArray>("aesKey")!!
        val streamId = call.argument<String>("streamId")!!
        val timestamp = call.argument<Int>("timestamp")!!
        val frameId = System.nanoTime()
        return encryptFrameInternal(frameBytes, aesKey, streamId, timestamp, frameId)
    }

    private fun decryptFrame(call: MethodCall): ByteArray {
        try {
            val encrypted = call.argument<ByteArray>("encrypted")!!
            val aesKey = call.argument<ByteArray>("aesKey")!!
            val nonce = call.argument<ByteArray>("nonce")!!
            val streamIdFromCall = call.argument<String>("streamId")!!
            val timestamp = call.argument<Int>("timestamp")!!

            if (encrypted.isEmpty()) throw IllegalArgumentException("Encrypted data is empty")
            if (aesKey.size != 32) throw IllegalArgumentException("Invalid AES key size: ${aesKey.size}")
            if (nonce.size != 12) throw IllegalArgumentException("Invalid nonce size: ${nonce.size}")

            val aad = "$streamIdFromCall:$timestamp".toByteArray(Charsets.UTF_8)

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val keySpec = SecretKeySpec(aesKey, "AES")
            val gcmSpec = GCMParameterSpec(128, nonce)
            
            cipher.init(Cipher.DECRYPT_MODE, keySpec, gcmSpec)
            cipher.updateAAD(aad)

            return cipher.doFinal(encrypted)
            
        } catch (e: Exception) {
            throw Exception("Decryption failed: ${e.message}", e)
        }
    }

    override fun onListen(arguments: Any?, events: EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        videoProcessor.shutdown()
        encryptionProcessor.shutdown()
        fpsMonitor.shutdown()
    }
}