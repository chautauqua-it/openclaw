package ai.openclaw.app

import ai.openclaw.app.sip.IanuaSipManager
import ai.openclaw.app.wad.SecurePrefsWadSessionStorage
import ai.openclaw.app.wad.WadApiClient
import android.app.Application
import android.os.StrictMode

class NodeApp : Application() {
  val prefs: SecurePrefs by lazy { SecurePrefs(this) }
  val wadApi: WadApiClient by lazy { WadApiClient(SecurePrefsWadSessionStorage(prefs)) }
  val sipManager: IanuaSipManager by lazy { IanuaSipManager(this, wadApi) }

  @Volatile private var runtimeInstance: NodeRuntime? = null

  fun ensureRuntime(): NodeRuntime {
    runtimeInstance?.let { return it }
    return synchronized(this) {
      runtimeInstance ?: NodeRuntime(this, prefs).also { runtimeInstance = it }
    }
  }

  fun peekRuntime(): NodeRuntime? = runtimeInstance

  override fun onCreate() {
    super.onCreate()
    if (BuildConfig.DEBUG) {
      StrictMode.setThreadPolicy(
        StrictMode.ThreadPolicy
          .Builder()
          .detectAll()
          .penaltyLog()
          .build(),
      )
      StrictMode.setVmPolicy(
        StrictMode.VmPolicy
          .Builder()
          .detectAll()
          .penaltyLog()
          .build(),
      )
    }
  }
}
