# Viaduct — App

A native macOS app (SwiftUI) that wraps the
[`@magicelk235/viaduct`](https://www.npmjs.com/package/@magicelk235/viaduct) command-line tool
in a graphical interface. Convert a Chrome extension into a Safari Web Extension
without touching the terminal.

## Features

- Pick a `.zip`, `.crx`, or unpacked extension folder and convert with one click.
- Every CLI flag exposed as a control: output dir, bundle id, app name,
  platforms (macOS / iOS / both), CI mode, temp-load, build toggle, install,
  signing (ad-hoc / auto-detected team / custom Team ID), shim, force, verbose.
- **Analyze** and **Doctor** buttons for report-only and toolchain checks.
- Live, scrolling output pane that streams the CLI's stdout/stderr.
- **Install straight from the Chrome Web Store** via the `viaduct://install?id=<ID>&name=<NAME>`
  URL scheme. The app downloads the `.crx` and converts it. Pass `name` so the
  converted app is named after the store listing, not its random-looking ID.
  (Names that use Chrome's `__MSG_` i18n keys are resolved from `_locales` too.)
- **Auto-renew** (Settings → Signing, on by default): free Apple accounts sign
  extensions for ~7 days, after which Safari drops them. The app rebuilds and
  re-signs installed extensions before that lapses, using the Apple identity it
  auto-detects from Xcode — so they never silently disappear.
- **Self-updating CLI**: on launch the app checks npm and, if a newer
  `@magicelk235/viaduct` exists, installs it automatically — no button, no app rebuild.

## Install

```sh
brew install --cask magicelk235/magicelklabs/viaduct
```

## Requirements

- macOS 13+, Apple Silicon or Intel (the app ships as a universal binary, and the
  bundled `node` is universal too, so neither chip needs Rosetta)
- A full Xcode install (for `safari-web-extension-packager` and `xcodebuild`).
  Apple ships the Safari packager only with Xcode, not the Command Line Tools, so
  this can't be bundled away. The app detects a missing Xcode on first convert and
  links a one-click (free) install instead of failing silently.

Node.js is **not** required — the app bundles its own self-contained `node` under
`Contents/Resources/bin/`, so users install nothing for the runtime. (A system
`node` is used only as a fallback if the bundled one is somehow absent.)

> **Not sandboxed.** The app shells out to `node`, `xcodebuild`, `lsregister`,
> and `open`, which the macOS App Sandbox forbids — so it ships unsandboxed and
> is **not** a Mac App Store app. Distribute as a notarized direct download.

## License

Licensed under the [PolyForm Shield License 1.0.0](LICENSE). Copyright (c) 2026
Yehonatan Cohen (magicelk235). You may freely use, modify, and share it — but
you may not use it to build a product that competes with Viaduct.
