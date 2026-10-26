# Compilazione e pacchetti

FolderFlow è un'app SwiftUI per macOS 13 o successivo. Il progetto Xcode usa Firebase Authentication, Firestore e Google Sign-In; SwiftPM risolve le versioni indicate nel progetto.

## Compilare sul proprio Mac

1. Clonare la repository e aprire `FolderFlow.xcodeproj` in Xcode.
2. Aggiungere il proprio Apple ID in **Xcode → Settings → Accounts**.
3. Nel target FolderFlow, aprire **Signing & Capabilities** e scegliere il proprio team Apple. Il team nel progetto è quello usato per lo sviluppo e va sostituito per una propria build.
4. Lasciare la firma automatica e selezionare **My Mac**, poi eseguire l'app.

Il login con Google usa il Portachiavi: una compilazione senza firma o una firma ad-hoc non ne dimostra il funzionamento. Il Personal Team gratuito può richiedere la registrazione del Mac e il rinnovo del profilo. Non sono inclusi certificati, chiavi private o profili di provisioning.

La configurazione client Firebase inclusa identifica il progetto dell'app; non è una credenziale amministrativa. Per usare un backend proprio bisogna configurare Firebase e Google Sign-In e sostituire il file client e lo schema di ritorno. Vedi [Backend](../Backend/README.md).

Per rigenerare il progetto con XcodeGen:

```sh
xcodegen generate
```

## Verifiche

```sh
swift test
npm ci --prefix Backend
npm exec --yes --package firebase-tools -- firebase emulators:exec --project demo-folderflow --only firestore 'npm --prefix Backend test'
```

I test live sono separati, richiedono autorizzazione al backend e creano soltanto il proprio account temporaneo. Non eseguirli per il semplice controllo dei sorgenti.

## Build universale

```sh
xcodebuild -project FolderFlow.xcodeproj -scheme FolderFlow \
  -configuration Release -destination 'generic/platform=macOS' \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  -allowProvisioningUpdates build
```

Per creare DMG, ZIP e checksum da un'app già firmata:

```sh
python3 Scripts/package-release.py --app /percorso/FolderFlow.app --output-dir dist
```

Lo script controlla firma e architetture, verifica gli archivi e produce un riepilogo della firma senza elencare gli identificativi dei dispositivi. Non pubblica nulla e non cambia il bundle originale. I pacchetti sono esclusi dalla cronologia Git.

## Distribuzione

La build attuale è firmata per lo sviluppo, non è notarizzata ed è limitata dal relativo profilo. Non equivale a un installer pronto per qualsiasi Mac. I pacchetti di questa build restano nella release in bozza finché non è disponibile una firma adatta alla distribuzione.

Per un download pubblico pronto all'uso servono una build firmata con Developer ID e notarizzazione Apple, oppure un canale di distribuzione equivalente. Il pacchetto va poi provato su Apple Silicon e Intel. La prova reale fra fisso e portatile, inclusi accesso, uso offline, conflitti e ripristino dei backup, resta da completare.
