package ai.openclaw.app.sip

import ai.openclaw.app.wad.WadSipConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SipModelsTest {
  @Test
  fun `valid configuration is normalized`() {
    val result = WadSipConfig(domain = " pbx.example.test ", ext = "701", password = "secret").validated()
    assertEquals("pbx.example.test", result.domain)
    assertEquals("701", result.ext)
  }

  @Test
  fun `missing credentials fail closed`() {
    assertThrows(IllegalArgumentException::class.java) {
      WadSipConfig(domain = "pbx.example.test", ext = "701", password = "").validated()
    }
  }

  @Test
  fun `dialed number is sanitized before building SIP uri`() {
    assertEquals("sip:+39021234@pbx.example.test", sipUri("+39 02-1234", "pbx.example.test"))
  }

  @Test
  fun `empty dialed number fails closed`() {
    assertThrows(IllegalArgumentException::class.java) { sipUri("abc", "pbx.example.test") }
  }
}
