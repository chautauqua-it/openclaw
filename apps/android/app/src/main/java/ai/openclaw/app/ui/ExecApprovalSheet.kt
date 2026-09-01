package ai.openclaw.app.ui

import ai.openclaw.app.MainViewModel
import ai.openclaw.app.authenticator.ExecApprovalPrompt
import android.content.Context
import android.hardware.biometrics.BiometricManager.Authenticators
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

@Composable
fun ExecApprovalHost(viewModel: MainViewModel) {
  val prompt by viewModel.execApprovalPrompt.collectAsState()
  val current = prompt ?: return
  ExecApprovalDialog(
    prompt = current,
    onResolve = { decision, code -> viewModel.resolveExecApproval(decision, code) },
    onDismiss = { viewModel.dismissExecApproval() },
  )
}

@Composable
private fun ExecApprovalDialog(
  prompt: ExecApprovalPrompt,
  onResolve: (decision: String, enteredCode: String) -> Unit,
  onDismiss: () -> Unit,
) {
  val context = LocalContext.current
  var codeInput by remember(prompt.id) { mutableStateOf("") }
  var biometricError by remember(prompt.id) { mutableStateOf<String?>(null) }
  val needsCode = prompt.challenge != null
  val requiredDigits = prompt.challenge?.matchCodeDigits ?: 0
  val codeReady = !needsCode || (codeInput.length == requiredDigits && codeInput.all { it.isDigit() })
  val busy = prompt.isResolving

  fun resolveGated(decision: String) {
    biometricError = null
    if (!needsCode) {
      onResolve(decision, codeInput)
      return
    }
    authenticateWithBiometrics(
      context = context,
      subtitle = if (decision == "approve") "Conferma per approvare il comando" else "Conferma per negare il comando",
      onSuccess = { onResolve(decision, codeInput) },
      onError = { message -> biometricError = message },
    )
  }

  AlertDialog(
    onDismissRequest = { if (!busy) onDismiss() },
    containerColor = mobileCardSurface,
    title = { Text("Iànua · Sblocco richiesto", style = mobileHeadline, color = mobileText) },
    text = {
      Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
          prompt.commandText.ifBlank { "Richiesta di approvazione dal gateway." },
          style = mobileCallout.copy(fontFamily = FontFamily.Monospace),
          color = mobileText,
          maxLines = 6,
          overflow = TextOverflow.Ellipsis,
        )
        val origin = listOfNotNull(prompt.agentId?.let { "Agente: $it" }, prompt.host?.let { "Host: $it" })
        if (origin.isNotEmpty()) {
          Text(origin.joinToString(" · "), style = mobileCaption1, color = mobileTextSecondary)
        }
        if (needsCode) {
          Text(
            "Inserisci il codice a $requiredDigits cifre mostrato sullo schermo che ha avviato la richiesta.",
            style = mobileCaption1,
            color = mobileTextSecondary,
          )
          OutlinedTextField(
            value = codeInput,
            onValueChange = { value ->
              if (value.length <= requiredDigits && value.all { it.isDigit() }) codeInput = value
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = !busy,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
            label = { Text("Codice") },
          )
        }
        val errorText = biometricError ?: prompt.errorText
        if (errorText != null) {
          Text(errorText, style = mobileCaption1, color = mobileDanger)
        }
        if (busy) {
          CircularProgressIndicator(color = mobileAccent)
        }
      }
    },
    confirmButton = {
      TextButton(
        onClick = { resolveGated("approve") },
        enabled = codeReady && !busy,
        colors = ButtonDefaults.textButtonColors(contentColor = mobileAccent),
      ) {
        Text("Approva")
      }
    },
    dismissButton = {
      TextButton(
        onClick = { resolveGated("deny") },
        enabled = codeReady && !busy,
        colors = ButtonDefaults.textButtonColors(contentColor = mobileDanger),
      ) {
        Text("Nega")
      }
    },
  )
}

private fun authenticateWithBiometrics(
  context: Context,
  subtitle: String,
  onSuccess: () -> Unit,
  onError: (String) -> Unit,
) {
  val prompt =
    BiometricPrompt.Builder(context)
      .setTitle("Iànua Authenticator")
      .setSubtitle(subtitle)
      .setAllowedAuthenticators(Authenticators.BIOMETRIC_STRONG or Authenticators.DEVICE_CREDENTIAL)
      .build()
  prompt.authenticate(
    CancellationSignal(),
    ContextCompat.getMainExecutor(context),
    object : BiometricPrompt.AuthenticationCallback() {
      override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
        onSuccess()
      }

      override fun onAuthenticationError(
        errorCode: Int,
        errString: CharSequence?,
      ) {
        onError(errString?.toString() ?: "Autenticazione biometrica non riuscita.")
      }
    },
  )
}
