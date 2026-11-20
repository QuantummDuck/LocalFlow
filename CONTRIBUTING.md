# Contributing to LocalFlow

Thanks for helping make LocalFlow better! Bug reports, ideas, translations and pull requests are all welcome.

## Reporting bugs and requesting features

- Search [existing issues](https://github.com/QuantummDuck/LocalFlow/issues) first.
- Use the **Bug report** or **Feature request** form. For bugs, include your macOS version, Mac model and the steps to reproduce.
- Please don't attach recordings or history files that contain private information.

## Development setup

1. Install Xcode 26+ and XcodeGen: `brew install xcodegen`.
2. Clone the repo and run `scripts/install.sh`. It builds a Release app, installs it to `/Applications` and launches the model download on first run.
3. Before opening a pull request, run the self-test:

   ```bash
   swift build -c release --product flowbench && .build/release/flowbench selftest
   ```

The Xcode project is generated from `App/project.yml`; don't commit `LocalFlow.xcodeproj`.

## Pull requests

- Keep each PR focused on one change and describe what it does and how you tested it.
- Follow the existing style: small, readable Swift, no new dependencies without discussion.
- Text-processing changes (cleanup guard, snippets, dictionary, styles) should come with a check in `Sources/flowbench/main.swift` (`selftest`).
- UI changes: include a before/after screenshot.
- Never commit models, training data, history or audio. `.gitignore` covers the usual paths.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating you agree to uphold it.
