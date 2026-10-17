# Sécurité

## Signaler une faille

Utilisez **[Signaler une vulnérabilité](../../security/advisories/new)** (onglet Security du dépôt) : le rapport reste privé jusqu'à sa correction. N'ouvrez pas d'issue publique pour une faille.

Indiquez la version de Plume, la version de macOS et, si possible, les étapes pour reproduire. Réponse visée sous 7 jours.

## Versions suivies

Seule la dernière release reçoit des correctifs.

## Ce que Plume protège

- La voix et le texte restent sur le Mac. Le serveur de mise au propre (`llama-server`) écoute uniquement sur `127.0.0.1`.
- L'historique est une base SQLite dans `~/Library/Application Support/Plume`, accessible au seul compte utilisateur.
- Le réseau sert uniquement à télécharger les modèles depuis Hugging Face au premier lancement.

## Vérifier un téléchargement

Chaque DMG publié porte une attestation de provenance signée par GitHub Actions :

```sh
gh attestation verify Plume-x.y.z.dmg -R samr037/plume
```

L'app n'est pas notarisée par Apple (pas de certificat Developer ID) : macOS demande une confirmation à la première ouverture.
