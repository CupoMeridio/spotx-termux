# SpotX-Termux 🎧📱

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
Prima di avviare l'installazione su Termux, installa le due applicazioni necessarie:

1. **Termux**: Scarica l'APK da [F-Droid](https://f-droid.org/packages/com.termux/) oppure da [GitHub Releases](https://github.com/termux/termux-app/releases) *(NON usare la versione obsoleta del Google Play Store)*.
2. **Termux-X11**: Scarica l'APK companion da [GitHub Releases](https://github.com/termux/termux-x11/releases) (consigliato: `termux-x11-universal-debug.apk`).

---

### 2. Comando di Installazione
Apri Termux e incolla il seguente comando:

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

## ⚙️ Struttura dei File

```
spotx-termux/
├── install.sh              # Script di installazione principale
├── README.md               # Documentazione e guida d'uso
└── src/
    ├── guest-setup.sh      # Script eseguito dentro Ubuntu PRoot (Box64, Spotify, SpotX)
    └── start-spotify.sh    # Script host per avviare PulseAudio, X11 e Spotify
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
