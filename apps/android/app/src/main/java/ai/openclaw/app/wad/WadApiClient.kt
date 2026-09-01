package ai.openclaw.app.wad

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

sealed class WadApiException(
  message: String,
) : Exception(message) {
  class Unreachable : WadApiException("Iànua non raggiungibile. Controlla la connessione Internet e riprova.")

  class Unauthorized : WadApiException("Sessione scaduta. Esegui di nuovo il login.")

  class Server(
    message: String,
  ) : WadApiException(message)
}

/**
 * Client minimo verso le API WAD/Iànua pubbliche (login a sessione + SIP),
 * speculare a WADAPIClient su iOS. La sessione vive in un cookie persistito
 * cifrato; credenziali e cookie non compaiono mai in log.
 */
class WadApiClient(
  storage: WadSessionStorage,
  baseUrl: String = DEFAULT_BASE_URL,
  client: OkHttpClient? = null,
) {
  companion object {
    const val DEFAULT_BASE_URL = "https://ianua.differen.it"
    private val jsonMediaType = "application/json".toMediaType()
  }

  private val baseHttpUrl: HttpUrl =
    requireNotNull(baseUrl.toHttpUrlOrNull()) { "Base URL WAD non valido" }
  private val json = Json { ignoreUnknownKeys = true }
  private val cookieJar = WadSessionCookieJar(storage)
  private val http: OkHttpClient =
    (client?.newBuilder() ?: OkHttpClient.Builder())
      .cookieJar(cookieJar)
      .build()

  fun hasSession(): Boolean = cookieJar.hasSession()

  fun clearSession() = cookieJar.clear()

  suspend fun login(
    username: String,
    password: String,
  ): WadCurrentUser {
    val payload =
      JsonObject(
        mapOf(
          "username" to JsonPrimitive(username),
          "password" to JsonPrimitive(password),
        ),
      )
    val data =
      request(
        "/api/login",
        method = "POST",
        body = payload.toString().toRequestBody(jsonMediaType),
        login = true,
      )
    return json.decodeFromString(WadUserEnvelope.serializer(), data).user
  }

  suspend fun me(): WadCurrentUser {
    val data = request("/api/me")
    return json.decodeFromString(WadUserEnvelope.serializer(), data).user
  }

  suspend fun logout() {
    request("/api/logout", method = "POST", body = ByteArray(0).toRequestBody(null))
    cookieJar.clear()
  }

  /** Credenziali SIP personali (interno Mercurio) per il softphone nativo. */
  suspend fun sipConfig(): WadSipConfig {
    val data = request("/api/sip/config")
    return json.decodeFromString(WadSipConfig.serializer(), data)
  }

  /** Rubrica degli interni (nome + interno + presenza PBX). */
  suspend fun sipDirectory(): List<WadSipContact> {
    val data = request("/api/sip/directory")
    return json.decodeFromString(WadSipDirectoryEnvelope.serializer(), data).contacts
  }

  private suspend fun request(
    path: String,
    method: String = "GET",
    body: RequestBody? = null,
    login: Boolean = false,
  ): String =
    withContext(Dispatchers.IO) {
      val url =
        baseHttpUrl
          .newBuilder()
          .encodedPath(path)
          .build()
      val request =
        Request
          .Builder()
          .url(url)
          .method(method, body)
          .build()
      val response =
        try {
          http.newCall(request).execute()
        } catch (_: IOException) {
          throw WadApiException.Unreachable()
        }
      response.use {
        val text = it.body.string()
        if (it.code == 401) {
          if (login) throw WadApiException.Server(parseError(text) ?: "Credenziali non valide")
          throw WadApiException.Unauthorized()
        }
        if (it.code !in 200..299) {
          throw WadApiException.Server(parseError(text) ?: "Errore WAD ${it.code}")
        }
        text
      }
    }

  private fun parseError(body: String): String? =
    try {
      json
        .decodeFromString(WadErrorEnvelope.serializer(), body)
        .error
        ?.takeIf { it.isNotBlank() }
    } catch (_: Throwable) {
      null
    }
}
