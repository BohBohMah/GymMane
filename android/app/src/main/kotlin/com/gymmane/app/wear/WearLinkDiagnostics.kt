package com.gymmane.app.wear

import android.content.Context
import android.util.Log
import com.gymmane.app.BuildConfig
import com.gymmane.wear.protocol.WearJson
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Metadata-only tracing for isolated device-test APKs. Kept disabled in
 * production builds; never logs workout values, names, PINs, addresses or data.
 */
internal object WearLinkDiagnostics {
    private const val TAG = "GymManeWearLink"
    private const val FILE_NAME = "wearlink-diagnostics.log"
    private const val MAX_BYTES = 128 * 1024
    private const val RETAIN_BYTES = 64 * 1024
    private val lock = Any()
    @Volatile private var logFile: File? = null

    fun initialize(context: Context) {
        if (BuildConfig.GYMMANE_WEAR_DIAGNOSTICS) {
            logFile = File(context.applicationContext.filesDir, FILE_NAME)
            log("diagnostics initialized")
        }
    }

    fun log(message: String) {
        if (!BuildConfig.GYMMANE_WEAR_DIAGNOSTICS) return
        val safeMessage = message
            .replace(Regex("[\\r\\n\\t]+"), " ")
            .take(320)
        Log.i(TAG, safeMessage)
        val file = logFile ?: return
        val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
        val line = "$timestamp $safeMessage\n".toByteArray(StandardCharsets.UTF_8)
        synchronized(lock) {
            runCatching {
                if (file.exists() && file.length() + line.size > MAX_BYTES) {
                    val old = file.readBytes()
                    val start = (old.size - RETAIN_BYTES).coerceAtLeast(0)
                    var newline = -1
                    for (index in start until old.size) {
                        if (old[index] == '\n'.code.toByte()) {
                            newline = index
                            break
                        }
                    }
                    val retained = old.copyOfRange(
                        if (newline >= 0) newline + 1 else start,
                        old.size,
                    )
                    file.writeBytes(retained)
                }
                FileOutputStream(file, true).use { it.write(line) }
            }.onFailure {
                Log.w(TAG, "diagnostics file append failed type=${it.javaClass.simpleName}")
            }
        }
    }

    fun snapshotSummary(json: String): String {
        val data = runCatching { WearJson.toMap(WearJson.parse(json)) }.getOrNull()
            ?: return "snapshot parse=failed bytes=${json.length}"
        return snapshotSummary(data) + " bytes=${json.length}"
    }

    fun snapshotSummary(data: Map<String, Any?>): String {
        val status = data["status"] as? String ?: "unknown"
        val workoutId = data["workoutId"] as? String
        val hasWorkout = !workoutId.isNullOrEmpty() && status != "idle"
        val exerciseCount = (data["exercises"] as? List<*>)?.size ?: 0
        return "rev=${data["rev"]} status=$status hasWorkout=$hasWorkout exercises=$exerciseCount"
    }

    fun snapshotSummary(data: JsonObject): String = snapshotSummary(WearJson.toMap(data))
}
