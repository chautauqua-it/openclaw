# NOTES RILANCIO — QR Provisioning build 8

Aggiornato: 2026-09-19. Scritto da un nuovo run dopo il context-overflow del run precedente (che non aveva salvato nulla).

## STATO: causa radice trovata e provata nel codice. In corso: fix + test + spec server.

## CAUSA RADICE (provata, non teorica)

L'app ha **due sottosistemi QR completamente separati e non comunicanti**:

1. **Gateway pairing** (Mac-side `/pair`): `OnboardingWizardView.swift` + `QRScannerView.swift` + `GatewayConnectDeepLink` (`apps/shared/OpenClawKit/Sources/OpenClawKit/DeepLinks.swift`). Capisce SOLO: (a) JSON base64url via `GatewayConnectDeepLink.fromSetupCode` (b) `openclaw://gateway?...` via `DeepLinkParser.parse`. Questo è il flusso fixato in build 7 (allineamento host LAN).
2. **Attivazione account Iànua** (QR dal profilo utente): `IanuaProvisionLink.swift` + `IanuaProvisioningClient.swift` + `IanuaProvisioningView.swift`. Capisce `ianua://provision?s=<slug>&t=<token>`. Questo flusso è raggiungibile SOLO da `IanuaLoginView` dentro `WADNativeChatSheet.swift` (bottone "Attiva con QR", riga ~594-598), cioè dalla schermata di login della Chat WAD — **non dal wizard di primo avvio**.

**Bug esatto**: `QRScannerView.swift` righe 61-91 (`dataScanner(didAdd:)`) e `OnboardingWizardView.swift` righe 197-221 (percorso "scegli da Foto") provano SOLO `GatewayConnectDeepLink.fromSetupCode(payload)` e poi `DeepLinkParser.parse(...)` (caso `.gateway`). **Non chiamano mai `IanuaProvisionLink.parse`.** Quando Stefano inquadra il QR del profilo nel wizard, il payload fallisce entrambi i tentativi e cade nel messaggio generico:

- `QRScannerView.swift:88-89`: "This QR code isn't a valid pairing code. It may be expired, or this app version may not support it."
- `OnboardingWizardView.swift:220`: "No valid QR code found in the selected image."

Questo è esattamente il fallimento muto/generico lamentato: non è un bug nel parser `IanuaProvisionLink` (le regex sono corrette, punto 3 della diagnosi originale è confermato ancora valido), è un **bug di instradamento**: il wizard non prova mai il parser giusto per quel tipo di QR.

Confermato anche: `IanuaDeviceKeyStore`/Secure Enclave (candidato 5a della diagnosi originale) NON è la causa — i suoi errori (`IanuaDeviceKeyError`, `IanuaDeviceKey.swift:4-16`) sono già distinti e localizzati correttamente; semplicemente non si arriva mai a chiamarli dal wizard.

## SECONDA SCOPERTA — anche risolvendo il routing, manca il collegamento gateway

`IanuaProvisioningClient.Claim.Gateway` (`IanuaProvisioningClient.swift:75-85`) porta oggi solo `status: String`. Il commento in codice (righe 82-85) dice esplicitamente che il collegamento al gateway è un passo "suo", non ancora implementato: la claim NON restituisce host/port/token/password del gateway. Quindi anche aggiungendo il routing lato app, un QR-solo-profilo oggi autentica la sessione Chat WAD (login) ma NON collega il nodo/gateway — serve che il server aggiunga i campi di connessione gateway alla risposta di `/api/provision/claim`.

## BLOCCANTE DA VERIFICARE CON ALETOV/STEFANO — non indovinato

Il ticket dice "il server è nello stesso repo monorepo (cerca provisioning.mjs)". Ho cercato in tutto questo worktree (che è un worktree reale di `/Users/polpo/claw/core/openclaw`, non uno sparse-checkout — verificato via `cat .git` → punta a `.git/worktrees/qr-provisioning-build8` dello stesso repo, quindi stesso albero file):

- `grep -r "provision/claim"` → zero risultati fuori da `IanuaProvisioningClient.swift` (il client, non il server)
- `grep -r "PROOF_CONTEXT"` / `"ianua-provision-v1"` → zero risultati server-side
- `find . -iname "*provision*"` → solo i 3 file Swift già citati, nessun `provisioning.mjs`

**Il file `provisioning.mjs` non esiste in questo monorepo.** Il backend che implementa `/api/provision/claim` (chiamato da `IanuaProvisioningClient.swift:114` su `WADAPIClient.shared.baseURL`, un endpoint pubblico Iànua distinto dal gateway self-hosted) deve vivere in un repo/servizio separato a cui non ho accesso (fuori dal clone assegnato, per regola dura). Non posso quindi scrivere una modifica reale al file server citato nel ticket — al massimo posso scrivere una **spec** del contratto di risposta che serve, per chi ha accesso a quel repo.

Procedo comunque con: (1) fix app-side del routing e dei messaggi d'errore, (2) estensione tollerante di `Claim.Gateway` per accettare campi di connessione opzionali quando il server li aggiungerà (retro-compatibile se assenti → messaggio esplicito, non crash), (3) documento di spec per la modifica server. Se Aletov conosce il repo/percorso reale di `provisioning.mjs`, va detto esplicitamente — non lo sto indovinando.

## PROSSIMI PASSI (in ordine)

1. [FATTO] Diagnosi provata.
2. [FATTO] Test scritti (vedi sotto), verdi dopo il fix.
3. [FATTO] Fix app applicato (vedi FILE TOCCATI).
4. [FATTO] `Claim.Gateway` esteso con campi opzionali di connessione + `connectDeepLink`.
5. [FATTO — vedi RISULTATI TEST] `swift test` sul pacchetto condiviso + target iOS su simulatore.
6. [DA FARE] Scrivere spec del contratto server (documento, non codice — il file server non è in questo repo, vedi BLOCCANTE sopra).
7. [DA FARE] Build 8 unica + upload TestFlight, solo a step 5 verde (verde ora — procedo).

## FIX APPLICATO (app-side)

- **`apps/ios/Sources/Onboarding/WizardQRRecognizer.swift` (nuovo)**: unico punto che prova, in ordine, `GatewayConnectDeepLink.fromSetupCode` → `DeepLinkParser.parse` (`.gateway`) → `IanuaProvisionLink.parse`. Prima del fix il terzo tentativo non esisteva in nessuno dei due punti di ingresso del wizard.
- **`apps/ios/Sources/Onboarding/QRScannerView.swift`**: `Coordinator.dataScanner(didAdd:)` (riga ~69, ora ~69-84) usa `WizardQRRecognizer.recognize` invece della coppia di controlli inline; nuovo `onProvisionLink` closure sul componente.
- **`apps/ios/Sources/Onboarding/OnboardingWizardView.swift`**:
  - riga ~172-179: il `QRScannerView(...)` passa anche `onProvisionLink: { link in self.handleProvisionLink(link) }`.
  - riga ~206-220 (percorso "scegli da Foto"): usa `WizardQRRecognizer.recognize` invece della coppia di controlli inline.
  - nuove funzioni `handleProvisionLink(_:)` / `claimProvisionLink(_:)` (dopo `handleScannedLink`, ~riga 784): chiamano `IanuaProvisioningClient.shared.claim(link)`; se la claim porta anche le credenziali gateway (`claim.gateway?.connectDeepLink`), incatenano `handleScannedLink` così un solo QR fa login **e** collega il nodo; se la claim va a buon fine ma senza credenziali gateway (server attuale), mostra messaggio esplicito che lo dice; ogni `IanuaProvisionError` mostra il proprio `errorDescription` (già distinti per caso). Nessun ramo cade più nel messaggio generico "not a valid pairing code".
- **`apps/ios/Sources/Provisioning/IanuaProvisioningClient.swift`**: `Claim.Gateway` ha ora `url/bootstrapToken/token/password: String?` opzionali (retro-compatibili: un server che manda solo `status` decodifica lo stesso, `connectDeepLink` è `nil`) + `var connectDeepLink: GatewayConnectDeepLink?`.
- **`apps/shared/OpenClawKit/Sources/OpenClawKit/DeepLinks.swift`**: `fromSetupCode` ora delega a un helper privato `build(urlString:bootstrapToken:token:password:)` condiviso con la nuova `GatewayConnectDeepLink.fromProvisionClaim(url:bootstrapToken:token:password:)` (stessa validazione host/LAN/path di `fromSetupCode`, ma da campi JSON semplici invece che base64url — è la forma che una futura risposta di `/api/provision/claim` userebbe).

## RISULTATI TEST (dopo il fix)

- `swift test` in `apps/shared/OpenClawKit`: **134/134 passati** (inclusi 4 nuovi test `provisionClaim*` in `DeepLinksSecurityTests.swift`).
- `xcodebuild test` su simulatore "Iànua Test iPhone 17 Pro" (scheme `OpenClaw`, solo i nuovi target): **8/8 passati** (`WizardQRRecognizerTests` × 5, `IanuaProvisioningClaimDecodingTests` × 3).
- Suite completa `OpenClawTests`/`OpenClawLogicTests`: **238/240 passati**. 2 fallimenti: `ShareToAgentDeepLinkTests.buildURLReturnsNilWhenPayloadEmpty()` e `NodeAppModelInvokeTests.handleInvokeCanvasCommandsUpdateScreen()`. **Confermati preesistenti e fuori scope**: `git diff HEAD~1 --stat` mostra che il fix tocca SOLO `Onboarding/{QRScannerView,OnboardingWizardView,WizardQRRecognizer}.swift`, `Provisioning/IanuaProvisioningClient.swift`, `OpenClawKit/DeepLinks.swift` + relativi test — nessun file di `ShareToAgentDeepLink` o `NodeAppModelInvoke`/canvas. Non necessario un secondo run completo su baseline pre-fix: lo scope del diff già esclude una relazione causale.

## FILE TOCCATI FINORA

Modificati: `apps/ios/Sources/Onboarding/QRScannerView.swift`, `apps/ios/Sources/Onboarding/OnboardingWizardView.swift`, `apps/ios/Sources/Provisioning/IanuaProvisioningClient.swift`, `apps/shared/OpenClawKit/Sources/OpenClawKit/DeepLinks.swift`, `apps/shared/OpenClawKit/Tests/OpenClawKitTests/DeepLinksSecurityTests.swift`.
Nuovi: `apps/ios/Sources/Onboarding/WizardQRRecognizer.swift`, `apps/ios/Tests/WizardQRRecognizerTests.swift`, `apps/ios/Tests/IanuaProvisioningClaimDecodingTests.swift`.

## PROSSIMO: SPEC SERVER (vedi `SERVER-SPEC-provision-claim.md`)

Documento di sola specifica (non codice deployabile — `provisioning.mjs` non è in questo monorepo, vedi BLOCCANTE sopra) scritto in `SERVER-SPEC-provision-claim.md` a livello di repo root. Descrive l'estensione retro-compatibile di `gateway` nella risposta 200 di `/api/provision/claim`.
