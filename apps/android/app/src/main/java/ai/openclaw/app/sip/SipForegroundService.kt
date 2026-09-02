package ai.openclaw.app.sip

import ai.openclaw.app.MainActivity
import ai.openclaw.app.NodeApp
import ai.openclaw.app.R
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Tiene vivo il telefono SIP quando l'app va in background e notifica le chiamate in arrivo. */
class SipForegroundService : Service() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var stateJob: Job? = null

  override fun onCreate() {
    super.onCreate()
    ensureChannels()
    startForegroundPhone(buildStatusNotification(SipState(status = SipRegistrationStatus.Loading)))

    val manager = (application as NodeApp).sipManager
    stateJob =
      scope.launch {
        manager.state.collect { state ->
          if (sipServiceShouldStop(state)) {
            stopSelf()
            return@collect
          }
          startForegroundPhone(buildStatusNotification(state))
          if (state.callStatus == SipCallStatus.Incoming) {
            notificationManager().notify(INCOMING_NOTIFICATION_ID, buildIncomingNotification(state))
          } else {
            notificationManager().cancel(INCOMING_NOTIFICATION_ID)
          }
        }
      }
  }

  override fun onStartCommand(
    intent: Intent?,
    flags: Int,
    startId: Int,
  ): Int {
    val manager = (application as NodeApp).sipManager
    when (intent?.action) {
      ACTION_ANSWER -> {
        notificationManager().cancel(INCOMING_NOTIFICATION_ID)
        manager.answer()
        startActivity(launchIntent().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
      }
      ACTION_DECLINE -> {
        notificationManager().cancel(INCOMING_NOTIFICATION_ID)
        manager.hangUp()
      }
      ACTION_STOP -> {
        manager.stop()
        stopSelf()
        return START_NOT_STICKY
      }
    }
    return START_STICKY
  }

  override fun onDestroy() {
    stateJob?.cancel()
    scope.cancel()
    notificationManager().cancel(INCOMING_NOTIFICATION_ID)
    super.onDestroy()
  }

  override fun onBind(intent: Intent?) = null

  private fun notificationManager(): NotificationManager = getSystemService(NotificationManager::class.java)

  private fun ensureChannels() {
    val mgr = notificationManager()
    mgr.createNotificationChannel(
      NotificationChannel(STATUS_CHANNEL_ID, "Telefono", NotificationManager.IMPORTANCE_LOW).apply {
        description = "Stato registrazione telefono Iànua"
        setShowBadge(false)
      },
    )
    mgr.createNotificationChannel(
      NotificationChannel(INCOMING_CHANNEL_ID, "Chiamate in arrivo", NotificationManager.IMPORTANCE_HIGH).apply {
        description = "Chiamate in arrivo sull'interno Iànua"
      },
    )
  }

  private fun launchIntent(): Intent =
    Intent(this, MainActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }

  private fun buildStatusNotification(state: SipState): Notification {
    val launchPending =
      PendingIntent.getActivity(
        this,
        10,
        launchIntent(),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    val stopPending =
      PendingIntent.getService(
        this,
        11,
        Intent(this, SipForegroundService::class.java).setAction(ACTION_STOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    return NotificationCompat
      .Builder(this, STATUS_CHANNEL_ID)
      .setSmallIcon(R.mipmap.ic_launcher)
      .setContentTitle(sipNotificationTitle(state))
      .setContentText(sipNotificationText(state))
      .setContentIntent(launchPending)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
      .addAction(0, "Disattiva telefono", stopPending)
      .build()
  }

  private fun buildIncomingNotification(state: SipState): Notification {
    val answerPending =
      PendingIntent.getService(
        this,
        12,
        Intent(this, SipForegroundService::class.java).setAction(ACTION_ANSWER),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    val declinePending =
      PendingIntent.getService(
        this,
        13,
        Intent(this, SipForegroundService::class.java).setAction(ACTION_DECLINE),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    val fullScreenPending =
      PendingIntent.getActivity(
        this,
        14,
        launchIntent(),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    return NotificationCompat
      .Builder(this, INCOMING_CHANNEL_ID)
      .setSmallIcon(R.mipmap.ic_launcher)
      .setContentTitle("Chiamata in arrivo")
      .setContentText(state.activePeer ?: "Interno sconosciuto")
      .setCategory(NotificationCompat.CATEGORY_CALL)
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .setOngoing(true)
      .setFullScreenIntent(fullScreenPending, true)
      .addAction(0, "Rispondi", answerPending)
      .addAction(0, "Rifiuta", declinePending)
      .build()
  }

  private fun startForegroundPhone(notification: Notification) {
    ServiceCompat.startForeground(
      this,
      STATUS_NOTIFICATION_ID,
      notification,
      ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL,
    )
  }

  companion object {
    private const val STATUS_CHANNEL_ID = "sip_phone"
    private const val INCOMING_CHANNEL_ID = "sip_incoming_calls"
    private const val STATUS_NOTIFICATION_ID = 20
    private const val INCOMING_NOTIFICATION_ID = 21

    internal const val ACTION_ANSWER = "ai.openclaw.app.action.SIP_ANSWER"
    internal const val ACTION_DECLINE = "ai.openclaw.app.action.SIP_DECLINE"
    internal const val ACTION_STOP = "ai.openclaw.app.action.SIP_STOP"

    fun start(context: Context) {
      context.startForegroundService(Intent(context, SipForegroundService::class.java))
    }
  }
}

internal fun sipServiceShouldStop(state: SipState): Boolean =
  state.callStatus == SipCallStatus.Idle &&
    (state.status == SipRegistrationStatus.Idle || state.status == SipRegistrationStatus.Failed)

internal fun sipNotificationTitle(state: SipState): String =
  when (state.callStatus) {
    SipCallStatus.Incoming -> "Chiamata in arrivo"
    SipCallStatus.Calling -> "Chiamata in corso"
    SipCallStatus.Active -> "In conversazione"
    SipCallStatus.Idle ->
      when (state.status) {
        SipRegistrationStatus.Registered -> "Telefono Iànua · Registrato"
        SipRegistrationStatus.Registering, SipRegistrationStatus.Loading -> "Telefono Iànua · Registrazione…"
        else -> "Telefono Iànua"
      }
  }

internal fun sipNotificationText(state: SipState): String =
  when {
    state.callStatus != SipCallStatus.Idle -> state.activePeer ?: "Interno sconosciuto"
    state.status == SipRegistrationStatus.Registered -> "Interno ${state.extension.orEmpty()} pronto".trim()
    else -> state.extension?.let { "Interno $it" } ?: "In attesa della configurazione"
  }
