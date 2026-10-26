# FolderFlow cloud

Progetto dedicato: `folderflow-marco-2026`. Firestore Standard, database `(default)`, regione `europe-west8` (Milano), free tier, nessuna fatturazione collegata. Authentication: Google ed email/password. Il plist distribuito nell'app contiene soltanto configurazione client pubblica: la protezione dei dati dipende dalle regole, non dalla segretezza della API key.

Ogni account usa `users/{uid}/catalogs/{catalogID}/projects/{projectID}`. Metadati e progetti hanno revisioni indipendenti, scritte con transazioni. Le cancellazioni sono tombstone: una modifica rimasta offline genera un conflitto esplicito invece di ricreare silenziosamente il progetto. Le due versioni rimangono nel file locale finché l'utente sceglie. Foto e video non vengono caricati. Le preferenze account sono in `users/{uid}/settings/preferences`, con la stessa coda persistente, revisione e gestione dei conflitti. Un nuovo Mac carica le preferenze già presenti; inizializza i valori solo quando il server conferma che il documento manca.

Le cache locali sono separate per UID, con coda delle modifiche persistita prima dell'invio. Un catalogo remoto non rende online un percorso appartenente a un altro Mac: il disco viene riconosciuto attraverso il UUID del volume. Cartelle monitorate e associazioni dei percorsi restano locali. L'importazione dei cataloghi senza account è esplicita.

## Verifiche

Dalla radice del progetto:

```sh
npm ci --prefix Backend
npm exec --yes --package firebase-tools -- firebase emulators:exec --project demo-folderflow --only firestore 'npm --prefix Backend test'
swift test
```

Il test live è separato e non fa parte di `npm test`. Crea e rimuove un account temporaneo e i propri documenti, usando la sessione CLI per ripulirli:

```sh
FOLDERFLOW_LIVE_SMOKE=folderflow-marco-2026 node Backend/tests/live-smoke.mjs
```

Pubblicazione regole/configurazione sul progetto dedicato:

```sh
npm exec --yes --package firebase-tools -- firebase deploy --only firestore:rules --project folderflow-marco-2026
```

Spark ha quote condivise tra tutti gli utenti dell'app: il servizio gratuito non è illimitato. Non sono abilitati Cloud Storage, Functions, Analytics o upgrade a pagamento. Le modifiche restano localmente se il cloud non è raggiungibile o rifiuta una richiesta. L'interfaccia mostra gli errori nell'account.

## Firma e prova sui Mac

Aprire `FolderFlow.xcodeproj`, generabile con `xcodegen generate` da `project.yml`. In Xcode aggiungere l'Apple ID in Settings > Accounts, scegliere il Personal Team in Signing & Capabilities, lasciare attiva la firma automatica. Il bundle identifier è `com.unshapedstudio.folderflow`, con un client Apple Firebase dedicato. Al primo avvio le preferenze della 4.8 (`com.folderflow.app`) vengono copiate una sola volta dopo un backup privato; il vecchio dominio rimane invariato. La cartella Application Support resta `FolderFlow`, quindi i cataloghi locali e le code mantengono gli stessi percorsi.

Il progetto contiene URL scheme Google e gruppo Portachiavi `$(AppIdentifierPrefix)$(CFBundleIdentifier)`. Un certificato Apple valido è necessario per il salvataggio delle credenziali; una firma ad-hoc non dimostra il funzionamento del login. La disponibilità e la durata della firma gratuita dipendono dai limiti del Personal Team Apple. Nessun team ID o certificato viene inventato nel repository.

Dopo la firma: accedere sul fisso, importare esplicitamente il catalogo locale, attendere sincronizzazione, accedere al medesimo account sul portatile; verificarne la consultazione senza HD, creare un catalogo sul portatile, modificare note offline, riconnettere e controllare aggiornamenti/conflitti. Verificare anche che le preferenze di sistema si aggiornino tra i dispositivi e siano disponibili offline. Questa prova fisica su due Mac resta necessaria prima della distribuzione.

Fonti: https://firebase.google.com/docs/projects/billing/firebase-pricing-plans ; https://developers.google.com/identity/sign-in/ios/start-integrating ; https://developer.apple.com/help/account/basics/about-your-developer-account
