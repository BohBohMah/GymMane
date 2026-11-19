package com.gymmane.app.wear

import android.content.Context
import android.os.Build
import com.gymmane.wear.protocol.WearCrypto
import com.gymmane.wear.protocol.WearJson
import kotlinx.serialization.json.buildJsonObject
import java.util.UUID
import java.security.SecureRandom

object WearUuids {
    val SERVICE = UUID.fromString("6f2a1f3c-7d4b-4a6e-9d0c-2b3a4c5d6e7f")
    val RX = UUID.fromString("6f2a1f3c-7d4b-4a6e-9d0c-2b3a4c5d6e80")
    val TX = UUID.fromString("6f2a1f3c-7d4b-4a6e-9d0c-2b3a4c5d6e81")
}

class WearPrefs(context: Context) {
    private val app = context.applicationContext
    private val phone = app.getSharedPreferences("gymmane_wear_phone", Context.MODE_PRIVATE)
    private val watch = app.getSharedPreferences("gymmane_wear_watch", Context.MODE_PRIVATE)

    var serverEnabled: Boolean
        get() = phone.getBoolean("enabled", false)
        set(value) = phone.edit().putBoolean("enabled", value).apply()

    val pairingUntil: Long get() = pairingDeadline
    val pairingPin: String get() = currentPin

    var lastWatchName: String
        get() = phone.getString("lastWatchName", "") ?: ""
        set(value) = phone.edit().putString("lastWatchName", value).apply()

    fun pskFor(watchId: String): ByteArray? {
        val encoded = watchKey(watchId) ?: return null
        return WearCrypto.fromB64(encoded)
    }

    fun savePsk(watchId: String, name: String, psk: ByteArray) {
        val current = keys()
        current[watchId] = WearCrypto.b64(psk)
        val json = buildJsonObject {
            for ((key, value) in current) put(key, WearJson.text(value))
        }
        phone.edit()
            .putString("keys", json.toString())
            .putString("lastWatchName", name)
            .apply()
    }

    fun keyCount(): Int = keys().size

    fun forgetAll() {
        phone.edit().remove("keys").remove("lastWatchName").apply()
        watch.edit().remove("psk").remove("phoneAddress").remove("phoneName").apply()
    }

    private fun keys(): MutableMap<String, String> {
        val raw = phone.getString("keys", "") ?: return mutableMapOf()
        if (raw.isBlank()) return mutableMapOf()
        return try {
            val json = WearJson.parse(raw)
            json.keys
                .associateWith { key -> WearJson.string(json, key) ?: "" }
                .filterValues { it.isNotEmpty() }
                .toMutableMap()
        } catch (_: Exception) {
            mutableMapOf()
        }
    }

    private fun watchKey(id: String): String? = keys()[id]

    var watchId: String
        get() {
            val current = watch.getString("watchId", "")
            if (!current.isNullOrBlank()) return current
            val created = UUID.randomUUID().toString()
            watch.edit().putString("watchId", created).apply()
            return created
        }
        set(value) = watch.edit().putString("watchId", value).apply()

    var watchName: String
        get() = watch.getString("watchName", "")?.takeIf { it.isNotBlank() }
            ?: if (Build.MODEL.isBlank()) "GymMane Watch" else Build.MODEL
        set(value) = watch.edit().putString("watchName", value.take(64)).apply()

    var phoneAddress: String
        get() = watch.getString("phoneAddress", "") ?: ""
        set(value) = watch.edit().putString("phoneAddress", value).apply()

    var phoneName: String
        get() = watch.getString("phoneName", "") ?: ""
        set(value) = watch.edit().putString("phoneName", value.take(64)).apply()

    var watchPsk: ByteArray?
        get() {
            val value = watch.getString("psk", "") ?: return null
            return WearCrypto.fromB64(value)
        }
        set(value) {
            if (value == null) {
                watch.edit().remove("psk").apply()
            } else {
                watch.edit().putString("psk", WearCrypto.b64(value)).apply()
            }
        }

    var clientEnabled: Boolean
        get() = watch.getBoolean("enabled", false)
        set(value) = watch.edit().putBoolean("enabled", value).apply()

    fun newPairingPin(): String {
        val pin = (100000 + random.nextInt(900000)).toString()
        currentPin = pin
        pairingDeadline = System.currentTimeMillis() + 120_000L
        pairingFailures = 0
        return pin
    }

    fun clearPairing() {
        currentPin = ""
        pairingDeadline = 0L
        pairingFailures = 0
    }

    fun notePairingFailure() {
        if (++pairingFailures >= 5) clearPairing()
    }

    companion object {
        private val random = SecureRandom()
        private var currentPin = ""
        private var pairingDeadline = 0L
        private var pairingFailures = 0
    }
}
