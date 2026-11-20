# Security Policy

LocalFlow listens to your microphone and types into other apps, so we take security seriously.

## Supported versions

Only the [latest release](https://github.com/QuantummDuck/LocalFlow/releases/latest) receives security fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through [GitHub Security Advisories](https://github.com/QuantummDuck/LocalFlow/security/advisories/new) with a description, steps to reproduce and the affected version. You can expect an initial response within a week.

## Design notes

- Audio, transcripts, history and the dictionary are stored only in `~/Library/Application Support/LocalFlow/`.
- The app makes network requests only to download models (GitHub Releases and Hugging Face) and when you use the "search" voice command.
- The clipboard is used to paste and is restored afterwards.
