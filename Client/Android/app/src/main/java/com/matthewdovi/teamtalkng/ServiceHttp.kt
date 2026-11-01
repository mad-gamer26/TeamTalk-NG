/*
 * HTTP with TeamTalk NG's service, and small JSON helpers.
 */
package com.matthewdovi.teamtalkng

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object ServiceHttp {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()
    val socketClient: OkHttpClient = client.newBuilder()
        .readTimeout(0, TimeUnit.SECONDS)
        .pingInterval(30, TimeUnit.SECONDS)
        .build()

    class Reply(val status: Int, val body: ByteArray) {
        val ok get() = status in 200..299
        val error: String?
            get() = runCatching { JSONObject(String(body)).optString("error").ifEmpty { null } }.getOrNull()
    }

    /** One request; throws IOException when the service can't be reached. */
    suspend fun send(method: String, url: String, token: String?, json: Any? = null, data: ByteArray? = null): Reply =
        withContext(Dispatchers.IO) {
            val body = when {
                json != null -> json.toString().toRequestBody("application/json".toMediaType())
                data != null -> data.toRequestBody("application/octet-stream".toMediaType())
                method == "POST" || method == "PUT" -> ByteArray(0).toRequestBody(null)
                else -> null
            }
            val builder = Request.Builder().url(url).method(method, body)
            if (token != null) builder.header("Authorization", "Bearer $token")
            client.newCall(builder.build()).execute().use { Reply(it.code, it.body?.bytes() ?: ByteArray(0)) }
        }
}

fun JSONObject.str(key: String): String = if (isNull(key)) "" else optString(key)
fun JSONObject.intOrNull(key: String): Int? = if (isNull(key) || !has(key)) null else optInt(key)
fun JSONObject.longOrNull(key: String): Long? = if (isNull(key) || !has(key)) null else optLong(key)
fun JSONObject.objOrNull(key: String): JSONObject? = if (isNull(key)) null else optJSONObject(key)
inline fun <T> JSONArray?.mapObjects(transform: (JSONObject) -> T): List<T> =
    if (this == null) emptyList() else (0 until length()).map { transform(getJSONObject(it)) }
fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).map { optString(it) }
fun JSONArray?.ints(): List<Int> = if (this == null) emptyList() else (0 until length()).map { optInt(it) }
