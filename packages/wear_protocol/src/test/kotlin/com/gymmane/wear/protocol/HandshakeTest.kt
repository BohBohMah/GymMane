package com.gymmane.wear.protocol

import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HandshakeTest {
    @Test
    fun exchangeWithoutPinUsesAnExplicitTrustedBluetoothBond() {
        var allowed = true
        var phoneKey: ByteArray? = null
        var watchKey: ByteArray? = null
        val phone = PhoneHandshake("Phone", { null }, { null }, { _, _, key -> phoneKey = key },
            allowBondedPairing = { allowed })
        val watch = WatchHandshake("watch-1", "Watch", null, trustBluetoothBond = true) { watchKey = it }
        val hello = phone.onMessage(watch.start()) as PhoneHandshakeResult.Reply
        assertEquals(2, hello.messages.size)
        assertTrue(watch.onMessage(hello.messages.first()) is WatchHandshakeResult.Reply)
        val ready = watch.onMessage(hello.messages.last()) as WatchHandshakeResult.Ready
        assertTrue(phone.onMessage(ready.confirm) is PhoneHandshakeResult.Established)
        assertTrue(phoneKey!!.contentEquals(watchKey!!))
        allowed = false
        val closed = PhoneHandshake("Phone", { null }, { null }, { _, _, _ -> error("must not pair") },
            allowBondedPairing = { allowed })
        assertTrue((closed.onMessage(WatchHandshake("watch-2", "Watch", null) {}.start()) as PhoneHandshakeResult.Reply).close)
    }

    @Test
    fun canceledPairingCannotBeConfirmed() {
        var pin: String? = "123456"
        var stored = false
        val phone = PhoneHandshake("Phone", { null }, { pin }, { _, _, _ -> stored = true })
        val watch = WatchHandshake("watch-1", "Watch", null) {}
        val hello = phone.onMessage(watch.start()) as PhoneHandshakeResult.Reply
        watch.onMessage(hello.messages.single())
        val grant = phone.onMessage(watch.submitPin("123456")!!) as PhoneHandshakeResult.Reply
        val ready = watch.onMessage(grant.messages.single()) as WatchHandshakeResult.Ready
        pin = null
        val rejected = phone.onMessage(ready.confirm) as PhoneHandshakeResult.Reply
        assertTrue(rejected.close)
        assertFalse(stored)
    }

    private data class Pairing(
        val phoneSession: SecureSession?,
        val watchSession: SecureSession?,
        val phoneStore: MutableMap<String, ByteArray>,
        val watchPsk: ByteArray?,
        val pairedNow: Boolean,
    )

    private fun pair(
        pin: String = "123456",
        typedPin: String? = pin,
    ): Pairing {
        val phoneStore = mutableMapOf<String, ByteArray>()
        var watchPsk: ByteArray? = null
        val phone = PhoneHandshake(
            phoneName = "Pixel",
            pskFor = { phoneStore[it] },
            pairingPin = { pin },
            onPaired = { id, _, key -> phoneStore[id] = key },
        )
        val watch = WatchHandshake(
            watchId = "watch-1",
            watchName = "Galaxy Watch",
            existingPsk = null,
            onPaired = { watchPsk = it },
        )
        val hello = watch.start()
        val first = phone.onMessage(hello) as PhoneHandshakeResult.Reply
        val phoneHello = first.messages.single()
        val next = watch.onMessage(phoneHello)
        assertTrue(next is WatchHandshakeResult.NeedPin)

        val auth = watch.submitPin(typedPin ?: "")
        assertNotNull(auth)
        val second = phone.onMessage(auth!!)
        if (typedPin != pin) {
            assertTrue(second is PhoneHandshakeResult.Reply)
            assertTrue((second as PhoneHandshakeResult.Reply).close)
            val rejected = watch.onMessage(second.messages.single())
            assertTrue(rejected is WatchHandshakeResult.Rejected)
            return Pairing(
                phoneSession = null,
                watchSession = null,
                phoneStore = phoneStore,
                watchPsk = watchPsk,
                pairedNow = false,
            )
        }
        val grant = (second as PhoneHandshakeResult.Reply).messages.single()
        val ready = watch.onMessage(grant) as WatchHandshakeResult.Ready
        assertTrue(ready.pairedNow)
        assertNotNull(watchPsk)
        val done = phone.onMessage(ready.confirm) as PhoneHandshakeResult.Established
        assertTrue(done.pairedNow)
        assertEquals("watch-1", done.watchId)
        assertEquals("Galaxy Watch", done.watchName)
        assertTrue(phoneStore.containsKey("watch-1"))
        return Pairing(
            phoneSession = done.session,
            watchSession = ready.session,
            phoneStore = phoneStore,
            watchPsk = watchPsk,
            pairedNow = true,
        )
    }

    private fun resume(pairing: Pairing): Pairing {
        var watchPsk: ByteArray? = pairing.watchPsk
        var pairedAgain = false
        val phone = PhoneHandshake(
            phoneName = "Pixel",
            pskFor = { pairing.phoneStore[it] },
            pairingPin = { null },
            onPaired = { _, _, key ->
                pairing.phoneStore["watch-1"] = key
                pairedAgain = true
            },
        )
        val watch = WatchHandshake(
            watchId = "watch-1",
            watchName = "Galaxy Watch",
            existingPsk = pairing.watchPsk,
            onPaired = { watchPsk = it },
        )
        val first = phone.onMessage(watch.start()) as PhoneHandshakeResult.Reply
        assertFalse(first.close)
        val auth = watch.onMessage(first.messages.single())
        assertTrue(auth is WatchHandshakeResult.Reply)
        val second = phone.onMessage((auth as WatchHandshakeResult.Reply).messages.single())
        assertTrue(second is PhoneHandshakeResult.Reply)
        val ready = watch.onMessage((second as PhoneHandshakeResult.Reply).messages.single())
        assertTrue(ready is WatchHandshakeResult.Ready)
        val done = phone.onMessage((ready as WatchHandshakeResult.Ready).confirm)
        assertTrue(done is PhoneHandshakeResult.Established)
        assertFalse((done as PhoneHandshakeResult.Established).pairedNow)
        assertFalse(pairedAgain)
        return Pairing(
            phoneSession = done.session,
            watchSession = ready.session,
            phoneStore = pairing.phoneStore,
            watchPsk = watchPsk,
            pairedNow = false,
        )
    }

    @Test
    fun pinPairingEstablishesMatchingSessions() {
        val first = pair()
        assertTrue(first.pairedNow)
        assertEquals(first.phoneStore["watch-1"]!!.toList(), first.watchPsk!!.toList())

        val data = buildJsonObject { put("n", WearJson.number(4)) }
        val phoneView = first.phoneSession!!.open(first.watchSession!!.seal("command", data))
        assertEquals(4, WearJson.int(phoneView.data, "n"))
        val watchView = first.watchSession!!.open(first.phoneSession!!.seal("state", data))
        assertEquals(4, WearJson.int(watchView.data, "n"))
    }

    @Test
    fun storedKeyResumesWithoutPin() {
        val first = pair()
        val second = resume(first)
        assertFalse(second.pairedNow)
        val data = buildJsonObject { put("ok", WearJson.bool(true)) }
        val opened = second.phoneSession!!.open(second.watchSession!!.seal("command", data))
        assertEquals(true, WearJson.bool(opened.data, "ok"))
    }

    @Test
    fun wrongPinIsRejectedAndNoKeyIsStored() {
        val result = pair(typedPin = "000000")
        assertFalse(result.pairedNow)
        assertNull(result.watchPsk)
        assertTrue(result.phoneStore.isEmpty())
    }

    @Test
    fun pairingWindowClosedRejectsUnknownWatch() {
        val phone = PhoneHandshake(
            phoneName = "Pixel",
            pskFor = { null },
            pairingPin = { null },
            onPaired = { _, _, _ -> error("must not pair") },
        )
        val watch = WatchHandshake("watch-x", "Watch", null) { error("must not pair") }
        val reply = phone.onMessage(watch.start()) as PhoneHandshakeResult.Reply
        assertTrue(reply.close)
        assertTrue(watch.onMessage(reply.messages.single()) is WatchHandshakeResult.Rejected)
    }

    @Test
    fun unknownWatchCannotResumeWithoutKey() {
        val phone = PhoneHandshake(
            phoneName = "Pixel",
            pskFor = { WearCrypto.random(32) },
            pairingPin = { "123456" },
            onPaired = { _, _, _ -> },
        )
        val watch = WatchHandshake("watch-x", "Watch", existingPsk = null) { }
        val reply = phone.onMessage(watch.start()) as PhoneHandshakeResult.Reply
        val hello = reply.messages.single()
        val rejected = watch.onMessage(hello)
        assertTrue(rejected is WatchHandshakeResult.Rejected)
    }

    @Test
    fun badNonceIsRejected() {
        val phone = PhoneHandshake("Pixel", { null }, { "123456" }, { _, _, _ -> })
        val hello = buildJsonObject {
            put("t", WearJson.text("hello"))
            put("v", WearJson.number(1))
            put("role", WearJson.text("watch"))
            put("id", WearJson.text("w"))
            put("name", WearJson.text("Watch"))
            put("nonce", WearJson.text(WearCrypto.b64(ByteArray(3))))
        }
        val reply = phone.onMessage(hello) as PhoneHandshakeResult.Reply
        assertTrue(reply.close)
        assertEquals("nonce", WearJson.string(reply.messages.single(), "reason"))
    }

    @Test
    fun wrongVersionIsRejected() {
        val phone = PhoneHandshake("Pixel", { null }, { "123456" }, { _, _, _ -> })
        val hello = buildJsonObject {
            put("t", WearJson.text("hello"))
            put("v", WearJson.number(2))
            put("role", WearJson.text("watch"))
            put("id", WearJson.text("w"))
            put("name", WearJson.text("Watch"))
            put("nonce", WearJson.text(WearCrypto.b64(WearCrypto.random(16))))
        }
        val reply = phone.onMessage(hello) as PhoneHandshakeResult.Reply
        assertTrue(reply.close)
        assertEquals("version", WearJson.string(reply.messages.single(), "reason"))
    }

    @Test
    fun duplicateHelloIsRejected() {
        val phone = PhoneHandshake("Pixel", { null }, { "123456" }, { _, _, _ -> })
        val watch = WatchHandshake("watch-1", "Watch", null) { }
        phone.onMessage(watch.start())
        val second = phone.onMessage(watch.start()) as PhoneHandshakeResult.Reply
        assertTrue(second.close)
    }

    @Test
    fun wrongPhoneIsRejectedByWatch() {
        val watch = WatchHandshake("watch-1", "Watch", WearCrypto.random(32)) { }
        watch.start()
        val reply = watch.onMessage(
            buildJsonObject {
                put("t", WearJson.text("hello"))
                put("v", WearJson.number(1))
                put("role", WearJson.text("watch"))
                put("name", WearJson.text("Impostor"))
                put("nonce", WearJson.text(WearCrypto.b64(WearCrypto.random(16))))
            },
        )
        assertTrue(reply is WatchHandshakeResult.Rejected)
    }

    @Test
    fun shortPinCannotBeSubmitted() {
        val watch = WatchHandshake("watch-1", "Watch", null) { }
        watch.start()
        assertNull(watch.submitPin("12"))
    }
}
