package ai.openclaw.app.authenticator

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Log
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64

private const val TAG = "IanuaAuthenticator"
private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
private const val KEY_ALIAS = "ianua.authenticator.p256"

// Android mirror of the iOS AuthenticatorStore: one P-256 signing key in the
// hardware keystore (StrongBox when available), identity = SHA256(SPKI DER).
// Biometric gating happens at the UI layer, like the iOS LAContext flow.
object AuthenticatorStore {
  fun identity(): AuthenticatorIdentity? =
    try {
      val der = ensurePublicKey().encoded
      AuthenticatorIdentity(
        personId = sha256Hex(der),
        publicKeyDer = Base64.getEncoder().encodeToString(der),
      )
    } catch (err: Exception) {
      Log.w(TAG, "authenticator identity unavailable", err)
      null
    }

  fun makeResolution(
    challenge: AuthenticatorChallenge,
    enteredCode: String,
    decision: String,
  ): AuthenticatorResolutionPayload {
    val der = ensurePublicKey().encoded
    val personId = sha256Hex(der)
    require(personId == challenge.personId) {
      "La richiesta è destinata a un altro dispositivo approvatore."
    }
    val message = challenge.signingMessage(enteredCode, decision)
    val signature = Signature.getInstance("SHA256withECDSA")
    signature.initSign(privateKey())
    signature.update(message)
    return AuthenticatorResolutionPayload(
      enteredCode = enteredCode,
      personId = personId,
      signatureDer = Base64.getEncoder().encodeToString(signature.sign()),
      publicKeyDer = Base64.getEncoder().encodeToString(der),
      decision = decision,
    )
  }

  private fun ensurePublicKey(): PublicKey {
    val keyStore = loadKeyStore()
    val existing = keyStore.getCertificate(KEY_ALIAS)?.publicKey
    if (existing != null) return existing
    return generateKeyPair()
  }

  private fun privateKey(): PrivateKey {
    val keyStore = loadKeyStore()
    return keyStore.getKey(KEY_ALIAS, null) as? PrivateKey
      ?: error("Chiave Authenticator non disponibile nel keystore.")
  }

  private fun generateKeyPair(): PublicKey {
    try {
      return generateKeyPair(strongBox = true)
    } catch (err: StrongBoxUnavailableException) {
      Log.i(TAG, "StrongBox unavailable, falling back to TEE keystore", err)
    } catch (err: Exception) {
      Log.w(TAG, "StrongBox key generation failed, falling back to TEE keystore", err)
    }
    return generateKeyPair(strongBox = false)
  }

  private fun generateKeyPair(strongBox: Boolean): PublicKey {
    val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE_PROVIDER)
    val spec =
      KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
        .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
        .setDigests(KeyProperties.DIGEST_SHA256)
        .apply { if (strongBox) setIsStrongBoxBacked(true) }
        .build()
    generator.initialize(spec)
    return generator.generateKeyPair().public
  }

  private fun loadKeyStore(): KeyStore =
    KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
}

internal fun sha256Hex(bytes: ByteArray): String =
  MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
