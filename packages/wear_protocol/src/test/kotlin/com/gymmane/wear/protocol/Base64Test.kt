package com.gymmane.wear.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class Base64Test {
    @Test
    fun roundTripsEveryPaddingLength() {
        for (size in 0..64) {
            val bytes = ByteArray(size) { (it * 37 + 11).toByte() }
            val encoded = WearCrypto.b64(bytes)
            val decoded = WearCrypto.fromB64(encoded)
            assertNotNull("size $size", decoded)
            assertEquals("size $size", bytes.toList(), decoded!!.toList())
        }
    }

    @Test
    fun matchesStandardAlphabet() {
        assertEquals("aGVsbG8=", WearCrypto.b64("hello".toByteArray()))
        assertEquals("aGVsbG8gd29ybGQ=", WearCrypto.b64("hello world".toByteArray()))
        assertEquals("", WearCrypto.b64(ByteArray(0)))
    }

    @Test
    fun rejectsMalformedInput() {
        assertNull(WearCrypto.fromB64("abc"))
        assertNull(WearCrypto.fromB64("a=b="))
        assertNull(WearCrypto.fromB64("!!!!"))
        assertNull(WearCrypto.fromB64("ab=c"))
        assertNull(WearCrypto.fromB64("abcd="))
        assertNull(WearCrypto.fromB64("aGVsbG8"))
    }
}
