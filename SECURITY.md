# Security

## Reporting a vulnerability

Use **[Report a vulnerability](../../security/advisories/new)** (Security tab of this repository): the report stays private until it is fixed. Please don't open a public issue for a vulnerability.

Include the Plume version, the macOS version and, if possible, steps to reproduce. Expect a reply within 7 days.

## Supported versions

Only the latest release receives fixes.

## What Plume protects

- Your voice and text stay on your Mac. The cleanup server (`llama-server`) listens on `127.0.0.1` only.
- History is a SQLite database in `~/Library/Application Support/Plume`, readable only by your user account.
- The network is used only to download models from Hugging Face on first launch.

## Verifying a download

Every published DMG carries a provenance attestation signed by GitHub Actions:

```sh
gh attestation verify Plume-x.y.z.dmg -R samr037/plume
```

The Sigstore bundle (`.sigstore.json`) is attached to each release for offline verification.

The app is not notarized by Apple (no Developer ID certificate): macOS asks for confirmation the first time you open it.
