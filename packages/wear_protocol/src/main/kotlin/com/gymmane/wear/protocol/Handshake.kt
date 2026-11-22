package com.gymmane.wear.protocol

import kotlinx.serialization.json.JsonObject

sealed class PhoneHandshakeResult {
    data class Reply(val messages: List<JsonObject>, val close: Boolean = false) : PhoneHandshakeResult()
    data class Established(
        val session: SecureSession,
        val watchId: String,
        val watchName: String,
        val pairedNow: Boolean,
    ) : PhoneHandshakeResult()
}

class PhoneHandshake(
    private val phoneName: String,
    private val pskFor: (String) -> ByteArray?,
    private val pairingPin: () -> String?,
    private val onPaired: (watchId: String, watchName: String, psk: ByteArray) -> Unit,
    private val onPairingFailure: () -> Unit = {},
    private val allowBondedPairing: () -> Boolean = { false },
) {
    private enum class Phase { HELLO, AUTH, CONFIRM, DONE }

    private var phase = Phase.HELLO
    private var watchId = ""
    private var watchName = ""
    private var watchNonce = ByteArray(0)
    private var phoneNonce = ByteArray(0)
    private var transcript = ByteArray(0)
    private var psk = ByteArray(0)
    private var pinKey: ByteArray? = null
    private var sessionId = ByteArray(0)
    private var pairing = false
    private var bondedPairing = false

    fun onMessage(message: JsonObject): PhoneHandshakeResult {
        val type = WearJson.string(message, "t")
        return try {
            when (phase) {
                Phase.HELLO -> hello(message, type)
                Phase.AUTH -> auth(message, type)
                Phase.CONFIRM -> confirm(message, type)
                Phase.DONE -> reject("already_done")
            }
        } catch (error: Exception) {
            reject("bad_message")
        }
    }

    private fun hello(message: JsonObject, type: String?): PhoneHandshakeResult {
        if (type != "hello") return reject("hello_expected")
        if (WearJson.long(message, "v") != HandshakeCrypto.PROTOCOL.toLong()) return reject("version")
        if (WearJson.string(message, "role") != "watch") return reject("role")
        val id = WearJson.string(message, "id")
        val name = WearJson.string(message, "name")
        val nonce = WearCrypto.fromB64(WearJson.string(message, "nonce") ?: "")
        if (!HandshakeCrypto.validDeviceId(id) || !HandshakeCrypto.validName(name)) return reject("identity")
        if (!HandshakeCrypto.validNonce(nonce)) return reject("nonce")
        watchId = id!!
        watchName = name!!
        watchNonce = nonce!!
        phoneNonce = WearCrypto.random(24)
        transcript = HandshakeCrypto.transcript(watchId, watchNonce, phoneNonce)
        val known = pskFor(watchId)
        val pin = pairingPin()
        pairing = known == null
        if (known != null) {
            psk = known
            phase = Phase.AUTH
            return PhoneHandshakeResult.Reply(
                listOf(HandshakeCrypto.phoneHello(phoneName, phoneNonce, "resume")),
            )
        }
        if (allowBondedPairing()) {
            bondedPairing = true
            psk = WearCrypto.random(WearCrypto.KEY_BYTES)
            sessionId = WearCrypto.random(16)
            phase = Phase.CONFIRM
            return PhoneHandshakeResult.Reply(listOf(
                HandshakeCrypto.phoneHello(phoneName, phoneNonce, "bonded"),
                HandshakeCrypto.grant(psk, sessionId, HandshakeCrypto.readyProof(psk, transcript, sessionId)),
            ))
        }
        if (pin == null || !validPin(pin)) return reject("not_paired")
        pinKey = HandshakeCrypto.pinKey(pin, transcript)
        phase = Phase.AUTH
        return PhoneHandshakeResult.Reply(
            listOf(HandshakeCrypto.phoneHello(phoneName, phoneNonce, "pair")),
        )
    }

    private fun auth(message: JsonObject, type: String?): PhoneHandshakeResult {
        if (type != "auth") return reject("auth_expected")
        val proof = WearCrypto.fromB64(WearJson.string(message, "proof") ?: "") ?: return reject("proof")
        if (pairing) {
            val currentPin = pairingPin() ?: return reject("not_paired")
            val key = pinKey ?: return reject("pin")
            if (!WearCrypto.constantTimeEquals(key, HandshakeCrypto.pinKey(currentPin, transcript))) {
                return reject("not_paired")
            }
            val expected = HandshakeCrypto.pairProof(key, transcript)
            if (!WearCrypto.constantTimeEquals(expected, proof)) {
                onPairingFailure()
                return reject("bad_pin")
            }
            val fresh = WearCrypto.random(WearCrypto.KEY_BYTES)
            sessionId = WearCrypto.random(16)
            psk = fresh
            phase = Phase.CONFIRM
            return PhoneHandshakeResult.Reply(
                listOf(
                    HandshakeCrypto.grant(
                        fresh,
                        sessionId,
                        HandshakeCrypto.grantProof(key, transcript, fresh),
                    ),
                ),
            )
        }
        val expected = HandshakeCrypto.resumeProof(psk, transcript)
        if (!WearCrypto.constantTimeEquals(expected, proof)) return reject("bad_proof")
        sessionId = WearCrypto.random(16)
        phase = Phase.CONFIRM
        return PhoneHandshakeResult.Reply(
            listOf(
                HandshakeCrypto.ready(
                    HandshakeCrypto.readyProof(psk, transcript, sessionId),
                    sessionId,
                ),
            ),
        )
    }

    private fun confirm(message: JsonObject, type: String?): PhoneHandshakeResult {
        if (type != "confirm") return reject("confirm_expected")
        val proof = WearCrypto.fromB64(WearJson.string(message, "proof") ?: "") ?: return reject("proof")
        if (bondedPairing) {
            if (!allowBondedPairing()) return reject("not_paired")
        } else if (pairing) {
            val currentPin = pairingPin() ?: return reject("not_paired")
            val key = pinKey ?: return reject("pin")
            if (!WearCrypto.constantTimeEquals(key, HandshakeCrypto.pinKey(currentPin, transcript))) {
                return reject("not_paired")
            }
            pinKey = null
        }
        val expected = HandshakeCrypto.confirmProof(psk, transcript, sessionId)
        if (!WearCrypto.constantTimeEquals(expected, proof)) return reject("bad_confirm")
        phase = Phase.DONE
        if (pairing) onPaired(watchId, watchName, psk)
        val key = HandshakeCrypto.sessionKey(psk, transcript)
        return PhoneHandshakeResult.Established(
            SecureSession(key, sessionId, "p2w", "w2p"),
            watchId,
            watchName,
            pairing,
        )
    }

    private fun reject(reason: String): PhoneHandshakeResult {
        phase = Phase.DONE
        return PhoneHandshakeResult.Reply(listOf(HandshakeCrypto.reject(reason)), close = true)
    }
}

sealed class WatchHandshakeResult {
    data class Reply(val messages: List<JsonObject>) : WatchHandshakeResult()
    data class NeedPin(val phoneName: String) : WatchHandshakeResult()
    data class Ready(
        val session: SecureSession,
        val phoneName: String,
        val pairedNow: Boolean,
        val confirm: JsonObject,
    ) : WatchHandshakeResult()
    data class Rejected(val reason: String) : WatchHandshakeResult()
}

class WatchHandshake(
    private val watchId: String,
    private val watchName: String,
    private val existingPsk: ByteArray?,
    private val trustBluetoothBond: Boolean = false,
    private val onPaired: (ByteArray) -> Unit,
) {
    private enum class Phase { PHONE_HELLO, PIN, READY, GRANT, DONE }

    private var phase = Phase.PHONE_HELLO
    private var phoneName = ""
    private var phoneNonce = ByteArray(0)
    private var watchNonce = ByteArray(0)
    private var transcript = ByteArray(0)
    private var pinKey: ByteArray? = null
    private var psk = ByteArray(0)
    private var sessionId = ByteArray(0)
    private var pairing = false
    private var bondedPairing = false

    fun start(): JsonObject {
        watchNonce = WearCrypto.random(24)
        return HandshakeCrypto.hello("watch", watchId, watchName, watchNonce)
    }

    fun onMessage(message: JsonObject): WatchHandshakeResult {
        val type = WearJson.string(message, "t")
        return try {
            when {
                type == "hello" -> phoneHello(message)
                type == "reject" -> WatchHandshakeResult.Rejected(
                    WearJson.string(message, "reason") ?: "rejected",
                )
                type == "ready" && phase == Phase.READY -> ready(message)
                type == "grant" && phase == Phase.GRANT -> grant(message)
                else -> WatchHandshakeResult.Rejected("unexpected")
            }
        } catch (error: Exception) {
            WatchHandshakeResult.Rejected("bad_message")
        }
    }

    private fun phoneHello(message: JsonObject): WatchHandshakeResult {
        if (phase != Phase.PHONE_HELLO) return WatchHandshakeResult.Rejected("duplicate_hello")
        if (WearJson.long(message, "v") != HandshakeCrypto.PROTOCOL.toLong()) {
            return WatchHandshakeResult.Rejected("version")
        }
        if (WearJson.string(message, "role") != "phone") {
            return WatchHandshakeResult.Rejected("role")
        }
        val name = WearJson.string(message, "name")
        val nonce = WearCrypto.fromB64(WearJson.string(message, "nonce") ?: "")
        if (!HandshakeCrypto.validName(name) || !HandshakeCrypto.validNonce(nonce)) {
            return WatchHandshakeResult.Rejected("identity")
        }
        phoneName = name!!
        phoneNonce = nonce!!
        transcript = HandshakeCrypto.transcript(watchId, watchNonce, phoneNonce)
        when (WearJson.string(message, "mode")) {
            "bonded" -> {
                if (!trustBluetoothBond) return WatchHandshakeResult.Rejected("mode")
                bondedPairing = true
                phase = Phase.GRANT
                return WatchHandshakeResult.Reply(emptyList())
            }
            "pair" -> {
                pairing = true
                phase = Phase.PIN
                return WatchHandshakeResult.NeedPin(phoneName)
            }
            "resume" -> {
                val known = existingPsk
                    ?: return WatchHandshakeResult.Rejected("no_key")
                psk = known
                phase = Phase.READY
                return WatchHandshakeResult.Reply(
                    listOf(HandshakeCrypto.auth(HandshakeCrypto.resumeProof(psk, transcript))),
                )
            }
            else -> return WatchHandshakeResult.Rejected("mode")
        }
    }

    fun submitPin(pin: String): JsonObject? {
        if (phase != Phase.PIN || !validPin(pin)) return null
        val key = HandshakeCrypto.pinKey(pin, transcript)
        pinKey = key
        phase = Phase.GRANT
        return HandshakeCrypto.auth(HandshakeCrypto.pairProof(key, transcript))
    }

    private fun ready(message: JsonObject): WatchHandshakeResult {
        val proof = WearCrypto.fromB64(WearJson.string(message, "proof") ?: "")
            ?: return WatchHandshakeResult.Rejected("proof")
        val sid = WearCrypto.fromB64(WearJson.string(message, "sid") ?: "")
        if (!HandshakeCrypto.validNonce(sid) || sid!!.size > 32) {
            return WatchHandshakeResult.Rejected("sid")
        }
        sessionId = sid
        val expected = HandshakeCrypto.readyProof(psk, transcript, sessionId)
        if (!WearCrypto.constantTimeEquals(expected, proof)) {
            return WatchHandshakeResult.Rejected("bad_ready")
        }
        phase = Phase.DONE
        return WatchHandshakeResult.Ready(
            session = SecureSession(
                HandshakeCrypto.sessionKey(psk, transcript),
                sessionId,
                "w2p",
                "p2w",
            ),
            phoneName = phoneName,
            pairedNow = false,
            confirm = HandshakeCrypto.confirm(
                HandshakeCrypto.confirmProof(psk, transcript, sessionId),
            ),
        )
    }

    private fun grant(message: JsonObject): WatchHandshakeResult {
        val fresh = WearCrypto.fromB64(WearJson.string(message, "psk") ?: "")
            ?: return WatchHandshakeResult.Rejected("psk")
        val sid = WearCrypto.fromB64(WearJson.string(message, "sid") ?: "")
            ?: return WatchHandshakeResult.Rejected("sid")
        if (fresh.size != WearCrypto.KEY_BYTES) return WatchHandshakeResult.Rejected("psk_size")
        if (!HandshakeCrypto.validNonce(sid) || sid.size > 32) {
            return WatchHandshakeResult.Rejected("sid")
        }
        sessionId = sid
        val proof = WearCrypto.fromB64(WearJson.string(message, "proof") ?: "")
            ?: return WatchHandshakeResult.Rejected("proof")
        val expected = if (bondedPairing) HandshakeCrypto.readyProof(fresh, transcript, sid) else {
            val key = pinKey ?: return WatchHandshakeResult.Rejected("pin")
            HandshakeCrypto.grantProof(key, transcript, fresh)
        }
        if (!WearCrypto.constantTimeEquals(expected, proof)) {
            return WatchHandshakeResult.Rejected("bad_grant")
        }
        psk = fresh
        pinKey = null
        onPaired(fresh)
        phase = Phase.DONE
        return WatchHandshakeResult.Ready(
            session = SecureSession(
                HandshakeCrypto.sessionKey(psk, transcript),
                sessionId,
                "w2p",
                "p2w",
            ),
            phoneName = phoneName,
            pairedNow = true,
            confirm = HandshakeCrypto.confirm(
                HandshakeCrypto.confirmProof(psk, transcript, sessionId),
            ),
        )
    }
}

private fun validPin(pin: String): Boolean = pin.length == 6 && pin.all { it in '0'..'9' }
