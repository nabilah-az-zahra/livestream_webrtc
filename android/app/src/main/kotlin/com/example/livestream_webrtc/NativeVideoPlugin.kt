package com.example.livestream_webrtc

import android.content.Context
import android.graphics.*
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.EventChannel.StreamHandler
import java.io.ByteArrayOutputStream
import java.io.File
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.security.SecureRandom
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.Date
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
    private val frameInterval = 1000L / targetFPS 
    
    private val keyCache = ConcurrentHashMap<String, ByteArray>()
    private var currentStreamId: String? = null
    private var connectedViewers = mutableSetOf<String>()
    
    private var framesSent = 0
    private var lastFpsUpdate = 0L
    private val fpsMonitor = Executors.newSingleThreadScheduledExecutor()
    
    private val frameQueue = mutableListOf<FrameData>()
    private val maxQueueSize = 3 

    private var totalFrames = 0
    private var fpsSamples = 0

    private lateinit var sessionLogFile: File
    private lateinit var latencyLogFile: File
    private val latencyTestEnabled = true
    private var frameCounter = 0

    private var entropyTestEnabled = true
    private lateinit var entropyDir: File
    private var entropyFrameCounter = 0
    private val maxEntropyFrames = 100
    
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

        initializeLogFile(flutterPluginBinding.applicationContext)
        initializeLatencyLogFile(flutterPluginBinding.applicationContext)
        initializeEntropyTesting(flutterPluginBinding.applicationContext)
        
        Log.d("NativeVideoPlugin", "Enhanced plugin attached to engine")
        startFpsMonitoring()
    }

    private fun initializeEntropyTesting(context: Context) {
        if (!entropyTestEnabled) return
        
        val targetDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        entropyDir = File(targetDir, "ciphertext")
        
        if (entropyDir.exists()) {
            // Clean existing files
            entropyDir.listFiles()?.forEach { it.delete() }
        } else {
            entropyDir.mkdirs()
        }
        
        Log.d("EntropyTest", "Entropy testing directory: ${entropyDir.absolutePath}")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        Log.d("NativeVideoPlugin", "Method called: ${call.method}")
        
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
            "recordFrameRendered" -> {
                recordFrameRendered(call, result)
            }
            "getLatencyStats" -> {
                getLatencyStats(result)
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
            "startEntropyTest" -> {
                startEntropyTest(result)
            }
            "stopEntropyTest" -> {
                stopEntropyTest(result)
            }
            "getEntropyTestStats" -> {
                getEntropyTestStats(result)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun processFrameInternal(frameData: FrameData) {
        try {
            val processingId = frameData.frameId
            val startTime = System.currentTimeMillis()
            
            Log.d("TIMING", "Frame $processingId: ===== STARTING PROCESSING =====")
            Log.d("TIMING", "Frame $processingId: Start time: $startTime")
            
            // YUV to JPEG conversion
            val convertStartTime = System.currentTimeMillis()
            val jpegBytes = convertYUV420ToJPEGInternal(frameData)
            val convertEndTime = System.currentTimeMillis()
            val convertDuration = convertEndTime - convertStartTime
            
            Log.d("TIMING", "Frame $processingId: Conversion done in ${convertDuration}ms (${jpegBytes.size} bytes)")
            
            if (latencyTestEnabled) {
                logLatencyEvent("conversion_complete", processingId, convertEndTime, convertDuration.toDouble())
            }
            
            // Image compression
            val compressStartTime = System.currentTimeMillis()
            val compressedBytes = compressImageInternal(jpegBytes, 426, 240, 80)
            val compressEndTime = System.currentTimeMillis()
            val compressDuration = compressEndTime - compressStartTime
            
            Log.d("TIMING", "Frame $processingId: Compression done in ${compressDuration}ms (${compressedBytes.size} bytes)")
            
            if (latencyTestEnabled) {
                logLatencyEvent("compression_complete", processingId, compressEndTime, compressDuration.toDouble())
            }
            
            Log.d("TIMING", "Frame $processingId: Processing ${connectedViewers.size} viewers...")
            
            val encryptJobs = connectedViewers.map { viewerId ->
                CompletableDeferred<Unit>().also { job ->
                    encryptionProcessor.execute {
                        try {
                            val aesKey = keyCache[viewerId]
                            if (aesKey != null && currentStreamId != null) {
                                val encryptStartTime = System.currentTimeMillis()
                                val encryptedPayload = encryptFrameInternalWithLatency(
                                    compressedBytes, aesKey, currentStreamId!!, frameData.timestamp.toInt(), processingId
                                )
                                val encryptEndTime = System.currentTimeMillis()
                                val encryptDuration = encryptEndTime - encryptStartTime
                                
                                Log.d("TIMING", "Frame $processingId: Encryption for $viewerId done in ${encryptDuration}ms (${encryptedPayload.size} bytes)")
                                
                                if (latencyTestEnabled) {
                                    logLatencyEvent("encryption_complete", processingId, encryptEndTime, encryptDuration.toDouble())
                                }
                                
                                mainHandler.post {
                                    try {
                                        val sendStartTime = System.currentTimeMillis()
                                        
                                        eventSink?.success(mapOf(
                                            "type" to "encrypted_frame",
                                            "viewerId" to viewerId,
                                            "data" to encryptedPayload,
                                            "timestamp" to frameData.timestamp,
                                            "frameId" to processingId
                                        ))
                                        
                                        val sendEndTime = System.currentTimeMillis()
                                        val totalProcessingTime = sendEndTime - startTime
                                        val eventSinkTime = sendEndTime - sendStartTime
                                        
                                        Log.d("TIMING", "Frame $processingId: EventSink call took ${eventSinkTime}ms")
                                        Log.d("TIMING", "Frame $processingId: ===== TOTAL NATIVE PROCESSING: ${totalProcessingTime}ms =====")
                                        
                                        if (latencyTestEnabled) {
                                            logLatencyEvent("frame_sent", processingId, sendEndTime, null)
                                            Log.d("LatencyTest", "STREAMER: Frame sent with ID=$processingId at timestamp=$sendEndTime")
                                        }
                                        
                                        framesSent++
                                    } catch (e: Exception) {
                                        Log.e("TIMING", "Frame $processingId: Error sending frame event for viewer $viewerId: $e")
                                    }
                                }
                            } else {
                                Log.w("TIMING", "Frame $processingId: No AES key for viewer $viewerId")
                            }
                            job.complete(Unit)
                        } catch (e: Exception) {
                            Log.e("TIMING", "Frame $processingId: Error processing frame for viewer $viewerId: $e")
                            job.complete(Unit)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("TIMING", "Frame ${frameData.frameId}: Critical error in frame processing: $e")
        }
    }

    private fun processFrame(call: MethodCall, result: Result) {
        if (!isStreaming || connectedViewers.isEmpty()) {
            result.success(false)
            return
        }

        val captureTimestamp = System.currentTimeMillis()
        val frameId = generateConsistentFrameId()
        frameCounter++

        if (latencyTestEnabled) {
            logLatencyEvent("frame_captured", frameId, captureTimestamp, null)
            Log.d("LatencyTest", "STREAMER: Frame captured with ID=$frameId at timestamp=$captureTimestamp")
        }

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

    private fun encryptFrameInternalWithLatency(frameBytes: ByteArray, aesKey: ByteArray, streamId: String, timestamp: Int, frameId: Long): ByteArray {
        val startTime = System.nanoTime()

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

        saveEncryptedFrameForEntropy(encrypted, frameId)
        
        val durationMs = (System.nanoTime() - startTime) / 1_000_000.0
        logTimingToLocalFile("encrypt", streamId, frameBytes.size, durationMs, true)
        
        Log.d("LatencyTest", "Encrypted frame with ID=$frameId, payload size=${payload.size}")
        Log.d("LatencyTest", "Payload structure: nonce(${nonce.size}) + encrypted(${encrypted.size}) + timestamp(4) + frameId(8)")

        return payload
    }

    private fun saveEncryptedFrameForEntropy(encrypted: ByteArray, frameId: Long) {
        if (!entropyTestEnabled || entropyFrameCounter >= maxEntropyFrames) return
        
        try {
            val filename = "frame_${String.format("%06d", entropyFrameCounter)}.bin"
            val file = File(entropyDir, filename)
            
            file.writeBytes(encrypted) // Save ONLY the encrypted content
            entropyFrameCounter++
            
            Log.d("EntropyTest", "Saved encrypted frame $entropyFrameCounter: ${encrypted.size} bytes -> $filename")
            
            if (entropyFrameCounter >= maxEntropyFrames) {
                Log.i("EntropyTest", "Reached max entropy frames limit ($maxEntropyFrames)")
            }
            
        } catch (e: Exception) {
            Log.e("EntropyTest", "Failed to save entropy frame: ${e.message}")
        }
    }

    fun setEntropyTesting(enabled: Boolean) {
        entropyTestEnabled = enabled
        Log.d("EntropyTest", "Entropy testing: ${if (enabled) "enabled" else "disabled"}")
    }

    private fun recordFrameRendered(call: MethodCall, result: Result) {
        if (!latencyTestEnabled) {
            result.success(false)
            return
        }

        val frameId = call.argument<Long>("frameId")!!
        val renderTimestamp = System.currentTimeMillis()
        
        logLatencyEvent("frame_rendered", frameId, renderTimestamp, null)
        
        result.success(true)
    }

    private fun getLatencyStats(result: Result) {
        try {
            Log.d("LatencyTest", "Starting latency stats analysis...")
            
            val stats = mutableMapOf<String, Any>()
            
            if (::latencyLogFile.isInitialized && latencyLogFile.exists()) {
                val lines = latencyLogFile.readLines()
                Log.d("LatencyTest", "Reading ${lines.size} lines from: ${latencyLogFile.absolutePath}")
                
                if (lines.size <= 1) {
                    Log.w("LatencyTest", "CSV file only has header, no data yet")
                    stats["error"] = "No data in CSV file yet"
                    result.success(stats)
                    return
                }
                
                val frameLatencies = mutableListOf<Double>()
                val frameEvents = mutableMapOf<String, MutableMap<String, Long>>()
                
                var lineNumber = 0
                var parseErrors = 0
                
                lines.drop(1).forEach { line ->
                    lineNumber++
                    val parts = line.split(',')
                    
                    if (parts.size >= 5) { 
                        try {
                            val eventType = parts[1].trim()
                            val frameIdStr = parts[2].trim()
                            val eventTimeStr = parts[3].trim()
                            
                            val eventTime = eventTimeStr.toLongOrNull()
                            
                            if (eventTime != null && frameIdStr.isNotEmpty()) {
                                frameEvents.getOrPut(frameIdStr) { mutableMapOf() }[eventType] = eventTime
                                
                                Log.v("LatencyTest", "Line $lineNumber: $eventType for frame $frameIdStr at $eventTime")
                            } else {
                                Log.w("LatencyTest", "Invalid data on line $lineNumber: eventTime=$eventTimeStr, frameId=$frameIdStr")
                                parseErrors++
                            }
                        } catch (e: Exception) {
                            Log.w("LatencyTest", "Parse error on line $lineNumber: $e - Line: $line")
                            parseErrors++
                        }
                    } else {
                        Log.w("LatencyTest", "Invalid line format on line $lineNumber (${parts.size} parts): $line")
                        parseErrors++
                    }
                }
                
                Log.d("LatencyTest", "Parsed ${frameEvents.size} unique frames, $parseErrors parse errors")
                
                var captureCount = 0
                var sentCount = 0
                var renderedCount = 0
                
                frameEvents.values.forEach { events ->
                    if (events.containsKey("frame_captured")) captureCount++
                    if (events.containsKey("frame_sent")) sentCount++
                    if (events.containsKey("frame_rendered")) renderedCount++
                }
                
                Log.d("LatencyTest", "Event counts - Captures: $captureCount, Sent: $sentCount, Rendered: $renderedCount")
                
                var validLatencies = 0
                var invalidLatencies = 0
                
                frameEvents.forEach { (frameIdStr, events) ->
                    val captureTime = events["frame_captured"]
                    val renderTime = events["frame_rendered"]
                    
                    if (captureTime != null && renderTime != null) {
                        val latency = (renderTime - captureTime).toDouble()
                        if (latency > 0 && latency < 10000) {
                            frameLatencies.add(latency)
                            validLatencies++
                            Log.v("LatencyTest", "Valid latency for frame $frameIdStr: ${String.format("%.2f", latency)}ms (capture: $captureTime, render: $renderTime)")
                        } else {
                            invalidLatencies++
                            Log.w("LatencyTest", "Invalid latency for frame $frameIdStr: ${latency}ms (capture: $captureTime, render: $renderTime)")
                        }
                    } else {
                        Log.v("LatencyTest", "Missing events for frame $frameIdStr: capture=$captureTime, render=$renderTime")
                    }
                }
                
                Log.d("LatencyTest", "Latency calculation results:")
                Log.d("LatencyTest", " - Valid latencies: $validLatencies")
                Log.d("LatencyTest", " - Invalid latencies: $invalidLatencies")
                Log.d("LatencyTest", " - Total frames: ${frameEvents.size}")
                
                if (frameLatencies.isNotEmpty()) {
                    frameLatencies.sort()
                    
                    val average = frameLatencies.average()
                    val median = frameLatencies[frameLatencies.size / 2]
                    val min = frameLatencies.minOrNull() ?: 0.0
                    val max = frameLatencies.maxOrNull() ?: 0.0
                    val p95 = frameLatencies[(frameLatencies.size * 0.95).toInt().coerceAtMost(frameLatencies.size - 1)]
                    val p99 = frameLatencies[(frameLatencies.size * 0.99).toInt().coerceAtMost(frameLatencies.size - 1)]
                    
                    stats["totalFramesTested"] = frameLatencies.size
                    stats["averageLatencyMs"] = average
                    stats["medianLatencyMs"] = median
                    stats["minLatencyMs"] = min
                    stats["maxLatencyMs"] = max
                    stats["p95LatencyMs"] = p95
                    stats["p99LatencyMs"] = p99
                    stats["captureCount"] = captureCount
                    stats["sentCount"] = sentCount
                    stats["renderedCount"] = renderedCount
                    stats["parseErrors"] = parseErrors
                    
                    Log.d("LatencyTest", "Successfully analyzed ${frameLatencies.size} complete frame journeys")
                    Log.d("LatencyTest", "Stats Summary:")
                    Log.d("LatencyTest", " - Average: ${String.format("%.2f", average)}ms")
                    Log.d("LatencyTest", " - Median: ${String.format("%.2f", median)}ms")
                    Log.d("LatencyTest", " - Min: ${String.format("%.2f", min)}ms")
                    Log.d("LatencyTest", " - Max: ${String.format("%.2f", max)}ms")
                    Log.d("LatencyTest", " - 95th percentile: ${String.format("%.2f", p95)}ms")
                    Log.d("LatencyTest", " - 99th percentile: ${String.format("%.2f", p99)}ms")
                    
                } else {
                    Log.w("LatencyTest", "No valid latencies found!")
                    stats["error"] = "No valid frame pairs found"
                    stats["captureCount"] = captureCount
                    stats["sentCount"] = sentCount
                    stats["renderedCount"] = renderedCount
                    stats["totalFrames"] = frameEvents.size
                    stats["parseErrors"] = parseErrors
                }
                
            } else {
                Log.e("LatencyTest", "Latency log file not available")
                if (::latencyLogFile.isInitialized) {
                    Log.e("LatencyTest", "File path: ${latencyLogFile.absolutePath}, exists: ${latencyLogFile.exists()}")
                }
                stats["error"] = "Latency log file not available"
            }
            
            result.success(stats)
        } catch (e: Exception) {
            Log.e("LatencyTest", "Error calculating latency stats: $e", e)
            result.error("LATENCY_STATS_ERROR", e.message, null)
        }
    }

    private fun initializeLatencyLogFile(context: Context) {
        val targetDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        if (targetDir != null && !targetDir.exists()) {
            targetDir.mkdirs()
        }

        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss").format(Date())
        val fileName = "e2ee_latency_test_$timestamp.csv"
        latencyLogFile = File(targetDir, fileName)

        try {
            latencyLogFile.writeText("timestamp,event_type,frame_id,event_time,duration_ms\n")
            Log.d("LatencyTest", "Latency CSV initialized: ${latencyLogFile.absolutePath}")
        } catch (e: Exception) {
            Log.e("LatencyTest", "Failed to initialize latency CSV: ${e.message}")
        }
    }

    private fun logLatencyEvent(eventType: String, frameId: Long, eventTime: Long, duration: Double?) {
        if (!latencyTestEnabled || !::latencyLogFile.isInitialized) return
        
        val timestamp = System.currentTimeMillis()
        val frameIdStr = frameId.toString()
        
        val durationStr = when {
            eventType in listOf("frame_captured", "frame_sent", "frame_rendered") -> "" 
            duration != null -> String.format(java.util.Locale.US, "%.2f", duration)
            else -> ""
        }
        
        val logLine = "$timestamp,$eventType,$frameIdStr,$eventTime,$durationStr\n"
        
        try {
            latencyLogFile.appendText(logLine)
            
            when (eventType) {
                "frame_captured" -> {
                    Log.d("LatencyTest", "Frame captured: ID=$frameIdStr at $eventTime")
                }
                "frame_sent" -> {
                    Log.d("LatencyTest", "Frame sent: ID=$frameIdStr at $eventTime") 
                }
                "frame_rendered" -> {
                    Log.d("LatencyTest", "Frame rendered: ID=$frameIdStr at $eventTime")
                }
                else -> Log.d("LatencyTest", "$eventType: frame $frameIdStr, duration: ${durationStr}ms")
            }
        } catch (e: Exception) {
            Log.e("LatencyTest", "Failed to write latency event: ${e.message}")
        }
    }

    private fun generateConsistentFrameId(): Long {
        return System.currentTimeMillis() * 1000 + (System.nanoTime() % 1000000) / 1000
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

    private fun encryptFrameInternal(frameBytes: ByteArray, aesKey: ByteArray, streamId: String, timestamp: Int): ByteArray {
        val startTime = System.nanoTime()
        val frameId = System.nanoTime() 

        try {
            if (frameBytes.isEmpty()) {
                throw IllegalArgumentException("Frame bytes are empty")
            }
            if (aesKey.size != 32) {
                throw IllegalArgumentException("Invalid AES key size: ${aesKey.size}, expected 32")
            }

            val nonce = ByteArray(12)
            SecureRandom().nextBytes(nonce)
            Log.d("ENCRYPT_DEBUG", "Generated nonce: ${nonce.joinToString(",")}")

            val safeTimestamp = timestamp and 0x7FFFFFFF 
            val aad = "$streamId:$safeTimestamp".toByteArray(Charsets.UTF_8)
            Log.d("ENCRYPT_DEBUG", "AAD: $streamId:$safeTimestamp -> ${aad.joinToString(",")}")

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val keySpec = SecretKeySpec(aesKey, "AES")
            val gcmSpec = GCMParameterSpec(128, nonce) 
            
            cipher.init(Cipher.ENCRYPT_MODE, keySpec, gcmSpec)
            cipher.updateAAD(aad)

            val encrypted = cipher.doFinal(frameBytes)
            Log.d("ENCRYPT_DEBUG", "Encrypted ${frameBytes.size} -> ${encrypted.size} bytes")
            
            val payload = ByteArray(nonce.size + encrypted.size + 4 + 8)
            
            var offset = 0
            System.arraycopy(nonce, 0, payload, offset, nonce.size)
            offset += nonce.size
            
            System.arraycopy(encrypted, 0, payload, offset, encrypted.size)
            offset += encrypted.size
            
            ByteBuffer.wrap(payload, offset, 4).putInt(safeTimestamp)
            offset += 4
            
            ByteBuffer.wrap(payload, offset, 8).putLong(frameId)

            val durationMs = (System.nanoTime() - startTime) / 1_000_000.0
            Log.d("ENCRYPT_DEBUG", "Encryption successful in ${"%.2f".format(durationMs)}ms")
            
            logTimingToLocalFile("encrypt", streamId, frameBytes.size, durationMs, true)

            return payload
            
        } catch (e: Exception) {
            val durationMs = (System.nanoTime() - startTime) / 1_000_000.0
            Log.e("ENCRYPT_ERROR", "Encryption failed: ${e.message}", e)
            
            logTimingToLocalFile("encrypt", streamId, frameBytes.size, durationMs, false, e.message)
            throw Exception("Encryption failed: ${e.message}", e)
        }
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
        
        synchronized(frameQueue) {
            frameQueue.clear()
        }
        
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
                Log.d("NativeVideoPlugin", "Native FPS: $framesSent frames/sec")
                totalFrames += framesSent
                fpsSamples++

                val avg = totalFrames.toDouble() / fpsSamples
                Log.d("NativeVideoPlugin", "Average FPS: ${"%.2f".format(avg)}")
                
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
        return encryptFrameInternal(frameBytes, aesKey, streamId, timestamp)
    }

    private fun decryptFrame(call: MethodCall): ByteArray {
        val decryptStartTime = System.nanoTime()
        
        try {
            val encrypted = call.argument<ByteArray>("encrypted")!!
            val aesKey = call.argument<ByteArray>("aesKey")!!
            val nonce = call.argument<ByteArray>("nonce")!!
            val streamIdFromCall = call.argument<String>("streamId")!!
            val timestamp = call.argument<Int>("timestamp")!!
            val frameId = call.argument<Long>("frameId") 
            
            Log.d("DECRYPT_DEBUG", "Input parameters:")
            Log.d("DECRYPT_DEBUG", "  - encrypted.size: ${encrypted.size}")
            Log.d("DECRYPT_DEBUG", "  - aesKey.size: ${aesKey.size}")
            Log.d("DECRYPT_DEBUG", "  - nonce.size: ${nonce.size}")
            Log.d("DECRYPT_DEBUG", "  - streamId: $streamIdFromCall")
            Log.d("DECRYPT_DEBUG", "  - timestamp: $timestamp")
            Log.d("DECRYPT_DEBUG", "  - frameId: $frameId")

            if (encrypted.isEmpty()) {
                throw IllegalArgumentException("Encrypted data is empty")
            }
            if (aesKey.size != 32) {
                throw IllegalArgumentException("Invalid AES key size: ${aesKey.size}, expected 32")
            }
            if (nonce.size != 12) {
                throw IllegalArgumentException("Invalid nonce size: ${nonce.size}, expected 12")
            }

            val aad = "$streamIdFromCall:$timestamp".toByteArray(Charsets.UTF_8)
            Log.d("DECRYPT_DEBUG", "AAD built:")
            Log.d("DECRYPT_DEBUG", "  - string: $streamIdFromCall:$timestamp")
            Log.d("DECRYPT_DEBUG", "  - bytes: ${aad.joinToString(",")}")

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val keySpec = SecretKeySpec(aesKey, "AES")
            val gcmSpec = GCMParameterSpec(128, nonce) 
            
            Log.d("DECRYPT_DEBUG", "Initializing cipher for decryption...")
            cipher.init(Cipher.DECRYPT_MODE, keySpec, gcmSpec)
            cipher.updateAAD(aad)

            Log.d("DECRYPT_DEBUG", "Starting decryption of ${encrypted.size} bytes...")
            val decrypted = cipher.doFinal(encrypted)
            
            val durationMs = (System.nanoTime() - decryptStartTime) / 1_000_000.0
            Log.d("DECRYPT_DEBUG", "Decryption successful!")
            Log.d("DECRYPT_DEBUG", "  - decrypted.size: ${decrypted.size}")
            Log.d("DECRYPT_DEBUG", "  - duration: ${"%.2f".format(durationMs)}ms")
            
            logTimingToLocalFile("decrypt", streamIdFromCall, encrypted.size, durationMs, true)

            if (latencyTestEnabled && frameId != null) {
                logLatencyEvent("decryption_complete", frameId, System.currentTimeMillis(), durationMs)
            }

            return decrypted
            
        } catch (e: Exception) {
            val durationMs = (System.nanoTime() - decryptStartTime) / 1_000_000.0
            
            Log.e("DECRYPT_ERROR", "Decryption failed after ${"%.2f".format(durationMs)}ms")
            Log.e("DECRYPT_ERROR", "Error type: ${e.javaClass.simpleName}")
            Log.e("DECRYPT_ERROR", "Error message: ${e.message}")
            Log.e("DECRYPT_ERROR", "Stack trace:", e)
            
            val streamId = call.argument<String>("streamId") ?: "unknown"
            val encryptedSize = call.argument<ByteArray>("encrypted")?.size ?: 0
            val keySize = call.argument<ByteArray>("aesKey")?.size ?: 0
            val nonceSize = call.argument<ByteArray>("nonce")?.size ?: 0
            val frameId = call.argument<Long>("frameId")
            
            Log.e("DECRYPT_ERROR", "Context:")
            Log.e("DECRYPT_ERROR", "  - streamId: $streamId")
            Log.e("DECRYPT_ERROR", "  - encryptedSize: $encryptedSize")
            Log.e("DECRYPT_ERROR", "  - keySize: $keySize")
            Log.e("DECRYPT_ERROR", "  - nonceSize: $nonceSize")
            Log.e("DECRYPT_ERROR", "  - frameId: $frameId")
            
            logTimingToLocalFile("decrypt", streamId, encryptedSize, durationMs, false, e.message)
            
            throw Exception("Decryption failed: ${e.message}", e)
        }
    }

    override fun onListen(arguments: Any?, events: EventSink?) {
        Log.d("NativeVideoPlugin", "Event channel listener attached")
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        Log.d("NativeVideoPlugin", "Event channel listener cancelled")
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        videoProcessor.shutdown()
        encryptionProcessor.shutdown()
        fpsMonitor.shutdown()
        
        Log.d("NativeVideoPlugin", "Enhanced plugin detached from engine")
    }

    private fun initializeLogFile(context: Context) {
        val targetDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        if (targetDir != null && !targetDir.exists()) {
            targetDir.mkdirs()
        }

        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss").format(Date())
        val fileName = "e2ee_timelogs_$timestamp.csv"
        sessionLogFile = File(targetDir, fileName)

        try {
            sessionLogFile.writeText("timestamp,operation,streamId,frameSize,durationMs,success,error\n")
            Log.d("CSVDebug", "CSV initialized with 7-field header")
        } catch (e: Exception) {
            Log.e("PerfLog", "Failed to initialize CSV: ${e.message}")
        }
    }

    private fun logTimingToLocalFile(
        operation: String,
        streamId: String, 
        frameSize: Int,
        durationMs: Double,
        success: Boolean = true,
        error: String? = null
    ) {
        val timestamp = System.currentTimeMillis()
        val successStr = if (success) "true" else "false"
        val errorStr = error ?: ""
        
        val durationFormatted = String.format(java.util.Locale.US, "%.2f", durationMs)
        
        val logLine = "$timestamp,$operation,$streamId,$frameSize,$durationFormatted,$successStr,$errorStr\n"
        
        Log.d("CSVDebug", "Writing: $logLine")
        Log.d("CSVDebug", "Fields: ${logLine.trim().split(',').size}")
        Log.d("CSVDebug", "Duration: $durationMs -> $durationFormatted")
        
        try {
            sessionLogFile.appendText(logLine)
        } catch (e: Exception) {
            Log.e("PerfLog", "Failed to write: ${e.message}")
        }
    }

    private fun debugLatencyTracking() {
        if (!::latencyLogFile.isInitialized) {
            Log.e("LatencyTest", "Latency log file not initialized!")
            return
        }
        
        try {
            if (!latencyLogFile.exists()) {
                Log.e("LatencyTest", "Latency log file doesn't exist: ${latencyLogFile.absolutePath}")
                return
            }
            
            val lines = latencyLogFile.readLines()
            Log.d("LatencyTest", "Latency log file has ${lines.size} lines")
            
            if (lines.size > 1) {
                val captureEvents = lines.drop(1).count { it.contains("frame_captured") }
                val sentEvents = lines.drop(1).count { it.contains("frame_sent") }
                val renderedEvents = lines.drop(1).count { it.contains("frame_rendered") }
                
                Log.d("LatencyTest", "Frame captured events: $captureEvents")
                Log.d("LatencyTest", "Frame sent events: $sentEvents")
                Log.d("LatencyTest", "Frame rendered events: $renderedEvents")
                
                val recentLines = lines.takeLast(5)
                Log.d("LatencyTest", "Recent events:")
                recentLines.forEach { line ->
                    Log.d("LatencyTest", "  $line")
                }
            } else {
                Log.w("LatencyTest", "No events recorded yet (only header)")
            }
        } catch (e: Exception) {
            Log.e("LatencyTest", "Error reading latency log: ${e.message}")
        }
    }

    private fun debugCsvContent(result: Result) {
        try {
            if (!::latencyLogFile.isInitialized || !latencyLogFile.exists()) {
                result.error("FILE_NOT_FOUND", "CSV file not found", null)
                return
            }
            
            val lines = latencyLogFile.readLines()
            val debugInfo = mutableMapOf<String, Any>()
            
            debugInfo["filePath"] = latencyLogFile.absolutePath
            debugInfo["totalLines"] = lines.size
            debugInfo["fileSize"] = latencyLogFile.length()
            
            if (lines.isNotEmpty()) {
                debugInfo["header"] = lines.first()
                
                if (lines.size > 1) {
                    debugInfo["firstDataLine"] = lines[1]
                    debugInfo["lastDataLine"] = lines.last()
                    
                    val recentLines = lines.takeLast(50)
                    val eventCounts = mutableMapOf<String, Int>()
                    
                    recentLines.forEach { line ->
                        val parts = line.split(',')
                        if (parts.size >= 2) {
                            val eventType = parts[1].trim()
                            eventCounts[eventType] = eventCounts.getOrDefault(eventType, 0) + 1
                        }
                    }
                    
                    debugInfo["recentEventCounts"] = eventCounts
                    debugInfo["sampleLines"] = recentLines.takeLast(5)
                }
            }
            
            Log.d("LatencyTest", "CSV Debug Info: $debugInfo")
            result.success(debugInfo)
            
        } catch (e: Exception) {
            Log.e("LatencyTest", "Error debugging CSV: $e")
            result.error("DEBUG_ERROR", e.message, null)
        }
    }

    private fun startEntropyTest(result: Result) {
        try {
            entropyTestEnabled = true
            entropyFrameCounter = 0
            
            // Clean existing files
            if (::entropyDir.isInitialized && entropyDir.exists()) {
                entropyDir.listFiles()?.forEach { it.delete() }
            }
            
            Log.d("EntropyTest", "Entropy test started - will collect up to $maxEntropyFrames frames")
            result.success(true)
        } catch (e: Exception) {
            Log.e("EntropyTest", "Failed to start entropy test: $e")
            result.success(false)
        }
    }

    private fun stopEntropyTest(result: Result) {
        try {
            entropyTestEnabled = false
            
            val stats = mapOf(
                "framesCollected" to entropyFrameCounter,
                "maxFrames" to maxEntropyFrames,
                "outputDir" to if (::entropyDir.isInitialized) entropyDir.absolutePath else "not initialized"
            )
            
            Log.d("EntropyTest", "Entropy test stopped - collected $entropyFrameCounter frames")
            result.success(stats)
        } catch (e: Exception) {
            Log.e("EntropyTest", "Failed to stop entropy test: $e")
            result.success(false)
        }
    }

    private fun getEntropyTestStats(result: Result) {
        try {
            val stats = mutableMapOf<String, Any>()
            stats["enabled"] = entropyTestEnabled
            stats["framesCollected"] = entropyFrameCounter
            stats["maxFrames"] = maxEntropyFrames
            
            if (::entropyDir.isInitialized && entropyDir.exists()) {
                stats["outputDir"] = entropyDir.absolutePath
                val files = entropyDir.listFiles()?.filter { it.name.endsWith(".bin") } ?: emptyList()
                stats["filesOnDisk"] = files.size
                stats["totalBytes"] = files.sumOf { it.length() }
            } else {
                stats["outputDir"] = "not initialized"
                stats["filesOnDisk"] = 0
                stats["totalBytes"] = 0L
            }
            
            result.success(stats)
        } catch (e: Exception) {
            Log.e("EntropyTest", "Failed to get entropy stats: $e")
            result.error("ENTROPY_STATS_ERROR", e.message, null)
        }
    }
}