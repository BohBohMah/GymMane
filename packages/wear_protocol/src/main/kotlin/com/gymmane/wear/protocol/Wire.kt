package com.gymmane.wear.protocol

import java.io.ByteArrayOutputStream

enum class FrameKind(val code: Byte) {
    HANDSHAKE(1),
    SECURE(2),
}

class WireFrame(val kind: FrameKind, val payload: ByteArray)

object Wire {
    const val PROTOCOL_VERSION = 1
    const val MAX_FRAME = 65536
    private const val HEADER = 5

    fun encode(kind: FrameKind, payload: ByteArray): ByteArray {
        require(payload.size <= MAX_FRAME) { "frame too large" }
        val out = ByteArray(HEADER + payload.size)
        out[0] = kind.code
        out[1] = (payload.size ushr 24).toByte()
        out[2] = (payload.size ushr 16).toByte()
        out[3] = (payload.size ushr 8).toByte()
        out[4] = payload.size.toByte()
        payload.copyInto(out, HEADER)
        return out
    }
}

class WireFormatException(message: String) : Exception(message)

class FrameReader {
    private var pending = ByteArray(0)

    fun feed(chunk: ByteArray): List<WireFrame> {
        if (chunk.isEmpty()) return emptyList()
        val joined = ByteArrayOutputStream(pending.size + chunk.size)
        joined.write(pending)
        joined.write(chunk)
        val data = joined.toByteArray()
        val frames = mutableListOf<WireFrame>()
        var at = 0
        while (data.size - at >= 5) {
            val kind = FrameKind.entries.firstOrNull { it.code == data[at] }
                ?: throw WireFormatException("unknown frame kind")
            val length = ((data[at + 1].toInt() and 0xff) shl 24) or
                ((data[at + 2].toInt() and 0xff) shl 16) or
                ((data[at + 3].toInt() and 0xff) shl 8) or
                (data[at + 4].toInt() and 0xff)
            if (length < 0 || length > Wire.MAX_FRAME) throw WireFormatException("bad frame length")
            if (data.size - at < 5 + length) break
            frames += WireFrame(kind, data.copyOfRange(at + 5, at + 5 + length))
            at += 5 + length
        }
        pending = if (at == data.size) ByteArray(0) else data.copyOfRange(at, data.size)
        return frames
    }

    fun reset() {
        pending = ByteArray(0)
    }
}

object Chunker {
    fun split(bytes: ByteArray, chunkSize: Int): List<ByteArray> {
        if (bytes.isEmpty()) return emptyList()
        val size = chunkSize.coerceAtLeast(20)
        val out = ArrayList<ByteArray>((bytes.size + size - 1) / size)
        var at = 0
        while (at < bytes.size) {
            val end = (at + size).coerceAtMost(bytes.size)
            out += bytes.copyOfRange(at, end)
            at = end
        }
        return out
    }
}
