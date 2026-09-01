package ai.openclaw.app.wad

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

private class InMemoryWadSessionStorage : WadSessionStorage {
  private var value: String? = null

  override fun read(): String? = value

  override fun write(value: String) {
    this.value = value
  }

  override fun clear() {
    value = null
  }
}

class WadApiClientTest {
  private fun MockWebServer.wadClient(storage: WadSessionStorage = InMemoryWadSessionStorage()) = WadApiClient(storage = storage, baseUrl = url("/").toString())

  @Test
  fun `login stores session cookie and sends it on next request`() {
    MockWebServer().use { server ->
      server.enqueue(
        MockResponse()
          .setHeader("Set-Cookie", "wad_session=abc123; Path=/; Max-Age=3600; HttpOnly")
          .setBody("""{"user":{"id":"u1","name":"Stefano","username":"stefano","role":"admin"}}"""),
      )
      server.enqueue(
        MockResponse()
          .setBody("""{"domain":"pbx.example.it","ext":"701","password":"s3cret","pickup_code":"*8"}"""),
      )
      server.start()

      val storage = InMemoryWadSessionStorage()
      val client = server.wadClient(storage)
      runBlocking {
        val user = client.login("stefano", "pw")
        assertEquals("u1", user.id)
        assertEquals("Stefano", user.name)
        assertTrue(client.hasSession())

        val sip = client.sipConfig()
        assertEquals("pbx.example.it", sip.domain)
        assertEquals("701", sip.ext)
        assertEquals("*8", sip.pickupCode)
      }

      val loginRequest = server.takeRequest()
      assertEquals("/api/login", loginRequest.path)
      assertNull(loginRequest.getHeader("Cookie"))

      val sipRequest = server.takeRequest()
      assertEquals("/api/sip/config", sipRequest.path)
      assertEquals("wad_session=abc123", sipRequest.getHeader("Cookie"))
    }
  }

  @Test
  fun `session cookie survives a new client instance on shared storage`() {
    MockWebServer().use { server ->
      server.enqueue(
        MockResponse()
          .setHeader("Set-Cookie", "wad_session=persist; Path=/; Max-Age=3600; HttpOnly")
          .setBody("""{"user":{"id":"u1","name":"Stefano"}}"""),
      )
      server.enqueue(MockResponse().setBody("""{"user":{"id":"u1","name":"Stefano"}}"""))
      server.start()

      val storage = InMemoryWadSessionStorage()
      runBlocking { server.wadClient(storage).login("stefano", "pw") }
      server.takeRequest()

      val restarted = server.wadClient(storage)
      assertTrue(restarted.hasSession())
      runBlocking { restarted.me() }
      assertEquals("wad_session=persist", server.takeRequest().getHeader("Cookie"))
    }
  }

  @Test
  fun `401 outside login maps to Unauthorized`() {
    MockWebServer().use { server ->
      server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"no session"}"""))
      server.start()

      val client = server.wadClient()
      try {
        runBlocking { client.me() }
        fail("expected Unauthorized")
      } catch (e: WadApiException.Unauthorized) {
        assertEquals("Sessione scaduta. Esegui di nuovo il login.", e.message)
      }
    }
  }

  @Test
  fun `401 on login surfaces server error message`() {
    MockWebServer().use { server ->
      server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"Credenziali errate"}"""))
      server.start()

      val client = server.wadClient()
      try {
        runBlocking { client.login("stefano", "wrong") }
        fail("expected Server")
      } catch (e: WadApiException.Server) {
        assertEquals("Credenziali errate", e.message)
      }
    }
  }

  @Test
  fun `server error without json body falls back to generic message`() {
    MockWebServer().use { server ->
      server.enqueue(MockResponse().setResponseCode(500).setBody("boom"))
      server.start()

      val client = server.wadClient()
      try {
        runBlocking { client.sipConfig() }
        fail("expected Server")
      } catch (e: WadApiException.Server) {
        assertEquals("Errore WAD 500", e.message)
      }
    }
  }

  @Test
  fun `logout clears the stored session`() {
    MockWebServer().use { server ->
      server.enqueue(
        MockResponse()
          .setHeader("Set-Cookie", "wad_session=bye; Path=/; Max-Age=3600; HttpOnly")
          .setBody("""{"user":{"id":"u1","name":"Stefano"}}"""),
      )
      server.enqueue(MockResponse().setBody("""{"ok":true}"""))
      server.start()

      val storage = InMemoryWadSessionStorage()
      val client = server.wadClient(storage)
      runBlocking {
        client.login("stefano", "pw")
        assertTrue(client.hasSession())
        client.logout()
      }
      assertFalse(client.hasSession())
      assertNull(storage.read())
    }
  }

  @Test
  fun `sip directory parses contacts with presence`() {
    MockWebServer().use { server ->
      server.enqueue(
        MockResponse().setBody(
          """{"contacts":[{"ext":"701","name":"Stefano","dnd":false,"registered":true,"busy":false},{"ext":"702","name":"Laura"}]}""",
        ),
      )
      server.start()

      val contacts = runBlocking { server.wadClient().sipDirectory() }
      assertEquals(2, contacts.size)
      assertEquals("701", contacts[0].ext)
      assertEquals(true, contacts[0].registered)
      assertEquals("Laura", contacts[1].name)
      assertNull(contacts[1].dnd)
    }
  }
}
