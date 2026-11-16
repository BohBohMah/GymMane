package com.gymmane.wear.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WireTest {
    @Test
    fun gattChunksRespectAttributeLimitAtMaximumMtu() {
        assertEquals(20, Chunker.gattPayloadSize(23))
        assertEquals(244, Chunker.gattPayloadSize(247))
        assertEquals(512, Chunker.gattPayloadSize(517))
        assertEquals(512, Chunker.gattPayloadSize(Int.MAX_VALUE))
        val payload = ByteArray(1500) { (it % 251).toByte() }
        val chunks = Chunker.split(Wire.encode(FrameKind.SECURE, payload), Chunker.gattPayloadSize(517))
        assertTrue(chunks.all { it.size <= 512 })
        val reader = FrameReader()
        val frames = chunks.flatMap { reader.feed(it) }
        assertArrayEquals(payload, frames.single().payload)
    }

    @Test
    fun roundTripKeepsKindAndPayload() {
        val payload = "hello".toByteArray()
        val encoded = Wire.encode(FrameKind.HANDSHAKE, payload)
        val frames = FrameReader().feed(encoded)
        assertEquals(1, frames.size)
        assertEquals(FrameKind.HANDSHAKE, frames[0].kind)
        assertArrayEquals(payload, frames[0].payload)
    }

    @Test
    fun fragmentedInputIsReassembled() {
        val payload = ByteArray(4096) { (it % 251).toByte() }
        val encoded = Wire.encode(FrameKind.SECURE, payload)
        val reader = FrameReader()
        var frames = emptyList<WireFrame>()
        for (chunk in Chunker.split(encoded, 37)) {
            frames = frames + reader.feed(chunk)
        }
        assertEquals(1, frames.size)
        assertArrayEquals(payload, frames[0].payload)
    }

    @Test
    fun twoFramesInOneChunkAreBothReported() {
        val a = Wire.encode(FrameKind.HANDSHAKE, "a".toByteArray())
        val b = Wire.encode(FrameKind.SECURE, "b".toByteArray())
        val frames = FrameReader().feed(a + b)
        assertEquals(2, frames.size)
        assertEquals("a", frames[0].payload.decodeToString())
        assertEquals("b", frames[1].payload.decodeToString())
    }

    @Test(expected = WireFormatException::class)
    fun unknownKindIsRejected() {
        FrameReader().feed(byteArrayOf(9, 0, 0, 0, 1, 0))
    }

    @Test(expected = WireFormatException::class)
    fun oversizedFrameIsRejected() {
        FrameReader().feed(byteArrayOf(1, 0, 2, 0, 0))
    }

    @Test
    fun chunkerNeverReturnsEmptyChunks() {
        val chunks = Chunker.split(ByteArray(100), 30)
        assertEquals(4, chunks.size)
        assertTrue(chunks.all { it.isNotEmpty() && it.size <= 30 })
        assertEquals(100, chunks.sumOf { it.size })
    }

    @Test
    fun chunksReassembleToOriginalBytes() {
        val data = WearCrypto.random(513)
        val joined = Chunker.split(data, 20).fold(ByteArray(0)) { acc, bytes -> acc + bytes }
        assertArrayEquals(data, joined)
    }

    @Test
    fun frameLimitIsEnforcedOnEncode() {
        var failed = false
        try {
            Wire.encode(FrameKind.SECURE, ByteArray(Wire.MAX_FRAME + 1))
        } catch (_: IllegalArgumentException) {
            failed = true
        }
        assertTrue(failed)
    }

    @Test
    fun emptyInputProducesNoFrames() {
        assertTrue(FrameReader().feed(ByteArray(0)).isEmpty())
    }

    @Test
    fun trailingPartialHeaderIsBuffered() {
        val encoded = Wire.encode(FrameKind.HANDSHAKE, "ok".toByteArray())
        val reader = FrameReader()
        assertTrue(reader.feed(encoded.copyOfRange(0, 3)).isEmpty())
        assertEquals(1, reader.feed(encoded.copyOfRange(3, encoded.size)).size)
    }

    @Test
    fun secureFrameKindSurvives() {
        val encoded = Wire.encode(FrameKind.SECURE, ByteArray(0))
        val frame = FrameReader().feed(encoded).single()
        assertEquals(FrameKind.SECURE, frame.kind)
        assertEquals(0, frame.payload.size)
    }

    @Test
    fun readerCanBeResetBetweenSessions() {
        val encoded = Wire.encode(FrameKind.HANDSHAKE, "x".toByteArray())
        val reader = FrameReader()
        reader.feed(encoded.copyOfRange(0, 2))
        reader.reset()
        val frames = reader.feed(encoded)
        assertEquals(1, frames.size)
        assertFalse(frames[0].payload.isEmpty())
    }
}
