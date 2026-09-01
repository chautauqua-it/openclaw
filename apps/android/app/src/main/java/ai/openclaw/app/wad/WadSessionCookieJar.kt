package ai.openclaw.app.wad

import ai.openclaw.app.SecurePrefs
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * Persistenza minima del cookie di sessione WAD. I valori finiscono solo nello
 * store cifrato (EncryptedSharedPreferences via SecurePrefs), mai in log.
 */
interface WadSessionStorage {
  fun read(): String?

  fun write(value: String)

  fun clear()
}

class SecurePrefsWadSessionStorage(
  private val prefs: SecurePrefs,
) : WadSessionStorage {
  companion object {
    private const val key = "wad.session.cookies"
  }

  override fun read(): String? = prefs.getString(key)

  override fun write(value: String) = prefs.putString(key, value)

  override fun clear() = prefs.remove(key)
}

@Serializable
private data class StoredCookie(
  val name: String,
  val value: String,
  val domain: String,
  val path: String,
  val expiresAt: Long,
  val secure: Boolean,
  val hostOnly: Boolean,
)

class WadSessionCookieJar(
  private val storage: WadSessionStorage,
) : CookieJar {
  private val json = Json { ignoreUnknownKeys = true }
  private val serializer = ListSerializer(StoredCookie.serializer())
  private val lock = Any()
  private var cache: MutableMap<String, StoredCookie>? = null

  override fun saveFromResponse(
    url: HttpUrl,
    cookies: List<Cookie>,
  ) {
    synchronized(lock) {
      val current = loadLocked()
      for (cookie in cookies) {
        val stored =
          StoredCookie(
            name = cookie.name,
            value = cookie.value,
            domain = cookie.domain,
            path = cookie.path,
            expiresAt = cookie.expiresAt,
            secure = cookie.secure,
            hostOnly = cookie.hostOnly,
          )
        if (cookie.expiresAt <= System.currentTimeMillis() || cookie.value.isEmpty()) {
          current.remove(cookie.name)
        } else {
          current[cookie.name] = stored
        }
      }
      persistLocked(current)
    }
  }

  override fun loadForRequest(url: HttpUrl): List<Cookie> =
    synchronized(lock) {
      val current = loadLocked()
      val now = System.currentTimeMillis()
      val expired = current.values.filter { it.expiresAt <= now }
      if (expired.isNotEmpty()) {
        expired.forEach { current.remove(it.name) }
        persistLocked(current)
      }
      current.values
        .mapNotNull { it.toCookie() }
        .filter { it.matches(url) }
    }

  fun hasSession(): Boolean =
    synchronized(lock) {
      loadLocked().values.any { it.expiresAt > System.currentTimeMillis() }
    }

  fun clear() {
    synchronized(lock) {
      cache = mutableMapOf()
      storage.clear()
    }
  }

  private fun loadLocked(): MutableMap<String, StoredCookie> {
    cache?.let { return it }
    val loaded =
      try {
        storage
          .read()
          ?.takeIf { it.isNotBlank() }
          ?.let { json.decodeFromString(serializer, it) }
          .orEmpty()
      } catch (_: Throwable) {
        emptyList()
      }
    val map = loaded.associateBy { it.name }.toMutableMap()
    cache = map
    return map
  }

  private fun persistLocked(current: MutableMap<String, StoredCookie>) {
    cache = current
    if (current.isEmpty()) {
      storage.clear()
    } else {
      storage.write(json.encodeToString(serializer, current.values.toList()))
    }
  }

  private fun StoredCookie.toCookie(): Cookie? =
    try {
      val builder =
        Cookie
          .Builder()
          .name(name)
          .value(value)
          .path(path)
          .expiresAt(expiresAt)
      if (hostOnly) builder.hostOnlyDomain(domain) else builder.domain(domain)
      if (secure) builder.secure()
      builder.build()
    } catch (_: Throwable) {
      null
    }
}
