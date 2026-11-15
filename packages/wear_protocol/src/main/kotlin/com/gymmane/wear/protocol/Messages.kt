package com.gymmane.wear.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

object WearJson {
    fun text(value: String): JsonPrimitive = JsonPrimitive(value)

    fun number(value: Long): JsonPrimitive = JsonPrimitive(value)

    fun real(value: Double): JsonPrimitive = JsonPrimitive(value)

    fun bool(value: Boolean): JsonPrimitive = JsonPrimitive(value)

    fun objectOf(build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): JsonObject =
        buildJsonObject(build)

    fun parse(raw: ByteArray): JsonObject {
        val value = Json.parseToJsonElement(raw.decodeToString())
        return value as? JsonObject ?: throw WireFormatException("json object expected")
    }

    fun parse(text: String): JsonObject {
        val value = Json.parseToJsonElement(text)
        return value as? JsonObject ?: throw WireFormatException("json object expected")
    }

    fun bytes(value: JsonElement): ByteArray = value.toString().toByteArray(Charsets.UTF_8)

    fun string(obj: JsonObject, key: String): String? =
        (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun long(obj: JsonObject, key: String): Long? =
        (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

    fun int(obj: JsonObject, key: String): Int? = long(obj, key)?.toInt()

    fun double(obj: JsonObject, key: String): Double? =
        (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()

    fun bool(obj: JsonObject, key: String): Boolean? =
        (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()

    fun nested(obj: JsonObject, key: String): JsonObject? = obj[key] as? JsonObject

    fun array(obj: JsonObject, key: String): JsonArray? = obj[key] as? JsonArray

    fun nullValue(): JsonElement = JsonNull

    fun toMap(obj: JsonObject): Map<String, Any?> = obj.mapValues { (_, value) -> toAny(value) }

    fun toAny(value: JsonElement?): Any? = when (value) {
        null, is JsonNull -> null
        is JsonObject -> toMap(value)
        is JsonArray -> value.map { toAny(it) }
        is JsonPrimitive -> when {
            value.isString -> value.content
            value.content == "true" || value.content == "false" -> value.content.toBoolean()
            value.content.contains('.') || value.content.contains('e') || value.content.contains('E') ->
                value.content.toDoubleOrNull() ?: value.content
            else -> value.content.toLongOrNull() ?: value.content
        }
    }

    fun fromAny(value: Any?): JsonElement = when (value) {
        null -> JsonNull
        is JsonElement -> value
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Int -> JsonPrimitive(value)
        is Long -> JsonPrimitive(value)
        is Float -> JsonPrimitive(value)
        is Double -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Map<*, *> -> buildJsonObject {
            for ((key, item) in value) {
                if (key is String) put(key, fromAny(item))
            }
        }
        is Iterable<*> -> JsonArray(value.map { fromAny(it) })
        is Array<*> -> JsonArray(value.map { fromAny(it) })
        else -> JsonPrimitive(value.toString())
    }
}
