package ai.openclaw.app.sip

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.linphone.core.Account
import org.linphone.core.Core
import org.linphone.core.CoreListenerStub
import org.linphone.core.Factory
import org.linphone.core.RegistrationState
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Collaudo manuale opt-in contro Mercurio. Le credenziali arrivano da un file
 * effimero nell'external-files dir dell'emulatore e vengono cancellate subito.
 */
@RunWith(AndroidJUnit4::class)
class MercurioRegistrationE2eTest {
  @Test
  fun registersProvisionedExtension() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val secretFile = File(context.getExternalFilesDir(null), SECRET_FILE)
    assertTrue("Fixture SIP effimera mancante", secretFile.isFile)
    val fixture = JSONObject(secretFile.readText())
    secretFile.delete()

    val extension = fixture.getString("extension")
    val domain = fixture.getString("domain")
    val password = fixture.getString("password")
    val factory = Factory.instance()
    val core = factory.createCore("", "", context)
    val completed = CountDownLatch(1)
    var finalState: RegistrationState? = null
    val listener =
      object : CoreListenerStub() {
        override fun onAccountRegistrationStateChanged(
          core: Core,
          account: Account,
          state: RegistrationState,
          message: String,
        ) {
          if (state == RegistrationState.Ok || state == RegistrationState.Failed) {
            finalState = state
            completed.countDown()
          }
        }
      }

    try {
      core.addListener(listener)
      core.isAutoIterateEnabled = true
      core.isPushNotificationEnabled = false
      assertEquals("Avvio Linphone", 0, core.start())
      val params = core.createAccountParams()
      params.identityAddress = factory.createAddress("sip:$extension@$domain")
      params.serverAddress = factory.createAddress("sip:$domain;transport=tcp")
      params.isRegisterEnabled = true
      val account = core.createAccount(params)
      core.addAuthInfo(factory.createAuthInfo(extension, "", password, "", "", domain))
      assertEquals("Account SIP aggiunto", 0, core.addAccount(account))
      core.defaultAccount = account
      assertTrue("Timeout registrazione SIP", completed.await(30, TimeUnit.SECONDS))
      assertEquals("Registrazione Mercurio", RegistrationState.Ok, finalState)
    } finally {
      core.removeListener(listener)
      core.stop()
      secretFile.delete()
    }
  }

  companion object {
    private const val SECRET_FILE = "sip-e2e.json"
  }
}
