package ai.openclaw.app.wad

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class WadCurrentUser(
  val id: String,
  val name: String,
  val username: String? = null,
  val role: String? = null,
)

@Serializable
internal data class WadUserEnvelope(
  val user: WadCurrentUser,
)

/** Credenziali SIP personali (interno Mercurio) servite da /api/sip/config. */
@Serializable
data class WadSipConfig(
  val domain: String,
  val ext: String,
  val password: String,
  @SerialName("pickup_code") val pickupCode: String? = null,
)

@Serializable
data class WadSipContact(
  val ext: String,
  val name: String,
  val dnd: Boolean? = null,
  val registered: Boolean? = null,
  val busy: Boolean? = null,
)

@Serializable
internal data class WadSipDirectoryEnvelope(
  val contacts: List<WadSipContact>,
)

@Serializable
internal data class WadErrorEnvelope(
  val error: String? = null,
)
