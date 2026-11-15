package com.gymmane.wear.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

class WearSecurityException(message: String) : Exception(message)

class OpenedMessage(val type: String, val data: JsonObject, val seq: Long)

class SecureSession(
    private val key: ByteArray,
    private val sessionId: ByteArray,
    private val outDirection: String,
    private val inDirection: String,
) {
    private var outSeq = 0L
    private var inSeq = 0L

    fun seal(type: String, data: JsonObject): JsonObject {
        require(type.length in 1..64) { "message type" }
        val seq = outSeq + 1
        val payload = data.toString()
        val mac = mac(seq, outDirection, type, payload)
        val envelope = buildJsonObject {
            put("sid", WearJson.text(WearCrypto.b64(sessionId)))
            put("seq", WearJson.number(seq))
            put("t", WearJson.text(type))
            put("d", WearJson.text(payload))
            put("mac", WearJson.text(WearCrypto.b64(mac)))
        }
        outSeq = seq
        return envelope
    }

    fun open(envelope: JsonObject): OpenedMessage {
        val sid = WearCrypto.fromB64(WearJson.string(envelope, "sid") ?: "")
            ?: throw WearSecurityException("sid")
        if (!WearCrypto.constantTimeEquals(sessionId, sid)) throw WearSecurityException("session")
        val seq = WearJson.long(envelope, "seq") ?: throw WearSecurityException("seq")
        if (seq <= inSeq) throw WearSecurityException("replay")
        if (seq != inSeq + 1) throw WearSecurityException("gap")
        val type = WearJson.string(envelope, "t") ?: throw WearSecurityException("type")
        if (type.length !in 1..64) throw WearSecurityException("type")
        val payload = WearJson.string(envelope, "d") ?: throw WearSecurityException("payload")
        if (payload.length > Wire.MAX_FRAME) throw WearSecurityException("payload_size")
        val actual = WearCrypto.fromB64(WearJson.string(envelope, "mac") ?: "")
            ?: throw WearSecurityException("mac")
        val expected = mac(seq, inDirection, type, payload)
        if (!WearCrypto.constantTimeEquals(expected, actual)) throw WearSecurityException("mac")
        val data = try {
            WearJson.parse(payload)
        } catch (_: Exception) {
            throw WearSecurityException("json")
        }
        inSeq = seq
        return OpenedMessage(type, data, seq)
    }

    private fun mac(seq: Long, direction: String, type: String, payload: String): ByteArray =
        WearCrypto.hmac(
            key,
            HandshakeCrypto.pack(
                HandshakeCrypto.text("msg"),
                sessionId,
                HandshakeCrypto.text(seq.toString()),
                HandshakeCrypto.text(direction),
                HandshakeCrypto.text(type),
                HandshakeCrypto.text(payload),
            ),
        )

    fun resetIncoming() {
        inSeq = 0
    }
}
