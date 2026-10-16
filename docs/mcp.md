# Serveur MCP `wl-mcp`

`wl-mcp` est un serveur MCP local (transport **stdio**, JSON-RPC 2.0, un message JSON par ligne). Il permet à
Claude Code (ou à tout autre client MCP) d'interroger les dictées, les réunions, les todos et le dictionnaire de
Plume.

## Compilation

```sh
swift build -c release --product wl-mcp --scratch-path /private/tmp/wl-build-mcp
# binaire : /private/tmp/wl-build-mcp/release/wl-mcp
```

Le `--scratch-path` doit rester hors de `~/Claude`, sinon la synchronisation casse `build.db`. Copiez ensuite le
binaire à un emplacement stable, par exemple `~/.local/bin/wl-mcp`.

## Enregistrement dans Claude Code

```sh
# projet courant (scope local, par défaut)
claude mcp add plume -- ~/.local/bin/wl-mcp

# tous les projets (scope utilisateur)
claude mcp add --scope user plume -- ~/.local/bin/wl-mcp

# autre base que celle de l'app
claude mcp add --scope user plume -e WL_DB=/chemin/vers/plume.sqlite -- ~/.local/bin/wl-mcp
```

Pour vérifier, lancez `claude mcp list`, ou `/mcp` dans une session.

Par défaut, la base lue est `~/Library/Application Support/Plume/plume.sqlite`. Vous pouvez la changer
avec `--db <chemin>` (prioritaire) ou avec la variable `WL_DB`. Le journal est écrit uniquement sur stderr.

## Outils

| Outil | Arguments | Résultat |
|---|---|---|
| `search_dictations` | `query?`, `since?` (date ISO 8601, ex. `2026-10-01`), `limit?` = 20 | heure, application, texte final, texte brut s'il diffère |
| `list_meetings` | `query?` (titre, résumé, notes, transcription), `limit?` = 20 | id, titre, date, durée, plateforme, statut, 300 premiers caractères du résumé |
| `get_meeting` | `id`, `include_transcript?` = true, `max_chars?` = 20000 | métadonnées, résumé, notes, e-mail de suivi, todos, transcription `[mm:ss] Moi/Eux: texte` |
| `list_todos` | `open_only?` = true, `meeting_id?` | todos avec leur réunion d'origine |
| `add_todo` | `text`, `meeting_id?` | **seule écriture** : ajoute une todo |
| `get_dictionary` | — | mots, remplacements, snippets, préférences de style apprises |

Les résultats sont du texte de type Markdown, tronqué à environ 60 000 caractères. Pour `get_meeting`, la
transcription est plafonnée à `max_chars`. Dans la transcription, « Moi » correspond au micro de l'utilisateur et
« Eux » au son système, c'est-à-dire les autres participants.

Le serveur gère les révisions MCP 2024-11-05, 2025-03-26, 2025-06-18 et 2025-11-25, avec poignée de main
`initialize`. Un client de la révision 2026-07-28 qui sonde d'abord `server/discover` reçoit l'erreur `-32601` et
se rabat alors sur `initialize`. Erreurs JSON-RPC renvoyées :

- `-32601` : méthode inconnue ;
- `-32602` : outil inconnu ou argument invalide ;
- `-32700` : JSON illisible.

Une erreur métier, comme une réunion introuvable ou une base absente, revient sous la forme `isError: true`.

## Confidentialité

- **Tout reste local.** Le serveur n'ouvre aucune connexion réseau et ne fait que lire le fichier SQLite sur le
  Mac. En revanche, les extraits renvoyés entrent dans le contexte de Claude, comme tout autre résultat d'outil.
- **Lecture seule**, à une exception près : la base est ouverte en `SQLITE_OPEN_READONLY`, sans migration. Seul
  `add_todo` ouvre une connexion lecture-écriture dédiée (`TodoWriter.swift`), le temps d'un unique
  `INSERT INTO todo`. Cette connexion ne peut jamais créer de base ni modifier le schéma.
- Aucun outil ne supprime ni ne modifie les dictées, les réunions ou le dictionnaire.

## Test manuel (développement)

L'option `--seed` crée une base de démonstration au vrai schéma, via `Store(path:)`. Elle sert uniquement au
développement et refuse d'écraser un fichier existant.

```sh
wl-mcp --seed /tmp/wl-test.sqlite
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":1}}}' \
  | wl-mcp --db /tmp/wl-test.sqlite
```

Remarque : une base créée par une ancienne version de l'app (schéma v1) n'a pas encore les tables `meeting` et
`todo`. Les outils correspondants renvoient alors une erreur explicite. Il suffit de lancer une fois une version
récente de l'app pour migrer la base.
