package com.gymmane.wear.protocol

import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureSessionTest {
    private fun pair(): Pair<SecureSession, SecureSession> {
        val key = WearCrypto.random(32)
        val sid = WearCrypto.random(16)
        return SecureSession(key, sid, "w2p", "p2w") to
            SecureSession(key, sid, "p2w", "w2p")
    }

    private fun message(value: Int) = buildJsonObject {
        put("value", WearJson.number(value.toLong()))
    }

    @Test
    fun messagesRoundTripInBothDirections() {
        val (watch, phone) = pair()
        val opened = phone.open(watch.seal("command", message(7)))
        assertEquals("command", opened.type)
        assertEquals(7, WearJson.int(opened.data, "value"))
        val back = watch.open(phone.seal("state", message(8)))
        assertEquals("state", back.type)
        assertEquals(8, WearJson.int(back.data, "value"))
    }

    @Test
    fun sequenceNumbersAreStrictlyIncreasing() {
        val (watch, phone) = pair()
        assertEquals(1, phone.open(watch.seal("a", message(1))).seq)
        assertEquals(2, phone.open(watch.seal("a", message(2))).seq)
    }

    @Test(expected = WearSecurityException::class)
    fun replayedMessageIsRejected() {
        val (watch, phone) = pair()
        val envelope = watch.seal("command", message(1))
        phone.open(envelope)
        phone.open(envelope)
    }

    @Test(expected = WearSecurityException::class)
    fun tamperedPayloadIsRejected() {
        val (watch, phone) = pair()
        val envelope = watch.seal("command", message(1))
        val copy = kotlinx.serialization.json.JsonObject(
            envelope.toMutableMap().also { it["d"] = WearJson.text("{\"value\":99}") },
        )
        phone.open(copy)
    }

    @Test(expected = WearSecurityException::class)
    fun tamperedSequenceIsRejected() {
        val (watch, phone) = pair()
        val envelope = watch.seal("command", message(1))
        val copy = kotlinx.serialization.json.JsonObject(
            envelope.toMutableMap().also { it["seq"] = WearJson.number(5) },
        )
        phone.open(copy)
    }

    @Test(expected = WearSecurityException::class)
    fun reflectionIsRejected() {
        val (watch, phone) = pair()
        val envelope = watch.seal("command", message(1))
        watch.open(envelope)
    }

    @Test(expected = WearSecurityException::class)
    fun messagesFromAnotherSessionAreRejected() {
        val (watch, _) = pair()
        val (_, otherPhone) = pair()
        otherPhone.open(watch.seal("command", message(1)))
    }

    @Test
    fun wrongKeyCannotForge() {
        val key = WearCrypto.random(32)
        val sid = WearCrypto.random(16)
        val attacker = SecureSession(WearCrypto.random(32), sid, "w2p", "p2w")
        val phone = SecureSession(key, sid, "p2w", "w2p")
        var failed = false
        try {
            phone.open(attacker.seal("command", message(1)))
        } catch (_: WearSecurityException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun hkdfIsDeterministicAndDomainSeparated() {
        val ikm = ByteArray(32) { it.toByte() }
        val salt = ByteArray(16) { (it * 3).toByte() }
        val a = WearCrypto.hkdf(ikm, salt, "one".toByteArray())
        val b = WearCrypto.hkdf(ikm, salt, "one".toByteArray())
        val c = WearCrypto.hkdf(ikm, salt, "two".toByteArray())
        assertArrayEquals(a, b)
        assertNotEquals(a.toList(), c.toList())
        assertEquals(32, a.size)
        assertEquals(64, WearCrypto.hkdf(ikm, salt, "one".toByteArray(), 64).size)
    }

    @Test
    fun pbkdf2IsDeterministic() {
        val salt = WearCrypto.random(16)
        val a = WearCrypto.pbkdf2("123456".toCharArray(), salt, 1000)
        val b = WearCrypto.pbkdf2("123456".toCharArray(), salt, 1000)
        val c = WearCrypto.pbkdf2("123457".toCharArray(), salt, 1000)
        assertArrayEquals(a, b)
        assertNotEquals(a.toList(), c.toList())
    }

    @Test
    fun base64RoundTrips() {
        val data = WearCrypto.random(64)
        assertArrayEquals(data, WearCrypto.fromB64(WearCrypto.b64(data)))
        assertEquals(null, WearCrypto.fromB64("!!!"))
    }
}
