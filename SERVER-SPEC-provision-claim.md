# Spec: estensione `gateway` nella risposta di `POST /api/provision/claim`

Stato: **proposta, non implementata**. Il backend che serve questa rotta (atteso come
`provisioning.mjs` per indicazione del ticket) non esiste in questo monorepo
(`/Users/polpo/claw/core/openclaw`) — verificato con `grep -r "provision/claim"`,
`grep -r "PROOF_CONTEXT"` e `find . -iname "*provision*"`, tutti senza risultati
server-side. Vive in un repo/servizio Iànua separato a cui questo worker non ha
accesso. Questo documento è quindi una spec per chi ha accesso a quel repo
(Aletov/Stefano), non una patch.

## Perché serve

Il QR nella pagina profilo Iànua (`ianua://provision?s=<slug>&t=<token>`) oggi,
tramite `/api/provision/claim`, autentica solo la sessione WAD (login utente) e
riporta lo stato del setup code del gateway (`gateway.status`), ma **non porta le
credenziali di connessione al gateway stesso**. Per il rollout a 50 telefoni si
vuole un solo QR, scansionato una volta nel wizard di primo avvio, che porti a
termine sia il login sia il collegamento del nodo al gateway. Senza questo campo,
il fix app-side (già applicato, vedi `NOTES-RILANCIO.md`) può solo riconoscere il
QR e fare login; il collegamento gateway resta un passo separato per l'operatore.

## Contratto attuale (invariato, per compatibilità con i QR già emessi — build 7)

```jsonc
200 OK
{
  "tenant": { "slug": "...", "nome": "..." },
  "user": { "id": 1, "email": "...", "nome": "..." },
  "device": { "id": "...", "trust": "..." },
  "gateway": { "status": "pending" }   // opzionale
}
```

## Contratto proposto (retro-compatibile, campi aggiuntivi opzionali)

```jsonc
200 OK
{
  "tenant": { "slug": "...", "nome": "..." },
  "user": { "id": 1, "email": "...", "nome": "..." },
  "device": { "id": "...", "trust": "..." },
  "gateway": {
    "status": "connected",          // invariato
    "url": "wss://host:port/path",  // NUOVO, opzionale — stesso formato websocketURL già usato da /pair
    "bootstrapToken": "...",        // NUOVO, opzionale
    "token": "...",                 // NUOVO, opzionale
    "password": "..."               // NUOVO, opzionale
  }
}
```

Regole:

- Tutti e 4 i campi nuovi sono **opzionali**. Un server che non li invia (comportamento
  attuale) continua a funzionare: l'app mostra un messaggio esplicito che dice che il
  QR ha fatto login ma non porta credenziali gateway, invece di fallire silenziosamente.
- `url` deve essere uno scheme `ws://` o `wss://`. Per `ws://` (cleartext) vale la
  stessa regola già in vigore per i setup code `/pair`: l'host deve essere nella LAN
  privata (`LoopbackHost.isLocalNetworkHost`), altrimenti l'app scarta il link. Per
  hostname pubblici va usato `wss://`.
  Vedi `apps/shared/OpenClawKit/Sources/OpenClawKit/DeepLinks.swift:80` (stessa regola
  per `fromSetupCode`) e il commento a riga 76-79 che rimanda a
  `src/pairing/setup-code.ts:isMobilePairingCleartextAllowedHost` come sorgente di
  verità lato server per questo gate.
- Path del gateway (se dietro reverse proxy): stringa con `/` iniziale, niente `..`
  (traversal rifiutato). Stringa vuota o `/` equivalgono ad assente.
- Porta di default se omessa nell'URL: 443 per `wss`, 18789 per `ws` — stessa
  convenzione dei setup code `/pair`.

## Consumo lato app (già pronto, in attesa solo di questi campi server)

- `IanuaProvisioningClient.Claim.Gateway` (`apps/ios/Sources/Provisioning/IanuaProvisioningClient.swift`)
  decodifica già `url`/`bootstrapToken`/`token`/`password` come opzionali.
- `Claim.Gateway.connectDeepLink` costruisce un `GatewayConnectDeepLink` via
  `GatewayConnectDeepLink.fromProvisionClaim(url:bootstrapToken:token:password:)`
  (`apps/shared/OpenClawKit/Sources/OpenClawKit/DeepLinks.swift`), che applica le
  stesse regole di validazione host/path di `fromSetupCode`.
- `OnboardingWizardView.claimProvisionLink(_:)` (`apps/ios/Sources/Onboarding/OnboardingWizardView.swift`)
  chiama `claim.gateway?.connectDeepLink`: se presente, incatena
  `handleScannedLink(_:)` (lo stesso percorso di collegamento gateway già usato dai
  setup code `/pair`) così il login e il collegamento del nodo avvengono da un solo
  QR; se assente, mostra un messaggio esplicito e non ambiguo invece di bloccarsi.

## Cosa NON è incluso in questa spec

- Nessuna modifica al meccanismo di generazione/rotazione dei setup code del gateway
  (`gateway.status`, valori come `pending`/`connected`): quella logica resta del tutto
  server-side e fuori da questo lavoro.
- Nessun cambiamento all'autenticazione/proof-of-possession (`PROOF_CONTEXT`,
  `provision_prova_non_valida`, ecc.): già implementata e testata, invariata.
- Nessun deploy: questo file è solo la spec del contratto per chi implementerà la
  modifica nel repo server reale.
