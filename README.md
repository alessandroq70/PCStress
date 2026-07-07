# PCStress — test di stabilità del PC sotto carico

Vuoi sapere se un computer "si impalla" quando lavora al massimo? PCStress lo
porta al limite (CPU, RAM, GPU e disco) per il tempo che decidi tu e sorveglia
il sistema: blocchi, congelamenti, crash dei driver ed errori vengono rilevati
e riassunti in un verdetto finale — **STABILE**, **STABILE CON RISERVA** o
**INSTABILE** — con un report scaricabile.

Tutto è pensato per **Windows** e non richiede alcuna installazione.

## I due modi di usare PCStress

| | Web app (`index.html`) | Script nativo (`stress-nativo.ps1`) |
|---|---|---|
| Come si usa | Si apre nel browser | Si esegue in PowerShell |
| Installazione | Nessuna | Nessuna (PowerShell è già in Windows) |
| Cosa stressa | CPU, RAM, GPU, disco | CPU, RAM (a fondo, senza i limiti del browser) |
| Rileva | Blocchi UI, crash driver video, worker morti, crash pagina/sistema | Blocchi dello scheduler di sistema, con log su file |
| Quando sceglierla | Check rapido, uso da altri PC via rete | Diagnosi seria, stress massimo |

Il consiglio: parti dalla web app; se vuoi il carico più profondo o un log su
file, usa anche lo script nativo (si scarica anche dal link in fondo alla
pagina web).

## Avvio rapido

### A) Sul PC da testare, senza rete

Copia `index.html` sul PC e aprilo con doppio clic (Edge o Chrome). Configura
durata e moduli e premi **Avvia il test**. *(Aperto da file locale il modulo
Disco non è disponibile: serve il server del punto B.)*

### B) Da un altro PC della rete (web app condivisa)

Sul PC che fa da "server" (può essere lo stesso da testare o un altro):

```powershell
powershell -ExecutionPolicy Bypass -File .\avvia-server.ps1
```

Lo script stampa gli indirizzi, ad esempio `http://192.168.1.50:8080/`.
Dal PC **da testare** apri quell'indirizzo nel browser e avvia il test:
il carico gira sul computer che apre la pagina, non sul server.

Note:
- per essere raggiungibile dagli altri PC, il server va avviato in un
  PowerShell **da amministratore** (aggiunge da solo la regola del firewall);
  senza diritti admin funziona comunque, ma solo da `http://localhost:8080/`;
- in alternativa, con Node.js installato: `node server.js`
  (oppure, con Python: `python -m http.server 8080`).

### C) Stress nativo massimo (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File .\stress-nativo.ps1
```

Parametri utili:

```powershell
# 30 minuti, CPU al 100%, 4 GB di RAM occupata, senza domanda di conferma
powershell -ExecutionPolicy Bypass -File .\stress-nativo.ps1 -DurataMinuti 30 -MemoriaMB 4096 -SenzaConferma

# carico più delicato (75% per core)
powershell -ExecutionPolicy Bypass -File .\stress-nativo.ps1 -CaricoCPU 75
```

Si interrompe in ogni momento con `CTRL+C` (il carico viene fermato e la
memoria rilasciata). Scrive un log dettagliato `pcstress-log-*.txt` accanto
allo script.

## Come leggere il risultato

- **STABILE** — nessun blocco, crash o errore per tutta la durata: il PC regge
  il carico.
- **STABILE CON RISERVA** — il test è arrivato in fondo ma con rallentamenti
  marcati: tipico di surriscaldamento o *thermal throttling*. Vale la pena
  controllare temperature e ventole.
- **INSTABILE** — blocchi dell'interfaccia oltre 5 secondi, crash del driver
  video, processi di calcolo morti o errori: il PC ha un problema reale sotto
  carico. Cause tipiche: raffreddamento insufficiente, RAM difettosa
  (verifica con `mdsched.exe`, lo strumento diagnostica memoria di Windows),
  alimentatore al limite, driver instabili.
- **La pagina, il browser o il PC si sono bloccati/riavviati durante il test?**
  È il verdetto peggiore, anche se nessun report è stato prodotto. Alla
  riapertura la web app se ne accorge da sola e te lo segnala con un banner.

Un consiglio pratico: un check rapido da 10 minuti scova i problemi grossi;
per una diagnosi seria (PC nuovo, overclock, PC che si riavvia "a caso") fai
almeno 30–60 minuti con carico al 100%.

## Avvertenze

- Il test porta **davvero** il computer al limite: ventole al massimo e
  temperature alte sono normali. Salva e chiudi i documenti prima di partire.
- Su un portatile tienilo collegato alla corrente e su una superficie rigida.
- Se il PC ha già problemi di raffreddamento noti, parti dall'intensità Media.
- La web app non invia nulla in rete: tutto il test gira in locale nel browser.

## Contenuto del repository

| File | Cosa fa |
|---|---|
| `index.html` | La web app completa (un solo file, nessuna dipendenza) |
| `avvia-server.ps1` | Serve la cartella in HTTP sulla rete locale (Windows) |
| `server.js` | Come sopra, ma con Node.js (qualsiasi sistema) |
| `stress-nativo.ps1` | Stress test nativo Windows con log e verdetto |
