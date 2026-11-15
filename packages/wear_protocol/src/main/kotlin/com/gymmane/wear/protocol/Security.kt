package com.gymmane.wear.protocol

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object WearCrypto {
    const val KEY_BYTES = 32
    const val PBKDF2_ITERATIONS = 120_000
    private const val ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    private val random = SecureRandom()

    fun random(size: Int): ByteArray {
        val out = ByteArray(size)
        random.nextBytes(out)
        return out
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        for (part in parts) digest.update(part)
        return digest.digest()
    }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = KEY_BYTES): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArrayOutputStream(length)
        var block = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            block = hmac(prk, block + info + byteArrayOf(counter.toByte()))
            out.write(block)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }

    fun pbkdf2(pin: CharArray, salt: ByteArray, iterations: Int = PBKDF2_ITERATIONS): ByteArray {
        val spec = PBEKeySpec(pin, salt, iterations, KEY_BYTES * 8)
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean =
        MessageDigest.isEqual(left, right)

    fun b64(bytes: ByteArray): String {
        val out = StringBuilder((bytes.size + 2) / 3 * 4)
        var at = 0
        while (at + 2 < bytes.size) {
            val value = ((bytes[at].toInt() and 0xff) shl 16) or
                ((bytes[at + 1].toInt() and 0xff) shl 8) or
                (bytes[at + 2].toInt() and 0xff)
            out.append(ALPHABET[(value ushr 18) and 63])
            out.append(ALPHABET[(value ushr 12) and 63])
            out.append(ALPHABET[(value ushr 6) and 63])
            out.append(ALPHABET[value and 63])
            at += 3
        }
        when (bytes.size - at) {
            1 -> {
                val value = (bytes[at].toInt() and 0xff) shl 16
                out.append(ALPHABET[(value ushr 18) and 63])
                out.append(ALPHABET[(value ushr 12) and 63])
                out.append("==")
            }
            2 -> {
                val value = ((bytes[at].toInt() and 0xff) shl 16) or
                    ((bytes[at + 1].toInt() and 0xff) shl 8)
                out.append(ALPHABET[(value ushr 18) and 63])
                out.append(ALPHABET[(value ushr 12) and 63])
                out.append(ALPHABET[(value ushr 6) and 63])
                out.append('=')
            }
        }
        return out.toString()
    }

    fun fromB64(value: String): ByteArray? {
        if (value.length % 4 != 0) return null
        val out = ByteArrayOutputStream(value.length / 4 * 3)
        var buffer = 0
        var bits = 0
        var padding = 0
        for (char in value) {
            if (char == '=') {
                padding++
                continue
            }
            if (padding > 0) return null
            val symbol = ALPHABET.indexOf(char)
            if (symbol < 0) return null
            buffer = (buffer shl 6) or symbol
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write((buffer ushr bits) and 0xff)
            }
        }
        if (padding > 2) return null
        if (bits > 0 && (buffer and ((1 shl bits) - 1)) != 0) return null
        return out.toByteArray()
    }

    fun utf8(value: String): ByteArray = value.toByteArray(Charsets.UTF_8)
}
