# FolderFlow — interfaccia studio, revisione 4.8

Decisione icona del 26 ottobre: mantenere il logo originale intero e la cornice di sistema esistente. Scartata la prova ingrandita con cornice ridotta perché macOS taglia la sagoma. Nessun ulteriore ingrandimento o ridisegno del logo.

Revisione 5.1.3: ripristinato il logo originale FolderFlow (cartella scura con elenco e badge verde), conservando il PNG originale trasparente senza ridisegno; la barra laterale lo carica direttamente, senza cornice di sistema. Icona minimale della barra dei menu preservata. Ingranaggio visibile nello stesso pulsante profilo/impostazioni. Scansione in quadrato petrolio/azzurro 42×38 con contorno e tono della selezione Tutti i dischi, affiancato al + arancione della stessa misura. Dati e azioni invariati.

Revisione 5.1.2: icona app con sola cartella piena petrolio e badge più verde, su sfondo trasparente, senza cornice o bordi bianchi. Barra dei menu con simbolo nativo folder.badge.plus da 18 punti, template monocromatico per i temi chiaro/scuro. La barra laterale usa direttamente il PNG dell'app, senza maschere o ingrandimenti che tagliano la sagoma. Risorse rigenerabili con `swift Scripts/generate-icons.swift`.

App macOS SwiftUI per lavori fotografici e video. Riferimenti SecureCopy e BooBar e correzioni di Marco del 23 ottobre 2026.

Revisione 5.1.1: selettore anno compatto 104×34 su una sola riga, con solo il valore attivo e due piccole frecce. Nessun anno precedente o successivo visibile; scorrimento, tastiera e accessibilità mantenuti. All'avvio il valore resta Tutti.

Base antracite/petrolio, superfici opache, SF e SF Symbols. **Non usare mai il viola.** Colori di dischi e stati della 4.2 preservati. StudioTheme contiene i token e la rimappatura dei vecchi colori.

Layout: HSplitView nativo macOS. Sinistra da 420 a 520 punti, destra almeno 660; finestra minima 1200×760. Ogni pannello riempie il proprio spazio; niente maxWidth applicato dentro un pannello di navigazione più largo. Panoramica fino a 1320 punti e scheda progetto fino a 1040, con 36 punti di margine. Spaziatura tra gruppi 28 punti.

Sinistra: barra compatta con 18 punti orizzontali e 16 verticali di margine. Tabella nativa con nome e icona HD, righe da almeno 60 punti, separatori nativi; colonne stato fisse da 64 punti. Intestazioni Progetti / In corso / Da fatt. In corso pieno petrolio = non concluso; Da fatt. pieno ambra = non fatturato. Stato opposto con pallino vuoto; tooltip e label accessibili espongono il valore. Su macOS 14.5+ intestazioni centrate sulle colonne; fallback nativo macOS 13. Frecce e scorrimento gestiti da NSTableView. Filtro dischi in basso con margini di 20/18 punti.

Dettaglio: percorso e fascia dimensione/data/disco; gestione in tre colonne e note sotto. Stato form isolato per identità del progetto.

Impostazioni: sistema prima, dischi monitorati poi, dischi inattivi in fondo, ordine naturale nei gruppi. Finestra da 760 punti con altezza fino a 700, griglia a due colonne più ariosa. Ordinamento solo visivo, nessuna modifica alle preferenze o al catalogo.

Nuovo progetto: fino a 1100×800 con griglia adattiva, come nella 4.2.

Revisione 4.5: pannello HD con LazyVGrid adattiva (celle da almeno 104 punti, distanze 8), solo dischi monitorati e collegati, nessuna selezione = elenco vuoto. Nessuno scorrimento laterale. Dettagli capacità espandibili.

Nuovo progetto: campo Nome del lavoro e anteprima del nome cartella generato. Griglia dischi con celle da almeno 150 punti, fino a 6 colonne nella finestra larga per vedere 11 dischi su due righe.

Impostazioni Progetti: formato originale `{AA}_{MM}_{NN}_{Nome}` predefinito, quattro preset e formato personalizzato con campi AA/AAAA/MM/GG/NN/Nome. Anteprima, validazione e applicazione esplicita; pulsante per ripristinare il formato di Marco. Regola condivisa tra generazione e riconoscimento nella scansione, numerazione per data inclusa, vecchi percorsi già catalogati conservati. Preferenza locale; nessuna rinomina delle cartelle esistenti.

Revisione 4.6: selettore colore nativo macOS da 44 punti su ogni riga in Impostazioni → Dischi, con etichetta accessibile e tooltip per nome HD. Stessi colori in lista, grafici e finestre; rimappatura del viola e saturazione del tema preservate. Scelte salvate in RGB, mantenute per HD scollegati e nelle importazioni/esportazioni. La vecchia palette a nomi viene rigenerata una sola volta.

Grafico HD: ordinamento decrescente per percentuale, calcolata con la capacità reale in byte e le stesse unità delle dimensioni dei progetti (GiB). Le stime da nome per dischi scollegati restano disponibili; capacità ignota indicata come n/d e ordinata in fondo. L'anno continua a filtrare i progetti sommati. Pulsante nuovo progetto solo simbolo +, 42×38 punti, arancione, simbolo da 19 punti; posizione e pulsanti HD invariati.

Revisione 4.7: nella barra laterale l'icona nativa dell'app sostituisce il simbolo griglia per il ritorno alla panoramica. Immagine 28×28 in pulsante 34×38, tooltip esplicito; mantenuti accessibilità e comando ⌘1. Footer impostazioni con link discreto a sinistra “powered by unshapedstudio.com” e Chiudi a destra, visibile in ogni scheda.

Revisione 4.8: scheda Sistema con righe esplicite: blocco titolo/descrizione allineato a sinistra, Toggle senza label visiva in colonna fissa da 48 punti a destra. Margini orizzontali 20, verticali 18; testo a capo con altezza naturale. Titoli e suggerimenti accessibili presenti sui controlli. Azioni e preferenze esistenti conservate.

Login 5.0.1: sheet compatta da 500 punti (590 di altezza normale), pulsante Google ufficiale wide 240×40 centrato e ritagliato con raggio 8 come gli altri comandi. Form da 364 punti con campi scuri da 44, icone SF Symbols e bordo petrolio sul campo attivo; azione email larga quanto i campi e stato disabilitato con testo leggibile. Footer centrato, nessuno spazio vuoto alto 300 punti; chiusura da tastiera Esc. Sessione e azioni account preservate.


Revisione 5.0.2: barra principale con solo indicatore di sincronizzazione e nome utente; il profilo apre Impostazioni → Account, dove si selezionano e creano i cataloghi. Rimosso il pulsante Impostazioni duplicato dalla panoramica e dal dettaglio. Anno in rotella incorporata accanto al titolo, scorrimento mouse/trackpad, frecce e accessibilità; valore iniziale Tutti a ogni apertura, mai persistito. Icona laterale 36 punti con presentazione senza bordo bianco e pulsante trasparente. Preferenze Avvia all’accesso e Solo barra dei menu sincronizzate per account con cache offline e risoluzione dei conflitti; nomenclatura e colori continuano a seguire il catalogo. Percorsi, dischi monitorati e autorizzazioni macOS appartengono al singolo computer.


Revisione 5.0.3: unica scheda Cataloghi per profilo, elenco cataloghi, importazione/esportazione e copie di sicurezza; eliminate Backup e Database e il pannello duplicato Gestisci account e sincronizzazione. Login resta una finestra dedicata solo all’accesso. Le importazioni JSON mostrano anteprima e scelta esplicita nuovo/sostituzione; la sostituzione e le operazioni avanzate creano una copia prima di modificare i dati. Selettori nativi gestiti da fileImporter/fileExporter nel contesto della scheda. Esito di backup dopo scrittura effettiva, nomi univoci e copie separate per account/catalogo. Indicatore accanto al nome account a destra nella stessa barra di icona, ricerca, aggiornamento HD e +; eliminata la riga superiore separata.


Revisione 5.0.4: nella scheda Cataloghi solo nome account, cataloghi, conteggi e comandi. Email disponibile nel tooltip del nome; nessun testo di sincronizzazione ordinaria, spiegazione JSON, titolo Cataloghi ripetuto o descrizione dei backup. Importa, Esporta e Nuovo catalogo nella stessa riga. Mantieni solo errori reali, esiti delle operazioni e informazioni essenziali nelle conferme di sostituzione.
