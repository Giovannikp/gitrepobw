# Order Enrichment API – README

API REST su TIBCO BusinessWorks: **POST /orders** riceve un ordine e restituisce il totale in euro e la data di consegna effettiva. Il cambio viene da ‘Frankfurter’, le festività da ‘Nager.Date’.

## Struttura flusso di Processo

| **Processo** | **Cosa fa** |
| --- | --- |
| Main_Orders | Valida la request (400 VALIDATION_ERROR), chiama i due processi atomici, calcola totalAmount e totalEUR, costruisce la risposta |
| At_FxRate | Riceve la valuta, restituisce il tasso. Con EUR restituisce 1 senza chiamate |
| At_DeliveryDate | Riceve paese e data richiesta, restituisce data effettiva e motivo |
| GetHolidays | Riceve (paese, anno), restituisce le date delle festività. Contiene la cache e l’unica chiamata a Nager.Date |

## Come avviare

1.  **MockServices** (solo in modalità mock): applicazione BW sulla porta 8084.

Espone

\- GET _/v1/latest_ e

\- GET _/api/v3/PublicHolidays/{year}/{countryCode}_

con risposte fisse (risposte opzione “Implementation Data = Opaque”: restituiscono il JSON grezzo, come i servizi veri, che nel processo si presenta come ‘getResponse > message > messageBody’). Il mock ignora “base”, “symbols”, “anno” e “paese”.

1.  **OrderEnrichment**: applicazione BW sulla porta 8085, endpoint POST /orders.
2.  Test: collection Postman (environment mock o reale).

Con i servizi reali basta avviare solo **OrderEnrichment**. Dopo ogni cambio di property si ferma e si rilancia l’applicazione: i valori si leggono all’avvio.

## Da mock a reale

Nessun processo cambia: si modificano solo le Module Properties. In BW host, porta e SSL appartengono alla HTTP Client Resource (FrankfurterHttpClientResource, NagerHttpClientResource), quindi per ogni servizio le property sono tre (la traccia prevedeva un’unica baseUrl). L’opzione SSL della risorsa (_Default Confidentiality_) è legata alla property \*.ssl.

| Property | Mock | Reale |
| --- | --- | --- |
| frankfurter.host | localhost | api.frankfurter.dev |
| frankfurter.port | 8084 | 443 |
| frankfurter.ssl | false | true |
| nager.host | localhost | date.nager.at |
| nager.port | 8084 | 443 |
| nager.ssl | false | true |

Le “SendHTTPRequest” non mappano Host e Port: valgono i default della risorsa (se fossero mappati vincerebbero sulla risorsa).  
I path restano identici _(/v1/latest_, _/api/v3/PublicHolidays/{anno}/{paese}_).  
Il ParseJSON è lo stesso per mock e reale (festività: stile _Anonymous Array_, schema Holidays.xsd, _Ignore Additional JSON Fields_; cambio: FxResponse.xsd).

Con la property “_Default Confidentiality”_ spuntato (ssl = true) verso una porta in chiaro si ottiene: _Unsupported or unrecognized SSL message_.

Dopo il cambio, fxRate e totalEUR seguono il tasso reale; le date non cambiano.

## Regola di calcolo della data di consegna

- **Festività:** voci di Nager.Date con global = true e types che contiene Public, per paese e anno.
- **effectiveDeliveryDate:** si parte dalla data richiesta e si provano i giorni successivi (massimo 30) fino al primo che non sia sabato, domenica o festivo. Il giorno della settimana si ricava dai giorni trascorsi dal 1900-01-07 (una domenica) modulo 7: 0 domenica, 6 sabato.
- **deliveryShiftReason:** si decide solo sulla data richiesta: HOLIDAY (ha la precedenza), altrimenti WEEKEND, altrimenti NONE.

### Cambio d’anno

1.  At_DeliveryDate chiama GetHolidays per l’anno richiesto e calcola la data (MapperCalc1).
2.  Se l’anno della data trovata è uguale a quello richiesto, il risultato è definitivo (la seconda chiamata non parte: con 2026-12-25 → 2026-12-28 le chiamate restano due, cambio e festività 2026).
3.  Altrimenti chiama GetHolidays anche per l’anno dopo e ricalcola con i due elenchi uniti (MapperCalc2). Il motivo resta calcolato sulla data originale, che sta nell’anno richiesto.

Esempio G2-T4: IT, 2022-12-31 (sabato) → 2023-01-02, motivo WEEKEND, con le liste 2022 e 2023.

## Gestione della valuta

- EUR: fxRate = 1, nessuna chiamata a Frankfurter.
- Valuta sconosciuta: Frankfurter risponde 404 (visto nel log con ‘ZZZ’).

L’uscita di errore di Call_FxRate riconosce qualunque 4xx e l’API risponde 400 con code = INVALID_CURRENCY (la valuta è l’unica parte variabile della richiesta). Tutto il resto arriva al **Catch All** di “Main_Orders”, che registra l’errore e lo rilancia (500). Timeout e 5xx: Attività Giorno 3.

## Cache delle festività

**Scelta:** elenco delle festività in memoria in una _Module Shared Variable_ (HolidayCache), una voce per coppia (paese, anno).  
\=> **Perché:** non ha dipendenze esterne e basta perché le festività di un anno non cambiano; due ordini consecutivi per lo stesso paese e anno fanno una sola chiamata a Nager.Date.

- **Formato:** stringa di voci separate da “ ; ”, ciascuna PAESE-ANNO=data1,data2,….  
    Esempio: IT-2026=2026-12-08,2026-12-25,2026-12-26;DE-2026=2026-12-25,2026-12-26;.  
    Un elenco vuoto è una voce valida (XX-2026=;) e conta come hit.
- **Flusso di GetHolidays:** GetCache legge la variabile.
    - _Hit_ (la chiave c’è): log Festività CACHE HIT paese=… anno=… e restituisce il valore.
    - _Miss_: log Festività chiamata paese=… anno=… | cache=…, SendHTTPRequest → ParseJSON → MapperFestivo (filtro e stringa di date) → SetCache (aggiunge la voce) → restituisce le date.
- **Prova G2-T5:** due ordini IT/2026 di fila con l’applicazione appena avviata: nel log una sola riga di chiamata e una riga CACHE HIT; le due risposte sono identiche.

## XPath introdotti

**1\. Festività utili** (MapperFestivo, in GetHolidays)

_string-join($ParseJSON/tns:holiday\[@global = true() and tns:types = 'Public'\]/@date, ',')_

Tiene le feste valide in tutto il paese (global) e di tipo Public, e restituisce le date in una sola stringa separata da virgole.

**2\. Chiave, hit, valore e scrittura della cache** (GetHolidays)

hit : contains(concat(';', $GetCache), concat(';', $Start/tns1:countryCode, '-', $Start/tns1:year, '='))  
valore : substring-before(substring-after(concat(';', $GetCache),  
concat(';', $Start/tns1:countryCode, '-', $Start/tns1:year, '=')), ';')  
nuovo : concat($GetCache, $Start/tns1:countryCode, '-', $Start/tns1:year, '=', $MapperFestivo, ';')

- _hit_: la chiave PAESE-ANNO= è all’inizio di una voce? Il “ ; “ aggiunto davanti evita che T-2026 coincida con IT-2026.
- _valore_: prende ciò che segue la chiave fino al “ ; “ successivo (le date della voce).
- _nuovo_: la cache attuale più la nuova voce, con “ ; “ finale.
- End.dates ← if (hit) then valore else $MapperFestivo.

**3\. Data effettiva** (MapperCalc1; MapperCalc2 usa l’elenco unito)

_string((for $i in 0 to 30  
return if (not(((((xsd:date($Start/tns1:requestedDeliveryDate) + xsd:dayTimeDuration(concat('P', string($i), 'D')))  
\- xsd:date('1900-01-07')) div xsd:dayTimeDuration('P1D')) mod 7) = (0, 6))  
and not(string((xsd:date($Start/tns1:requestedDeliveryDate) + xsd:dayTimeDuration(concat('P', string($i), 'D'))))  
\= tokenize($Call_GetHolidays, ',')))  
then (xsd:date($Start/tns1:requestedDeliveryDate) + xsd:dayTimeDuration(concat('P', string($i), 'D')))  
else ())\[1\])_

Per $i da 0 a 30 costruisce il candidato data richiesta + $i giorni, lo tiene se non è weekend (mod 7 diverso da 0 e 6) né festivo (non è tra le date di tokenize), e \[1\] prende il primo.  
In MapperCalc2 il confronto usa:

_tokenize(concat($Call_GetHolidays, ',', $Call_GetHolidaysNextYear), ',')._

**4\. Campo Motivo** (End di At_DeliveryDate)

if ($Start/tns1:requestedDeliveryDate = tokenize($Call_GetHolidays, ',')) then 'HOLIDAY'  
else if (((xsd:date($Start/tns1:requestedDeliveryDate) - xsd:date('1900-01-07')) div xsd:dayTimeDuration('P1D')) mod 7 = (0, 6)) then 'WEEKEND'  
else 'NONE'

**5\. Scelta del risultato e anno successivo** (At_DeliveryDate)

End.effectiveDeliveryDate : if (substring($MapperCalc1, 1, 4) != substring($Start/tns1:requestedDeliveryDate, 1, 4))  
then $MapperCalc2 else $MapperCalc1  
Call_GetHolidaysNextYear.year : string(xsd:int(substring($Start/tns1:requestedDeliveryDate, 1, 4)) + 1)

**6\. Valuta sconosciuta** (transition di LogFxError in Main_Orders)

matches(string($\_error/Msg), '\\\[4\[0-9\]{2}\\\]')

Il messaggio dell’errore HTTP contiene il codice tra parentesi quadre (per esempio \[404\]): la regex riconosce qualunque 4xx restituito da ‘Frankfurter’. Non verifica lo status in uscita: il 400 lo decide la Reply.

## Giorno 3 – Errori e resilienza

Il Giorno 3 rende l’API affidabile quando i servizi esterni sono lenti o non disponibili. Ogni chiamata a Frankfurter e a Nager.Date ha un tempo massimo di attesa e, se serve, un secondo tentativo. I due guasti hanno conseguenze diverse: senza il cambio l’ordine non si può completare, senza le festività sì. Ogni richiesta porta un identificativo che si ritrova nei log, nell’header di risposta e negli errori, e la risposta agli errori è decisa in un solo punto dell’applicazione.

### Mappa delle attività

| **Blocco** | **Obiettivo** | **Test** | **Stato** |
| --- | --- | --- | --- |
| A   | Guasto del cambio: timeout e risposta 502 | G3-T1 | Completato |
| B   | correlationId nei log, nell’header e negli errori | G3-T5 | Completato |
| C   | Guasto delle festività: l’ordine passa con la sola regola di sabato e domenica | G3-T2, G3-T3 | Completato |
| D   | Un tentativo in più dopo 1 secondo (retry) sulle due chiamate | G3-T1, G3-T3 | Completato |
| E   | I due processi atomici partono in parallelo | G3-T4 | Completato |
| F   | Un solo gestore degli errori per tutta l’applicazione | G3-T1 e prove sugli errori | Completato |
| E2E | Test finale: 20 richieste consecutive sul mock, poi Collection Runner completo | E2E-4, E2E-5 | Completato |

Il mock viene esteso con i guasti richiesti (parte dei blocchi A e C). I blocchi D e C condividono lo stesso schema di retry.

### Mock con “guasti”

Per provare i casi di errore senza toccare i servizi veri, il mock risponde in modo anomalo a tre richieste. I guasti esistono solo nel mock: sui servizi reali JPY, FR ed ES funzionano normalmente.

| **Chiamata** | **Risposta del mock** | **Come è realizzata** |
| --- | --- | --- |
| Cambio con base=JPY | HTTP 500 | In Cambio, dopo lo Start, una transition condizionata (base = 'JPY') porta a un Throw. Le altre valute vanno alla risposta fissa. |
| Festività del paese FR | HTTP 500 | Come sopra, in Festivo, con countryCode = 'FR'. |
| Festività del paese ES | Nessuna risposta per 10 secondi | La transition per ES porta a uno Sleep di 10000 ms e poi alla risposta normale: il client smette di aspettare dopo 3 secondi, quindi per lui il servizio non risponde. |

### Timeout e retry

Vale per tutte e due le chiamate esterne (blocchi A, C e D). Le impostazioni sono nelle Module Properties, per poterle cambiare senza modificare i processi.

| **Property** | **Valore** | **Significato** |
| --- | --- | --- |
| fx.timeoutMs | 3000 | Attesa massima per la risposta del cambio, in millisecondi. |
| fx.retryCount | 1   | Tentativi in più dopo il primo: con 1 i tentativi totali sono 2. |
| fx.retryDelayMs | 1000 | Pausa prima del tentativo successivo. |
| Property nager. | come sopra | Gli stessi tre parametri per la chiamata alle festività. |

- **Timeout:** il campo Timeout della SendHTTPRequest è mappato sulla property.
- **Retry:** la sola SendHTTPRequest è dentro un gruppo _Repeat On Error Until True_ (RetryFx in At_FxRate, RetryNager in GetHolidays). Il gruppo ripete le sue attività finché non riescono.  
    Un indice (tentativo) parte da 1; la “_stop repeat condition”_ è retryCount < tentativo. Con retryCount = 1: dopo l’errore del tentativo 1 la condizione è falsa e il gruppo ripete; dopo l’errore del tentativo 2 è vera e l’errore esce dal gruppo.
- **Dentro il gruppo**, in ordine: Sleep, un Log con il numero del tentativo (LogFxTentativo), la SendHTTPRequest. Lo Sleep aspetta retryDelayMs solo dal secondo tentativo (if ($tentativo > 1) then &lt;ritardo&gt; else 1).  
    Al primo vale 1 ms, non 0: nella attuale versione di BW in uso uno Sleep con intervallo 0 causava un’attesa di 2/3 minuti.
- **Fuori dal gruppo** restano ParseJSON e le attività successive.
- **HTTP Client Resource:** la sua opzione “_Retry Count”_ è stata azzerata. Il client ha un retry proprio, e lasciarlo attivo avrebbe nascosto tentativi in più oltre a quelli del gruppo.
- **Tempi:** nel caso peggiore 3 s + 1 s + 3 s, circa 7 secondi per servizio: da qui il limite di 8 secondi di G3-T3.

Nel file log, con “JPY” sul mock, si leggono i due tentativi (le righe sono abbreviate):

_LogFxTentativo - \[REQ-bw0a100-…\] Tentativo indice=1 | valuta=JPY  
Cambio (mock) instance faulted ... Throw activity \[Throw\] fault  
LogFxTentativo - \[REQ-bw0a100-…\] Tentativo indice=2 | valuta=JPY  
At_FxRate instance faulted ... HttpServerException: \[500\] status code_

### Header ‘correlationId’

Il correlationId è un identificativo unico di richiesta. Serve a ricostruire dal log tutto ciò che è successo per un ordine, anche quando i processi girano in parallelo e le righe si alternano.

1.  **Lettura.** Il binding di Main_Orders dichiara un parametro _Header_ facoltativo X-Correlation-Id.
2.  **Generazione.** Il primo Mapper di Main_Orders (quello della validazione) ha un campo correlationId: il valore dell’header se c’è, altrimenti REQ- seguito dal JobId e da data e ora.

\> Esempio: REQ-bw0a100-202610211552521320200.

1.  **Propagazione.** Un campo correlationId nello Start di At_Enrich, At_FxRate, At_DeliveryDate e GetHolidays, mappato in ogni _Call Process_.
2.  **Log.** Ogni messaggio dei Log comincia con \[&lt;correlationId&gt;\].
3.  **Risposta.** L’header X-Correlation-Id torna anche nelle risposte di errore, e Error.xsd ha un campo correlationId.

### Festività non disponibili

Se ‘Nager.Date’ non risponde o risponde con un errore anche dopo il secondo tentativo, l’ordine passa: si applica solo la regola di sabato e domenica.

**Perché il “cambio” blocca l’ordine e le festività no.** Senza il tasso non si può calcolare totalEUR, un campo obbligatorio della risposta: non esiste un risultato parziale accettabile, quindi si risponde 502. Le festività servono solo a rifinire la data di consegna.

Come funziona dentro il processo GetHolidays:

1.  La SendHTTPRequest è dentro il gruppo RetryNager, con lo stesso timeout e lo stesso retry del cambio.
2.  Il processo ha un _Catch All_: se, dopo i tentativi, l’errore esce dal gruppo, lo cattura. Il Log LogFestiviSkipped scrive anche la causa ($FaultDetails/Msg).
3.  Il Catch All termina con un secondo End (End1) che restituisce dates vuoto e skipped = true. Nei casi normali skipped = false.
4.  SetCache sta dopo il gruppo: se la chiamata fallisce non viene eseguita, quindi un guasto non entra mai in cache.

Con l’elenco vuoto la formula della data applica solo il controllo di sabato e domenica, e il motivo non può essere HOLIDAY. Il campo skipped distingue un elenco vuoto per guasto da un elenco vuoto perché in quel paese non ci sono festività.  
Prove sul mock: FR, consegna di sabato 2026-10-10 → data effettiva 2026-10-12, motivo WEEKEND; ES dà lo stesso risultato in meno di 8 secondi.

### Servizi: Chiamate in parallelo

Le chiamate al “cambio” e alle festività non dipendono l’una dall’altra: se partono insieme, il tempo totale è quello della più lenta e non la somma dei due.

**Realizzazione.** Il sottoprocesso At_Enrich ha lo Start con due uscite semplici, senza condizione: una verso Call_FxRate, una verso Call_DeliveryDate. Le due Call arrivano nello stesso End. Main_Orders fa una sola chiamata: _Mapper_ → Call_Enrich → MapperResponce → postOut.

Prova (G3-T4): i Log di avvio dei due processi distano 81 ms e le righe dei due rami si alternano.

16:05:27,607 LogStartDelivery - \[TEST-G3T4\] Inizio calcolo data di consegna  
16:05:27,688 LogStartFx - \[TEST-G3T4\] Inizio cambio  
16:05:28,032 LogCacheMiss - \[TEST-G3T4\] Festivita chiamata Paese=IT ...  
16:05:28,147 LogFxTentativo - \[TEST-G3T4\] Tentativo indice=1 | valuta=USD

Il motore BW fa avanzare i rami paralleli in modo cooperativo sullo stesso thread finché non si bloccano su una chiamata. La prova del parallelismo è quindi lo scarto di 81 ms (il limite è 200 ms) e l’alternanza delle righe, non thread diversi.

### Gestore errori unico

Tutti gli errori confluiscono in un solo punto: il _Catch All_ dello scope orders/post di Main_Orders, che decide la risposta. Le due eccezioni sono volute. La validazione della request (400 VALIDATION_ERROR) è un esito normale, non un guasto, e resta un ramo dedicato. Il Catch All di GetHolidays è una scelta di degrado, non una risposta all’utente.

Le tre risposte del Catch All:

| **Situazione** | **Come si riconosce** | **Risposta** |
| --- | --- | --- |
| Valuta sconosciuta | Il messaggio contiene At_FxRate e un codice \[4xx\] | 400 INVALID_CURRENCY |
| Cambio non disponibile (timeout o 5xx) | Il messaggio contiene At_FxRate, senza \[4xx\] | 502 UPSTREAM_FX_UNAVAILABLE |
| Qualunque altro errore | Nessuna delle due condizioni | 500 INTERNAL_ERROR |

Il messaggio di un errore BW contiene il nome del processo (ProcessName=orderenrichment.module.At_FxRate) e, per gli errori HTTP, il codice tra parentesi quadre (\[404\], \[500\]): le condizioni usano questi due elementi. Il testo arriva integro al Catch All anche dopo aver attraversato At_Enrich.  
Le transition in uscita dal Log iniziale sono tre:

\-- verso MapperInvalidCurrency (Success with condition)  
contains(string($FaultDetails/Msg), 'At_FxRate')  
and matches(string($FaultDetails/Msg), '\\\[4\[0-9\]{2}\\\]')  
<br/>\-- verso MapperUpstreamFx (Success with condition)  
contains(string($FaultDetails/Msg), 'At_FxRate')  
and not(matches(string($FaultDetails/Msg), '\\\[4\[0-9\]{2}\\\]'))  
<br/>\-- verso Mapper500: Success with no matching condition

- **Variabile del fault.** Dentro un Catch All l’errore non è in $\_error, ma in una variabile con un nome proprio ($FaultDetails; il numero finale può cambiare): va presa dall’albero dei dati.
- **Stato della risposta.** Nel binding sono registrati 400, 502 e 500, ciascuno con lo schema errorResponse. Ogni stato crea un messaggio di errore (client-400-Fault, server-502-Fault, server-500-Fault): la Reply sceglie con _Reply With_.
- **Corpo dell’errore.** code, message e correlationId; details dove serve a indicare il campo.

Prove: ‘ZZZ’ sul servizio reale → 400; JPY sul mock → 502; una data impossibile come 2026-02-30 (supera il controllo del formato e fa fallire xsd:date in At_DeliveryDate) → 500. Nei log il messaggio di LogError mostra At_FxRate e \[404\] oppure \[500\].

### Test e risultati

| **Test** | **Scenario** | **Esito atteso** | **Stato** |
| --- | --- | --- | --- |
| G3-T1 | IT, valuta JPY, mock | 502 UPSTREAM_FX_UNAVAILABLE con correlationId; due tentativi nel log | OK  |
| G3-T2 | FR, consegna di sabato, mock | 200; data 2026-10-12, motivo WEEKEND | OK  |
| G3-T3 | ES, consegna di sabato, mock | Stessa risposta di G3-T2 in meno di 8 secondi | OK  |
| G3-T4 | Ordine valido qualsiasi | I due processi atomici partono a meno di 200 ms | OK  |
| G3-T5 | Header X-Correlation-Id: TEST-G3T4 | Lo stesso valore in tutte le righe di log | OK  |
| E2E-4 | 20 richieste valide consecutive, mock | 20 risposte 200, nessun errore nei log | OK  |
| E2E-5 | Collection Runner completo, mock e reale | Test dei giorni 1 e 3 sul mock, del giorno 2 sul reale | OK  |

### Esecuzione test E2E

La collection E2E-4 ha una sola richiesta con il corpo a variabili e un file dati con 20 righe, ciascuna con i valori attesi (totali, data, motivo, tasso). Gli ordini usano IT, DE, NL, BE e PT e le valute USD, EUR, GBP e CHF: sono esclusi JPY, FR ed ES (guasti del mock) e le date 2026-10-04 e 2026-11-01, presenti solo in uno dei due elenchi di festività del mock.  
Con le property sul mock e le applicazioni appena avviate ci si aspetta, oltre alle 20 risposte 200, nessun ERROR nei log, 4 LogCacheMiss e 16 LogCacheHit (una chiamata alle festività per paese) e 15 chiamate al cambio (le 5 in EUR non ne fanno).

- **Postman:** Collection Runner con l’ambiente Mock e il file dati.
- **Newman**, da terminale, senza account né agent:

_newman run E2E-4_collection.postman_collection.json -d E2E-4_data.json  
\-r cli,json --reporter-json-export e2e4_risultati.json_

### Problemi incontrati e soluzioni

| **Sintomo** | **Causa** | **Soluzione** |
| --- | --- | --- |
| Dal correlationId al primo tentativo passano 2-3 minuti | Sleep con intervallo 0 nel gruppo di retry (nella build in uso 0 non è «nessuna attesa») | Intervallo di 1 ms al primo tentativo. |
| Cannot invoke "…PmLink.getState(…)" because "link" is null nel log, e la chiamata non parte | Errore interno del motore: transition corrotte dopo aver copiato attività e averle spostate in un gruppo | Cancellare e ridisegnare le transition del gruppo e quelle intorno; _Project > Clean_. Gli avvisi _Recreate missing activity id_ si risolvono con il _Quick Fix_. |
| $\_error/Msg non compare nell’albero del Catch All | Nel Catch All il fault ha una variabile propria | Usare $FaultDetails/Msg, trascinandolo dall’albero. |
| Con “ZZZ” il cambio rispondeva 502 e non 400, con ActivityTimedOutException | Il timeout era troppo corto per la prima chiamata verso il servizio reale, che impiega circa 2 secondi tra connessione e TLS | fx.timeoutMs a 3000. Dopo ogni riavvio il primo ordine è più lento: conviene un ordine di riscaldamento prima di cronometrare. |

### Limiti noti e punti aperti

- Il retry vale anche per i 4xx: la condizione di stop del gruppo non vede l’errore (vedi _Timeout e retry_).
- Il Catch All di GetHolidays assorbe ogni errore del processo, non solo quelli di Nager.Date; la causa è nel log.
- Un errore non legato al cambio che nasca dentro At_Enrich finisce nella risposta 500, perché le condizioni 400 e 502 richiedono At_FxRate nel messaggio.
- L’array **warnings** della risposta: L’assertion _expected \[ '' \] to deeply equal \[\]_ dice che il tuo warnings è \[""\], cioè un array con un elemento che è una stringa vuota, non un array vuoto.  
    Quando mappa l’espressione “_if (...) then 'HOLIDAY_CHECK_SKIPPED' else ()_“ direttamente sul nodo warnings, BW crea sempre un elemento: con la sequenza vuota nasce un warnings con testo vuoto.
