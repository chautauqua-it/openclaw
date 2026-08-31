# Iànua iPhone: uscita da Tailscale

Stato inventario: 2026-08-31. Target ordinario: `https://ianua.differen.it`,
senza VPN/Tailscale obbligatoria. Tailscale può restare soltanto come percorso
legacy esplicito per strumenti interni, mai come default o prerequisito cliente.

## Inventario e classificazione

### Chat e API operative

- `Sources/WAD/WADNativeChatSheet.swift`: chat Iànua già su HTTPS pubblico e
  cookie tenant-bound.
- `Sources/WAD/IanuaSessionStore.swift`: sessione firmata e revocabile salvata
  nel Keychain; dominio già limitato a `ianua.differen.it`.
- `Sources/WAD/WADAPI.swift`: **migrato nella slice 1**; il fallback era il Mac
  mini via tailnet e alimentava SIP, Siri e alcune API chat WAD. Ora accetta
  solo il canonical host HTTPS pubblico e ignora fail-closed preferenze legacy.
- `Sources/WAD/WADSiriIntents.swift`: **migrato nella slice 1**; gli errori
  richiedono connettività Internet/login e non Tailscale.

Sostituzione: endpoint pubblico canonico, solo HTTPS, host/porta/path
fail-closed; sessione Iànua esistente e 401 definitivo verso login.

### Gateway/node

- `Sources/Gateway/GatewayConnectionController.swift`,
  `Sources/Settings/SettingsTab.swift` e onboarding conservano discovery LAN,
  host `.ts.net`, IP CGNAT Tailscale e messaggi dedicati.
- Deep link `openclaw://gateway` può ancora configurare un gateway arbitrario;
  la logica forza TLS fuori loopback e richiede pin TLS.
- Push gateway usa APNs diretto nelle build locali e relay nelle build
  TestFlight; il reconnect dipende ancora da una configurazione gateway attiva.

Sostituzione: introdurre un profilo Iànua pubblico preconfigurato su WSS/HTTPS,
separato dalla discovery legacy; allowlist host, TLS di sistema e sessione
revocabile. Deep link di produzione deve accettare solo intent Iànua firmati o
host pubblici consentiti, senza credenziali nell'URL. Push e reconnect devono
puntare al profilo pubblico.

### Authenticator

- `Sources/Authenticator/IanuaAuthenticatorClient.swift` usa già
  `https://ianua.differen.it`.
- Il modello è `approve-not-initiate` con chiave Secure Enclave/Face ID; TOTP a
  sei cifre resta fallback autorizzativo. Nessuna dipendenza Tailscale rilevata.

Sostituzione: nessuna sul trasporto; mantenere challenge monouso, scadenza,
replay reject e tenant binding nei test di regressione.

### Telefonia

- `Sources/WAD/WADPhone.swift` registra SIP/TCP direttamente sul dominio
  Mercurio; il traffico SIP non passa nel gateway né deve essere deviato in una
  VPN.
- Config, DND, rubrica e token PushKit passano da `WADAPIClient`; quindi il
  fallback tailnet rendeva indirettamente Tailscale necessario al bootstrap.
- `Sources/WAD/WADCallKit.swift` riceve PushKit e risveglia il core SIP.

Sostituzione: API di bootstrap su HTTPS pubblico Iànua; media e segnalazione SIP
restano dirette verso Mercurio. Smoke richiesti: config, registrazione, chiamata,
DND, PushKit/cold start e reconnect cellulare/Wi-Fi.

### Voce agente e diagnostica

- `Sources/Voice/SpockTalkManager.swift` e
  `Sources/Device/WADDeviceLog.swift` puntano ancora al daemon privato del Mac
  mini su `:40812` via tailnet.

Sostituzione: non esporre il daemon privato. Creare endpoint tenant-bound dietro
Iànua con token brevi e rate limit per la voce; inviare solo telemetria tecnica
minimizzata a un endpoint autenticato. Fino ad allora queste funzioni devono
essere indicate come interne/legacy e non bloccare l'uso ordinario.

## Piano fail-closed

1. **API pubbliche e ATS — implementato nella slice 1**: fallback tailnet
   eliminato da chat/Siri/SIP API; canonical host HTTPS e nessun arbitrary load
   globale (resta soltanto `NSAllowsLocalNetworking` per discovery/dev locale).
2. **Gateway pubblico**: profilo WSS Iànua, auth/sessione revocabile, tenant
   binding, reconnect e deep-link allowlist.
3. **Push**: relay ufficiale pubblico, registrazione tenant/device-bound e smoke
   foreground/background/cold start.
4. **Voce e diagnostica**: sostituire il daemon tailnet con API pubbliche
   minimizzate oppure disabilitare esplicitamente le funzioni legacy.
5. **Telefonia**: smoke end-to-end confermando che SIP resta fuori dal tunnel.
6. **Release**: suite automatica, smoke reale esterno, guard pipeline,
   TestFlight e controllo MetricKit.

## Rollback

Ogni slice resta in commit separato. Il rollback applicativo consiste nel
revert del singolo commit e in una build TestFlight precedente; nessuna modifica
a WatchGuard, switch, DNS, SIP o infrastruttura di rete è necessaria.
