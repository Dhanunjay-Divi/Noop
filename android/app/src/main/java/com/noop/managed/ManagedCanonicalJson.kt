package com.noop.managed

import org.json.JSONArray
import org.json.JSONObject

internal object ManagedCanonicalJson {
    fun encode(value: JSONObject): String = encodeValue(value)

    fun equal(left: JSONObject, right: JSONObject): Boolean =
        encode(left) == encode(right)

    private fun encodeValue(value: Any?): String = when {
        value == null || value === JSONObject.NULL -> "null"
        value is JSONObject -> value.keys().asSequence().toList().sorted()
            .joinToString(prefix = "{", postfix = "}", separator = ",") { key ->
                "${JSONObject.quote(key)}:${encodeValue(value.get(key))}"
            }
        value is JSONArray -> (0 until value.length())
            .joinToString(prefix = "[", postfix = "]", separator = ",") { index ->
                encodeValue(value.get(index))
            }
        value is String -> JSONObject.quote(value)
        value is Boolean -> value.toString()
        value is Number -> runCatching { JSONObject.numberToString(value) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        else -> throw ManagedStorageException.InvalidResponse()
    }
}
