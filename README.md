# Plume

Dictée vocale pour macOS, 100 % locale. Maintenez **fn**, parlez, relâchez : Plume transcrit, met le texte au propre et le colle là où se trouve le curseur. La voix et le texte ne quittent jamais le Mac.

*Local voice dictation for macOS (Apple Silicon). Hold fn, speak, release: Plume transcribes, cleans up and pastes the text at the cursor. Nothing leaves your Mac.*

- **Transcription :** Parakeet (Core ML, sur le Neural Engine), Whisper en option
- **Mise au propre :** Qwen3.5 4B avec llama.cpp (ponctuation, hésitations, styles par app)
- **Réunions :** détection des appels, transcription, séparation des interlocuteurs, compte rendu et tâches
- **Réécritures rapides** (⌃⌥1…9), **bloc-notes** (⌃⌥N), mode **Instruct** (⌃ + fn)
- Interface en français et en anglais

## Installer

1. Téléchargez le dernier `Plume-x.y.z.dmg` dans [Releases](../../releases).
2. Glissez Plume dans Applications.
3. Ouvrez Plume. L'app n'est pas signée par un développeur Apple identifié : macOS la bloque la première fois. Ouvrez **Réglages Système › Confidentialité et sécurité** et cliquez sur **Ouvrir quand même**.
4. Suivez le guide de bienvenue. Plume télécharge ses modèles (environ 4 Go) pendant ce temps, et demande l'accès au **Micro** et à l'**Accessibilité**.

Configuration requise : Mac Apple Silicon (M1 ou plus récent), macOS 14 ou plus, environ 5 Go d'espace libre.

Recommandé : Réglages Système › Clavier › « Appuyer sur 🌐 pour » → **Ne rien faire**.

## Utiliser

| Geste | Effet |
|---|---|
| Maintenir fn | Dicter : relâcher transcrit et colle |
| Double-tap fn ou fn+espace | Mains-libres : fn pour terminer |
| fn + une autre touche, ou Échap | Annule la dictée |
| ⌃⌘V | Recolle la dernière dictée |
| ⌃⌥1…9 | Réécrit la sélection (plus formel, plus court, en anglais…) |
| ⌃⌥N | Bloc-notes |
| ⌃ puis fn | Instruct : rédiger, traduire, répondre, retenir une préférence |

La barre flottante se déplace sur n'importe quel bord de l'écran ; un clic dessus lance une dictée mains-libres, un clic droit ouvre le menu.

## Compiler

```sh
scripts/test.sh                      # tests
WL_SIGN=- scripts/build-app.sh       # ~/Applications/Plume.app, signature ad hoc
scripts/make-dmg.sh ~/Applications/Plume.app dist/Plume.dmg
```

Sans `WL_SIGN`, le script crée un certificat local « Plume Dev » : macOS garde alors l'autorisation d'Accessibilité d'un build à l'autre. Les releases sont produites par GitHub Actions à chaque tag `v*` (`.github/workflows/release.yml`).

Options de diagnostic : `--selftest fichier.wav`, `--bench a.wav b.wav`, `--instruct "demande"`, `--snapshot <dossier>`.

`wl-mcp` expose l'historique, les réunions et les tâches à un client MCP (voir [docs/mcp.md](docs/mcp.md)).

## Architecture

- `Sources/PlumeCore` : machine d'états du raccourci, post-traitement, filtres, prompts, stockage SQLite (testé)
- `Sources/MeetingKit` : détection des appels, capture micro et son système
- `Sources/Plume` : app (raccourci global, audio, moteurs, collage, interface SwiftUI)
- `Sources/wl-mcp` : serveur MCP local en lecture seule

## Licence

MIT, voir [LICENSE](LICENSE). Composants et modèles tiers : [Resources/THIRD_PARTY_NOTICES.md](Resources/THIRD_PARTY_NOTICES.md).

Plume est un projet indépendant, sans lien avec un autre éditeur de logiciel de dictée.
