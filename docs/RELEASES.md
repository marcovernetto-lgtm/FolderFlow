# Note di rilascio

## 5.1.3 — anteprima di sviluppo

- Ripristinato il logo originale FolderFlow nella barra dell'app, senza cornice aggiunta nell'interfaccia.
- Ingranaggio visibile accanto al profilo per aprire impostazioni e cataloghi.
- Aggiornamento dai dischi nel pulsante azzurro, accanto al più arancione.
- Cataloghi con accesso Google/email, cache locale, modifiche offline e sincronizzazione per account.
- Preferenze account condivise fra dispositivi; percorsi e dischi monitorati specifici di ogni Mac.
- Importazione JSON con anteprima, scelta fra aggiunta e sostituzione e copia di recupero prima della sostituzione.
- Backup online automatici all'avvio, cronologia e ripristino, conservazione di 60 giorni per le sole copie.
- Nomenclatura personalizzabile, colori dei dischi e grafico ordinato per percentuale occupata.
- Selettore anno su una riga, inizialmente Tutti; anni ricavati dai progetti presenti.

Questa è la prima pubblicazione del progetto su GitHub. Le funzioni sopra descrivono la versione disponibile, incluse modifiche realizzate prima della pubblicazione.

### Verifiche

45 test Swift passati. In precedenza sono stati superati 7 test delle regole Firestore, verifiche cloud con dati temporanei e prove native con cataloghi isolati. Le immagini della guida provengono dalle anteprime native con dati dimostrativi. Il pacchetto universale viene controllato per firma, architetture, integrità di ZIP/DMG e checksum.

### Limiti della distribuzione

La build è firmata per lo sviluppo e non notarizzata; il suo profilo può limitare Mac autorizzati e periodo di validità. I pacchetti restano in bozza, non come installer pubblico. Il collaudo reale su due Mac e una firma adatta alla distribuzione restano da completare. Vedi [Compilazione e pacchetti](BUILD.md).
