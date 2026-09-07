# SpotX-Termux 🎧📱

[![English](https://img.shields.io/badge/lang-en-red.svg)](README.md)

> **Esecuzione del client Desktop Linux di Spotify con patch SpotX su Android tramite Termux, PRoot, Box64 e Termux-X11.**  
> *Progetto sviluppato a scopo didattico e di ricerca sull'emulazione user-space e containerizzazione su architettura ARM64.*

---

## 📖 Panoramica del Progetto

Spotify per Linux viene distribuito ufficialmente soltanto per architetture **x86_64**.  
Questo progetto realizza una catena automatizzata per eseguire il client desktop patchato con [SpotX-Bash](https://github.com/SpotX-Official/SpotX-Bash) direttamente su un dispositivo Android:

```
┌────────────────────────────────────────────────────────┐
│                   Android OS (ARM64)                   │
├──────────────────────────┬─────────────────────────────┤
│   Termux-X11 (.apk)      │     Audio Android           │
│   Display Server GUI     │     (OpenSL / AAudio)       │
└────────────▲─────────────┴──────────────▲──────────────┘
             │                            │
             │ Display :0                 │ PulseAudio TCP
             │                            │ (127.0.0.1:4713)
┌────────────┴────────────────────────────┴──────────────┐
│                  Termux (User Space)                   │
│   pulseaudio daemon + termux-x11 display bridge        │
│   └── proot-distro (Ubuntu 24.04 LTS Noble)            │
│         │                                              │
│         ├── Box64 (CPU Emulator x86_64 -> ARM64)       │
│         ├── Spotify Desktop Linux (x86_64)             │
│         └── SpotX-Bash (Frontend ad-block patch)       │
└────────────────────────────────────────────────────────┘
```

---

## ⚡ Installazione Rapida (One-Liner)

### 1. Prerequisiti su Android
Prima di avviare l'installazione su Termux, installa le applicazioni necessarie:

- **Obbligatorie:**
  1. **Termux**: Scarica l'APK da [F-Droid](https://f-droid.org/packages/com.termux/) oppure da [GitHub Releases](https://github.com/termux/termux-app/releases) *(NON usare la versione obsoleta del Google Play Store)*.
  2. **Termux-X11**: Scarica l'APK companion da [GitHub Releases](https://github.com/termux/termux-x11/releases) (consigliato: `termux-x11-universal-debug.apk`).

- **Facoltativo (consigliato per comodità):**
  3. **Termux:Widget**: Scarica l'APK da [F-Droid](https://f-droid.org/packages/com.termux.widget/) oppure da [GitHub Releases](https://github.com/termux/termux-widget/releases). Permette di aggiungere una comoda icona/widget sulla home screen dello smartphone per avviare Spotify con un singolo tocco.  
     > ⚠️ **Importante**: Devi scaricare il widget dalla **stessa identica fonte** usata per Termux (entrambi da F-Droid oppure entrambi da GitHub Releases). Se provengono da fonti diverse, Android ne bloccherà l'installazione per incompatibilità della firma crittografica. (Questo vincolo non si applica a Termux-X11, che è un'app indipendente).

---

### 2. Comando di Installazione
Apri Termux e incolla i seguenti comandi:

#### Opzione consigliata (scarica, verifica e poi esegui):
```bash
curl -sSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/install.sh -o install.sh
less install.sh   # Controlla il contenuto dello script
bash install.sh
```

#### Esecuzione diretta (one-liner):
```bash
curl -sSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/install.sh | bash
```

Lo script si occuperà in totale autonomia di:
- Installare i pacchetti Termux richiesti (`proot-distro`, `pulseaudio`, `x11-repo`, `termux-x11-nightly`).
- Creare il container **Ubuntu 24.04 LTS**.
- Configurare **Box64** (su CPU ARM64) o usare l'esecuzione nativa (su x86_64).
- Scaricare e scompattare il client ufficiale di Spotify.
- Applicare la patch **SpotX** in modalità non interattiva.
- Configurare i lanciatori e il bridge audio.

---

## 🚀 Avvio dell'Applicazione

Dopo il termine dell'installazione, puoi avviare Spotify in qualsiasi momento con un singolo comando:

```bash
spotify
```
*(oppure `./start-spotify.sh`)*

### Dietro le quinte:
1. Viene avviato il demone PulseAudio per instradare l'audio verso il driver Android.
2. Viene inizializzato il display server Termux-X11.
3. L'app Termux-X11 viene portata automaticamente a schermo intero.
4. Spotify viene avviato dentro Ubuntu PRoot con i flag di sandboxing disattivati (`--no-sandbox`).

### Avvio con Widget da Home Screen (Termux:Widget)
Se hai installato il plugin **Termux:Widget**, aggiungi un widget di Termux sulla home del tuo smartphone: troverai direttamente la scorciatoia `Spotify` per avviare il tutto con un solo tocco senza aprire il terminale.

---

## 🔄 Aggiornamento e Manutenzione

Spotify e SpotX possono essere aggiornati in qualsiasi momento senza reinstallare l'intero ambiente container:

```bash
spotify-update
```

Lo script verifica la versione installata rispetto a quella più recente del repository APT Spotify:
- Se Spotify è già aggiornato, **salta il download (~150 MB risparmiati)** e verifica/ri-applica solo la patch SpotX se necessario.
- Se è disponibile una nuova versione, scarica il nuovo pacchetto deb, ne verifica l'integrità SHA256, lo estrae e applica la patch SpotX.

### Opzioni di comando:
- **Verificare solo la versione** (nessuna modifica al sistema):
  ```bash
  spotify-update --check
  ```
- **Ri-applicare solo la patch SpotX** (utile per rinnovare patch/filtri SpotX senza toccare i binari Spotify):
  ```bash
  spotify-update --spotx-only
  ```
- **Aggiornare solo il client Spotify** (senza applicare SpotX):
  ```bash
  spotify-update --skip-spotx
  ```

---

## ⚙️ Struttura dei File

```
spotx-termux/
├── install.sh              # Script di installazione principale
├── README.md               # Documentazione ufficiale (Inglese)
├── README.it.md            # Documentazione (Italiano)
└── src/
    ├── guest-setup.sh      # Script eseguito dentro Ubuntu PRoot (Box64, Spotify, SpotX)
    ├── start-spotify.sh    # Script host per avviare PulseAudio, X11 e Spotify
    └── update-spotify.sh   # Script host per verificare e applicare aggiornamenti
```

---

## 🛠️ Risoluzione Problemi & Consigli

* **Audio che si interrompe in background:**  
  Android applica restrizioni aggressive sul risparmio energetico. Vai nelle *Impostazioni Android > App > Termux > Batteria* e imposta **Senza restrizioni**.
* **Controlli touch in Termux-X11:**  
  Nelle impostazioni di Termux-X11 (accessibili scorrendo il pannello notifiche o con un swipe a 4 dita), puoi impostare il touchpad virtuale per un controllo fluido del cursore mouse.
* **Schermo nero o crash all'avvio:**  
  Assicurati che l'app Termux-X11 sia installata e che le siano stati concessi i permessi richiesti.

---

## ⚖️ Note Legali e Disclaimer
Questo repository è creato esclusivamente a fini educativi e di ricerca accademica sul funzionamento di runtime POSIX, traduzione dinamica di istruzioni (Box64) e containerizzazione user-space su Android. Spotify è un marchio registrato di Spotify AB. L'uso di script di terze parti avviene sotto la propria esclusiva responsabilità.
