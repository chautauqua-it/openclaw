package ai.openclaw.app.authenticator

import ai.openclaw.app.gateway.GatewaySession
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.put

private const val TAG = "IanuaExecApproval"
private const val RESOLVE_TIMEOUT_MS = 12_000L

data class ExecApprovalPrompt(
  val id: String,
  val commandText: String,
  val host: String?,
  val agentId: String?,
  val expiresAtMs: Long,
  val challenge: AuthenticatorChallenge?,
  val errorText: String? = null,
  val isResolving: Boolean = false,
)

class ExecApprovalController(
  private val scope: CoroutineScope,
  private val session: GatewaySession,
) {
  private val json = Json { ignoreUnknownKeys = true }

  private val _prompt = MutableStateFlow<ExecApprovalPrompt?>(null)
  val prompt: StateFlow<ExecApprovalPrompt?> = _prompt.asStateFlow()

  fun handleGatewayEvent(
    event: String,
    payloadJson: String?,
  ): Boolean {
    when (event) {
      "exec.approval.requested" -> {
        val id = extractId(payloadJson) ?: return true
        scope.launch(Dispatchers.IO) { fetchPrompt(id) }
        return true
      }
      "exec.approval.resolved" -> {
        val id = extractId(payloadJson) ?: return true
        if (_prompt.value?.id == id) _prompt.value = null
        return true
      }
    }
    return false
  }

  fun dismiss() {
    _prompt.value = null
  }

  fun resolve(
    decision: String,
    enteredCode: String,
  ) {
    val current = _prompt.value ?: return
    if (current.isResolving) return
    _prompt.value = current.copy(isResolving = true, errorText = null)
    scope.launch(Dispatchers.IO) {
      try {
        val params =
          buildJsonObject {
            put("id", current.id)
            put("decision", decision)
            val challenge = current.challenge
            if (challenge != null) {
              val payload = AuthenticatorStore.makeResolution(challenge, enteredCode, decision)
              put("authenticator", json.encodeToJsonElement(AuthenticatorResolutionPayload.serializer(), payload))
            }
          }
        val res =
          session.requestDetailed(
            "exec.approval.resolve",
            params.toString(),
            timeoutMs = RESOLVE_TIMEOUT_MS,
          )
        if (res.ok) {
          _prompt.value = null
        } else {
          val message = res.error?.message ?: "Richiesta di approvazione non riuscita."
          _prompt.value = _prompt.value?.copy(isResolving = false, errorText = message)
        }
      } catch (err: Exception) {
        Log.w(TAG, "exec.approval.resolve failed", err)
        _prompt.value =
          _prompt.value?.copy(
            isResolving = false,
            errorText = err.message ?: "Richiesta di approvazione non riuscita.",
          )
      }
    }
  }

  private suspend fun fetchPrompt(id: String) {
    val payloadJson =
      try {
        session.request(
          "exec.approval.get",
          buildJsonObject { put("id", id) }.toString(),
          timeoutMs = RESOLVE_TIMEOUT_MS,
        )
      } catch (err: Exception) {
        Log.w(TAG, "exec.approval.get failed for $id", err)
        return
      }
    val obj = parseObject(payloadJson) ?: return
    val challenge =
      (obj["authenticator"] as? JsonObject)?.let { element ->
        try {
          json.decodeFromJsonElement<AuthenticatorChallenge>(element)
        } catch (err: Exception) {
          Log.w(TAG, "invalid authenticator challenge for $id", err)
          null
        }
      }
    if (challenge != null) {
      val ownIdentity = AuthenticatorStore.identity()
      if (ownIdentity == null || ownIdentity.personId != challenge.personId) {
        // Challenge addressed to another approver device: not ours to show.
        return
      }
      val validation = challenge.validationError()
      if (validation != null) {
        Log.w(TAG, "authenticator challenge rejected for $id: $validation")
        return
      }
    }
    _prompt.value =
      ExecApprovalPrompt(
        id = obj["id"].asStringOrNull() ?: id,
        commandText = obj["commandText"].asStringOrNull() ?: "",
        host = obj["host"].asStringOrNull(),
        agentId = obj["agentId"].asStringOrNull(),
        expiresAtMs = obj["expiresAtMs"].asLongOrNull() ?: 0L,
        challenge = challenge,
      )
  }

  private fun extractId(payloadJson: String?): String? {
    val obj = parseObject(payloadJson ?: return null) ?: return null
    return obj["id"].asStringOrNull()
  }

  private fun parseObject(payload: String): JsonObject? =
    try {
      json.parseToJsonElement(payload) as? JsonObject
    } catch (_: Exception) {
      null
    }

  private fun JsonElement?.asStringOrNull(): String? =
    when (this) {
      is JsonNull -> null
      is JsonPrimitive -> if (isString) content else content.takeIf { it != "null" }
      else -> null
    }

  private fun JsonElement?.asLongOrNull(): Long? = (this as? JsonPrimitive)?.content?.toLongOrNull()
}

// Enrollment payload for push.apns.register (direct transport). Android has no
// APNs token, so we derive a stable synthetic 64-hex token from the device id:
// it passes gateway validation and only means failed wake pushes for this node.
fun buildAuthenticatorEnrollmentPayload(
  deviceId: String,
  topic: String,
  identity: AuthenticatorIdentity,
): String =
  buildJsonObject {
    put("transport", "direct")
    put("token", sha256Hex("android-authenticator:$deviceId".toByteArray(Charsets.UTF_8)))
    put("topic", topic)
    put("environment", "sandbox")
    put(
      "authenticator",
      buildJsonObject {
        put("personId", identity.personId)
        put("publicKeyDer", identity.publicKeyDer)
      },
    )
  }.toString()
