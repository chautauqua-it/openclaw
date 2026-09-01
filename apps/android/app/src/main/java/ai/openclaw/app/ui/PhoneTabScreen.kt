package ai.openclaw.app.ui

import ai.openclaw.app.NodeApp
import ai.openclaw.app.sip.SipCallStatus
import ai.openclaw.app.sip.SipRegistrationStatus
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat

private val dialPadRows =
  listOf(
    listOf("1", "2", "3"),
    listOf("4", "5", "6"),
    listOf("7", "8", "9"),
    listOf("*", "0", "#"),
  )

@Composable
fun PhoneTabScreen() {
  val context = LocalContext.current
  val app = context.applicationContext as NodeApp
  val manager = app.sipManager
  val state by manager.state.collectAsState()
  var username by remember { mutableStateOf("") }
  var password by remember { mutableStateOf("") }
  var number by remember { mutableStateOf("") }
  var pendingNumber by remember { mutableStateOf<String?>(null) }

  val microphonePermission =
    rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
      val requested = pendingNumber
      pendingNumber = null
      if (granted && requested != null) manager.call(requested)
    }

  LaunchedEffect(Unit) {
    if (app.wadApi.hasSession() && state.status == SipRegistrationStatus.Idle) {
      manager.registerFromExistingSession()
    }
  }

  Column(
    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(18.dp),
    verticalArrangement = Arrangement.spacedBy(14.dp),
  ) {
    Text(text = "Telefono Iànua", style = mobileTitle2, color = mobileText)
    Text(text = "Interno Mercurio personale", style = mobileBody, color = mobileTextSecondary)

    RegistrationCard(status = state.status, extension = state.extension, error = state.error)

    if (state.status == SipRegistrationStatus.Failed ||
      (!app.wadApi.hasSession() && state.status == SipRegistrationStatus.Idle)
    ) {
      OutlinedTextField(
        value = username,
        onValueChange = { username = it },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Utente Iànua") },
        singleLine = true,
      )
      OutlinedTextField(
        value = password,
        onValueChange = { password = it },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Password") },
        visualTransformation = PasswordVisualTransformation(),
        singleLine = true,
      )
      Button(
        onClick = { manager.loginAndRegister(username.trim(), password) },
        modifier = Modifier.fillMaxWidth(),
        enabled = username.isNotBlank() && password.isNotBlank() && state.status != SipRegistrationStatus.Loading,
      ) {
        Text("Accedi e registra il telefono")
      }
    }

    if (state.status == SipRegistrationStatus.Registered) {
      OutlinedTextField(
        value = number,
        onValueChange = { number = it.filter { char -> char.isDigit() || char in "+*#" } },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("Interno o numero") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
        singleLine = true,
      )
      dialPadRows.forEach { row ->
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
          row.forEach { digit ->
            OutlinedButton(
              onClick = { number += digit },
              modifier = Modifier.weight(1f).height(52.dp),
            ) {
              Text(digit, style = mobileHeadline)
            }
          }
        }
      }

      when (state.callStatus) {
        SipCallStatus.Idle ->
          Button(
            onClick = {
              if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
              ) {
                manager.call(number)
              } else {
                pendingNumber = number
                microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
              }
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = number.isNotBlank(),
          ) {
            Icon(Icons.Default.Call, contentDescription = null)
            Text("Chiama", modifier = Modifier.padding(start = 8.dp))
          }
        SipCallStatus.Incoming -> {
          Text(
            "Chiamata in arrivo da ${state.activePeer.orEmpty()}",
            style = mobileHeadline,
            color = mobileText,
          )
          Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(onClick = manager::answer, modifier = Modifier.weight(1f)) { Text("Rispondi") }
            HangUpButton(onClick = manager::hangUp, modifier = Modifier.weight(1f))
          }
        }
        SipCallStatus.Calling,
        SipCallStatus.Active,
        -> {
          Text(
            if (state.callStatus == SipCallStatus.Active) {
              "In chiamata con ${state.activePeer.orEmpty()}"
            } else {
              "Chiamata a ${state.activePeer.orEmpty()}"
            },
            style = mobileHeadline,
            color = mobileText,
          )
          HangUpButton(onClick = manager::hangUp, modifier = Modifier.fillMaxWidth())
        }
      }
    }
    Spacer(modifier = Modifier.height(8.dp))
  }
}

@Composable
private fun RegistrationCard(
  status: SipRegistrationStatus,
  extension: String?,
  error: String?,
) {
  Card(colors = CardDefaults.cardColors(containerColor = mobileCardSurface), modifier = Modifier.fillMaxWidth()) {
    Row(
      modifier = Modifier.fillMaxWidth().padding(16.dp),
      horizontalArrangement = Arrangement.SpaceBetween,
      verticalAlignment = Alignment.CenterVertically,
    ) {
      Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
          text = extension?.let { "Interno $it" } ?: "Telefono non registrato",
          style = mobileHeadline,
          color = mobileText,
        )
        Text(
          text = error ?: registrationLabel(status),
          style = mobileCaption1,
          color = if (error == null) mobileTextSecondary else mobileDanger,
        )
      }
      if (status == SipRegistrationStatus.Loading || status == SipRegistrationStatus.Registering) {
        CircularProgressIndicator()
      }
    }
  }
}

@Composable
private fun HangUpButton(
  onClick: () -> Unit,
  modifier: Modifier,
) {
  Button(
    onClick = onClick,
    modifier = modifier,
    colors = ButtonDefaults.buttonColors(containerColor = mobileDanger),
  ) {
    Icon(Icons.Default.CallEnd, contentDescription = null)
    Text("Termina", modifier = Modifier.padding(start = 8.dp))
  }
}

private fun registrationLabel(status: SipRegistrationStatus): String =
  when (status) {
    SipRegistrationStatus.Idle -> "Accedi per attivare l’interno"
    SipRegistrationStatus.Loading -> "Recupero configurazione Iànua"
    SipRegistrationStatus.Registering -> "Registrazione su Mercurio"
    SipRegistrationStatus.Registered -> "Registrato e pronto"
    SipRegistrationStatus.Failed -> "Registrazione non riuscita"
  }
