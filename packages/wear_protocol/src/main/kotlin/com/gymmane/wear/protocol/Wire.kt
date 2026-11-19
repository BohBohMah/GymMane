package com.gymmane.wear.protocol

enum class FrameKind(val code: Byte) {
    HANDSHAKE(1),
    SECURE(2),
}

class WireFrame(val kind: FrameKind, val payload: ByteArray)

object Wire {
    const val PROTOCOL_VERSION = 1
    const val MAX_FRAME = 65536
    internal const val HEADER = 5

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
    private val header = ByteArray(Wire.HEADER)
    private var headerSize = 0
    private var kind = FrameKind.HANDSHAKE
    private var payload: ByteArray? = null
    private var payloadSize = 0

    fun feed(chunk: ByteArray): List<WireFrame> {
        if (chunk.isEmpty()) return emptyList()
        val frames = mutableListOf<WireFrame>()
        var at = 0
        while (at < chunk.size) {
            if (payload == null) {
                val bytes = minOf(header.size - headerSize, chunk.size - at)
                chunk.copyInto(header, headerSize, at, at + bytes)
                headerSize += bytes
                at += bytes
                if (headerSize < header.size) break
                kind = FrameKind.entries.firstOrNull { it.code == header[0] }
                    ?: throw WireFormatException("unknown frame kind")
                val length = ((header[1].toInt() and 0xff) shl 24) or
                    ((header[2].toInt() and 0xff) shl 16) or
                    ((header[3].toInt() and 0xff) shl 8) or
                    (header[4].toInt() and 0xff)
                if (length !in 0..Wire.MAX_FRAME) throw WireFormatException("bad frame length")
                payload = ByteArray(length)
            }
            val frame = checkNotNull(payload)
            val bytes = minOf(frame.size - payloadSize, chunk.size - at)
            chunk.copyInto(frame, payloadSize, at, at + bytes)
            payloadSize += bytes
            at += bytes
            if (payloadSize == frame.size) {
                frames += WireFrame(kind, frame)
                reset()
            }
        }
        return frames
    }

    fun reset() {
        headerSize = 0
        payload = null
        payloadSize = 0
    }
}

object Chunker {
    /** ATT limits an attribute value to 512 bytes even when MTU - 3 is larger. */
    fun gattPayloadSize(mtu: Int): Int = (mtu.coerceAtLeast(23) - 3).coerceAtMost(512)

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
