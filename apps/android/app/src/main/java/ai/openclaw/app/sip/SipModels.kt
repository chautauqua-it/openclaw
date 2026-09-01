package ai.openclaw.app.sip

import ai.openclaw.app.wad.WadSipConfig

enum class SipRegistrationStatus { Idle, Loading, Registering, Registered, Failed }

enum class SipCallStatus { Idle, Incoming, Calling, Active }

data class SipState(
  val status: SipRegistrationStatus = SipRegistrationStatus.Idle,
  val extension: String? = null,
  val activePeer: String? = null,
  val callStatus: SipCallStatus = SipCallStatus.Idle,
  val error: String? = null,
)

internal fun WadSipConfig.validated(): WadSipConfig {
  require(domain.isNotBlank()) { "Dominio SIP mancante" }
  require(ext.matches(Regex("[0-9*#+]{2,16}"))) { "Interno SIP non valido" }
  require(password.isNotBlank()) { "Password SIP mancante" }
  return copy(domain = domain.trim(), ext = ext.trim())
}

internal fun sipUri(
  number: String,
  domain: String,
): String {
  val dialable = number.filter { it.isDigit() || it == '*' || it == '#' || it == '+' }
  require(dialable.isNotBlank()) { "Numero non valido" }
  return "sip:$dialable@${domain.trim()}"
}
