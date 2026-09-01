package ai.openclaw.app.sip

import ai.openclaw.app.wad.WadApiClient
import ai.openclaw.app.wad.WadSipConfig
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.linphone.core.Account
import org.linphone.core.Call
import org.linphone.core.Core
import org.linphone.core.CoreListenerStub
import org.linphone.core.Factory
import org.linphone.core.RegistrationState

/** Core SIP Android verso Mercurio. Credenziali e cookie non vengono mai loggati. */
class IanuaSipManager(
  context: Context,
  private val api: WadApiClient,
) {
  private val appContext = context.applicationContext
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val sipThread = HandlerThread("ianua-sip").apply { start() }
  private val sipHandler = Handler(sipThread.looper)
  private val _state = MutableStateFlow(SipState())
  val state: StateFlow<SipState> = _state.asStateFlow()

  private var core: Core? = null
  private var account: Account? = null
  private var domain: String? = null

  private val listener =
    object : CoreListenerStub() {
      override fun onAccountRegistrationStateChanged(
        core: Core,
        account: Account,
        state: RegistrationState,
        message: String,
      ) {
        val next =
          when (state) {
            RegistrationState.Ok -> SipRegistrationStatus.Registered
            RegistrationState.Failed -> SipRegistrationStatus.Failed
            RegistrationState.Progress -> SipRegistrationStatus.Registering
            else -> SipRegistrationStatus.Idle
          }
        _state.value =
          _state.value.copy(
            status = next,
            error = if (next == SipRegistrationStatus.Failed) message.ifBlank { "Registrazione SIP fallita" } else null,
          )
      }

      override fun onCallStateChanged(
        core: Core,
        call: Call,
        state: Call.State,
        message: String,
      ) {
        val nextCallStatus =
          when (state) {
            Call.State.IncomingReceived -> SipCallStatus.Incoming
            Call.State.OutgoingInit,
            Call.State.OutgoingProgress,
            Call.State.OutgoingRinging,
            -> SipCallStatus.Calling
            Call.State.Connected,
            Call.State.StreamsRunning,
            -> SipCallStatus.Active
            Call.State.End,
            Call.State.Error,
            Call.State.Released,
            -> SipCallStatus.Idle
            else -> return
          }
        _state.value =
          _state.value.copy(
            activePeer = if (nextCallStatus == SipCallStatus.Idle) null else call.remoteAddress.username,
            callStatus = nextCallStatus,
            error = if (state == Call.State.Error) message else null,
          )
      }
    }

  fun loginAndRegister(
    username: String,
    password: String,
  ) {
    _state.value = _state.value.copy(status = SipRegistrationStatus.Loading, error = null)
    scope.launch {
      runCatching {
        api.login(username, password)
        api.sipConfig().validated()
      }.onSuccess(::configure).onFailure(::showLoadFailure)
    }
  }

  fun registerFromExistingSession() {
    _state.value = _state.value.copy(status = SipRegistrationStatus.Loading, error = null)
    scope.launch {
      runCatching { api.sipConfig().validated() }
        .onSuccess(::configure)
        .onFailure(::showLoadFailure)
    }
  }

  private fun showLoadFailure(error: Throwable) {
    _state.value =
      _state.value.copy(
        status = SipRegistrationStatus.Failed,
        error = error.message ?: "Configurazione SIP non raggiungibile",
      )
  }

  private fun configure(config: WadSipConfig) {
    sipHandler.post {
      runCatching {
        tearDownOnSipThread()
        val factory = Factory.instance()
        val newCore = factory.createCore("", "", appContext)
        newCore.addListener(listener)
        newCore.isAutoIterateEnabled = true
        newCore.isPushNotificationEnabled = false
        check(newCore.start() == 0) { "Avvio motore SIP fallito" }

        val params = newCore.createAccountParams()
        params.identityAddress = factory.createAddress("sip:${config.ext}@${config.domain}")
        params.serverAddress = factory.createAddress("sip:${config.domain};transport=tcp")
        params.isRegisterEnabled = true
        val newAccount = newCore.createAccount(params)
        val auth = factory.createAuthInfo(config.ext, "", config.password, "", "", config.domain)
        newCore.addAuthInfo(auth)
        check(newCore.addAccount(newAccount) == 0) { "Account SIP non aggiunto" }
        newCore.defaultAccount = newAccount

        core = newCore
        account = newAccount
        domain = config.domain
        _state.value = SipState(status = SipRegistrationStatus.Registering, extension = config.ext)
      }.onFailure { error ->
        tearDownOnSipThread()
        _state.value =
          SipState(
            status = SipRegistrationStatus.Failed,
            extension = config.ext,
            error = error.message ?: "Telefono non inizializzabile",
          )
      }
    }
  }

  fun call(number: String) {
    sipHandler.post {
      runCatching {
        val currentCore = checkNotNull(core) { "Telefono SIP non avviato" }
        val currentDomain = checkNotNull(domain) { "Dominio SIP non configurato" }
        val address =
          checkNotNull(Factory.instance().createAddress(sipUri(number, currentDomain))) { "Indirizzo SIP non valido" }
        currentCore.inviteAddress(address)
      }.onFailure { error -> _state.value = _state.value.copy(error = error.message) }
    }
  }

  fun answer() {
    sipHandler.post { core?.currentCall?.accept() }
  }

  fun hangUp() {
    sipHandler.post { core?.terminateAllCalls() }
  }

  fun stop() {
    sipHandler.post {
      tearDownOnSipThread()
      _state.value = SipState()
    }
  }

  private fun tearDownOnSipThread() {
    account?.let { currentAccount -> core?.removeAccount(currentAccount) }
    core?.removeListener(listener)
    core?.stop()
    account = null
    core = null
    domain = null
  }
}
