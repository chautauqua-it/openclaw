package ai.openclaw.app.authenticator

import kotlinx.serialization.Serializable
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.Base64

@Serializable
data class AuthenticatorActionContext(
  val environment: String = "",
  val tenant: String = "",
  val audience: String = "",
  val actionId: String = "",
  val requestHash: String = "",
) {
  val isComplete: Boolean
    get() =
      listOf(environment, tenant, audience, actionId, requestHash).all { it.trim().isNotEmpty() } &&
        isHex64(requestHash)

  // Mirror of the iOS/gateway canonical encoding: for each field, a UInt32
  // big-endian length prefix followed by the UTF-8 bytes.
  fun canonicalData(): ByteArray {
    val output = ByteArrayOutputStream()
    for (value in listOf(environment, tenant, audience, actionId, requestHash)) {
      val bytes = value.toByteArray(Charsets.UTF_8)
      output.write(ByteBuffer.allocate(4).putInt(bytes.size).array())
      output.write(bytes)
    }
    return output.toByteArray()
  }
}

@Serializable
data class AuthenticatorChallenge(
  val personId: String = "",
  val initiatorDeviceId: String = "",
  val nonce: String = "",
  val action: AuthenticatorActionContext = AuthenticatorActionContext(),
  val target: String = "",
  val parameterSummary: String = "",
  val matchCodeDigits: Int = 0,
  val expiresAtUnix: Long = 0,
) {
  fun validationError(nowUnix: Long = System.currentTimeMillis() / 1000): String? {
    val nonceBytes = decodeBase64OrNull(nonce)
    val valid =
      listOf(personId, initiatorDeviceId, target, parameterSummary).all { it.trim().isNotEmpty() } &&
        isHex64(personId) &&
        isHex64(initiatorDeviceId) &&
        action.isComplete &&
        matchCodeDigits in 2..8 &&
        personId != initiatorDeviceId &&
        nonceBytes != null &&
        nonceBytes.size == 32 &&
        expiresAtUnix > nowUnix
    if (valid) return null
    if (personId == initiatorDeviceId) return "L'approvatore non può essere il dispositivo iniziatore."
    if (expiresAtUnix <= nowUnix) return "La richiesta è scaduta."
    return "La richiesta di approvazione è incompleta o non valida."
  }

  // Byte-identical to the iOS signingMessage and to the gateway digest input:
  // 0x02 || personId || initiatorDeviceId || nonce(32B) || enteredCode || decision || canonicalAction.
  fun signingMessage(
    enteredCode: String,
    decision: String,
  ): ByteArray {
    val nonceBytes = decodeBase64OrNull(nonce)
    require(
      validationError() == null &&
        enteredCode.length == matchCodeDigits &&
        enteredCode.all { it.isDigit() } &&
        (decision == "approve" || decision == "deny") &&
        nonceBytes != null,
    ) { "Richiesta Authenticator non valida o scaduta." }
    val output = ByteArrayOutputStream()
    output.write(byteArrayOf(0x02))
    output.write(personId.toByteArray(Charsets.UTF_8))
    output.write(initiatorDeviceId.toByteArray(Charsets.UTF_8))
    output.write(nonceBytes)
    output.write(enteredCode.toByteArray(Charsets.UTF_8))
    output.write(decision.toByteArray(Charsets.UTF_8))
    output.write(action.canonicalData())
    return output.toByteArray()
  }
}

@Serializable
data class AuthenticatorResolutionPayload(
  val enteredCode: String,
  val personId: String,
  val signatureDer: String,
  val publicKeyDer: String,
  val decision: String,
)

@Serializable
data class AuthenticatorIdentity(
  val personId: String,
  val publicKeyDer: String,
)

internal fun isHex64(value: String): Boolean = value.length == 64 && value.all { it in "0123456789abcdef" }

internal fun decodeBase64OrNull(value: String): ByteArray? =
  try {
    Base64.getDecoder().decode(value)
  } catch (_: IllegalArgumentException) {
    null
  }
