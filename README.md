# Viaduct for macOS

Viaduct is a native SwiftUI app wrapped around the
[`@magicelk235/viaduct`](https://www.npmjs.com/package/@magicelk235/viaduct) CLI.
It turns a Chrome extension into a Safari Web Extension, and you never have to
open a terminal to do it.

## What it does

- Pick a `.zip`, a `.crx`, or an unpacked extension folder, then hit convert.
- Every CLI flag has a control in the UI: output directory, bundle id, app name,
  target platforms (macOS, iOS, or both), CI mode, temp-load, build toggle,
  install, signing (ad-hoc, an auto-detected team, or a Team ID you type in),
  shim, force, and verbose.
- Analyze and Doctor buttons, for a report-only pass and a toolchain check.
- The output pane streams the CLI's stdout and stderr as it runs, so a slow
  build looks slow instead of looking hung.
- Install straight from the Chrome Web Store through the
  `viaduct://install?id=<ID>&name=<NAME>` URL scheme. The app downloads the
  `.crx` and converts it. Pass `name` if you want the finished app named after
  the store listing rather than the extension's random-looking ID. Names written
  as Chrome `__MSG_` i18n keys get resolved out of `_locales`.
- Auto-renew, in Settings under Signing, on by default. Free Apple accounts only
  sign extensions for about a week, and after that Safari quietly stops loading
  them. The app rebuilds and re-signs anything it installed before that week runs
  out, using the Apple identity it finds in your Xcode setup.
- The CLI isn't baked into the app. Viaduct downloads
  `@magicelk235/viaduct` from npm the first time you open it, keeps it in
  Application Support, and checks on every later launch whether a newer one has
  shipped. An app build from six months ago still converts with today's engine,
  and you never press anything to make that happen.

## Install

```sh
brew install --cask magicelk235/magicelklabs/viaduct
```

## Requirements

macOS 13 or later, on Apple Silicon or Intel. The app is a universal binary and
so is the `node` it carries, so neither chip needs Rosetta.

You do need a full Xcode install, because `safari-web-extension-packager` and
`xcodebuild` come from it. Apple ships the Safari packager with Xcode only, not
with the Command Line Tools, so there's no bundling around it. If Xcode is
missing, the app notices on your first convert and links you to the free install
instead of failing quietly.

Node.js is not a requirement. The app carries its own self-contained `node` in
`Contents/Resources/bin/`, and falls back to a system `node` only if that one has
somehow gone missing.

The first launch needs a network connection, since that's when the conversion
engine is fetched from npm. It takes a couple of seconds, and after that the
only thing Viaduct goes online for is checking whether a newer engine has
shipped.

One thing worth knowing: the app isn't sandboxed. It shells out to `node`,
`xcodebuild`, `lsregister`, and `open`, all of which the macOS App Sandbox
blocks, so it ships unsandboxed and can't be a Mac App Store app. It's
distributed as a notarized direct download.

## License

[PolyForm Shield License 1.0.0](LICENSE), copyright 2026 Yehonatan Cohen
(magicelk235). Use it, change it, pass it around. The one thing you can't do is
use it to build something that competes with Viaduct.
