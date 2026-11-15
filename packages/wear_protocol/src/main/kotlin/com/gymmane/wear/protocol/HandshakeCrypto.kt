package com.gymmane.wear.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import java.io.ByteArrayOutputStream

object HandshakeCrypto {
    const val PROTOCOL = 1
    const val APP = "GymMane-Wear-v1"
    const val MAX_NAME = 64
    const val MAX_DEVICE_ID = 64
    const val MIN_NONCE = 16
    const val MAX_NONCE = 32

    fun pack(vararg parts: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        for (part in parts) {
            out.write((part.size ushr 24) and 0xff)
            out.write((part.size ushr 16) and 0xff)
            out.write((part.size ushr 8) and 0xff)
            out.write(part.size and 0xff)
            out.write(part)
        }
        return out.toByteArray()
    }

    fun text(value: String): ByteArray = value.toByteArray(Charsets.UTF_8)

    fun transcript(watchId: String, watchNonce: ByteArray, phoneNonce: ByteArray): ByteArray =
        WearCrypto.sha256(pack(text(APP), text(watchId), watchNonce, phoneNonce))

    fun pinKey(pin: String, transcript: ByteArray): ByteArray =
        WearCrypto.pbkdf2(pin.toCharArray(), transcript)

    fun pairProof(pinKey: ByteArray, transcript: ByteArray): ByteArray =
        WearCrypto.hmac(pinKey, pack(text("pair"), transcript))

    fun grantProof(pinKey: ByteArray, transcript: ByteArray, psk: ByteArray): ByteArray =
        WearCrypto.hmac(pinKey, pack(text("grant"), transcript, psk))

    fun resumeProof(psk: ByteArray, transcript: ByteArray): ByteArray =
        WearCrypto.hmac(psk, pack(text("resume"), transcript))

    fun readyProof(psk: ByteArray, transcript: ByteArray, sessionId: ByteArray): ByteArray =
        WearCrypto.hmac(psk, pack(text("ready"), transcript, sessionId))

    fun confirmProof(psk: ByteArray, transcript: ByteArray, sessionId: ByteArray): ByteArray =
        WearCrypto.hmac(psk, pack(text("confirm"), transcript, sessionId))

    fun sessionKey(psk: ByteArray, transcript: ByteArray): ByteArray =
        WearCrypto.hkdf(psk, transcript, text("$APP-session"))

    fun hello(
        role: String,
        deviceId: String,
        name: String,
        nonce: ByteArray,
    ): JsonObject = buildJsonObject {
        put("t", WearJson.text("hello"))
        put("v", WearJson.number(PROTOCOL.toLong()))
        put("role", WearJson.text(role))
        put("id", WearJson.text(deviceId))
        put("name", WearJson.text(name))
        put("nonce", WearJson.text(WearCrypto.b64(nonce)))
    }

    fun phoneHello(name: String, nonce: ByteArray, mode: String): JsonObject = buildJsonObject {
        put("t", WearJson.text("hello"))
        put("v", WearJson.number(PROTOCOL.toLong()))
        put("role", WearJson.text("phone"))
        put("name", WearJson.text(name))
        put("nonce", WearJson.text(WearCrypto.b64(nonce)))
        put("mode", WearJson.text(mode))
    }

    fun reject(reason: String): JsonObject = buildJsonObject {
        put("t", WearJson.text("reject"))
        put("reason", WearJson.text(reason))
    }

    fun auth(proof: ByteArray): JsonObject = buildJsonObject {
        put("t", WearJson.text("auth"))
        put("proof", WearJson.text(WearCrypto.b64(proof)))
    }

    fun ready(proof: ByteArray, sessionId: ByteArray): JsonObject = buildJsonObject {
        put("t", WearJson.text("ready"))
        put("proof", WearJson.text(WearCrypto.b64(proof)))
        put("sid", WearJson.text(WearCrypto.b64(sessionId)))
    }

    fun grant(psk: ByteArray, sessionId: ByteArray, proof: ByteArray): JsonObject = buildJsonObject {
        put("t", WearJson.text("grant"))
        put("psk", WearJson.text(WearCrypto.b64(psk)))
        put("sid", WearJson.text(WearCrypto.b64(sessionId)))
        put("proof", WearJson.text(WearCrypto.b64(proof)))
    }

    fun confirm(proof: ByteArray): JsonObject = buildJsonObject {
        put("t", WearJson.text("confirm"))
        put("proof", WearJson.text(WearCrypto.b64(proof)))
    }

    fun validName(value: String?): Boolean = value != null && value.isNotBlank() && value.length <= MAX_NAME

    fun validDeviceId(value: String?): Boolean = value != null && value.isNotBlank() && value.length <= MAX_DEVICE_ID

    fun validNonce(value: ByteArray?): Boolean = value != null && value.size in MIN_NONCE..MAX_NONCE
}
