# Viaduct for macOS

Viaduct is a native SwiftUI app wrapped around the
[`@magicelk235/viaduct`](https://www.npmjs.com/package/@magicelk235/viaduct) CLI.
It turns a Chrome extension into a Safari Web Extension, and you never have to
open a terminal to do it.

## What it does

- Pick a `.zip`, a `.crx`, or an unpacked extension folder, then hit convert.
- Signing is automatic: Viaduct uses the Apple account signed in to Xcode and
  prefers a paid developer team over a personal one when you have both.
- If a conversion fails, the error offers Try again, Report this issue, and a
  copy of the CLI's full log. Anyone who wants every CLI flag can run the CLI
  directly.
- Install straight from the Chrome Web Store through the
  `viaduct://install?id=<ID>&name=<NAME>` URL scheme. The app downloads the
  `.crx` and converts it. Pass `name` if you want the finished app named after
  the store listing rather than the extension's random-looking ID. Names written
  as Chrome `__MSG_` i18n keys get resolved out of `_locales`.
- On the free plan, Viaduct removes a converted extension 7 days after converting
  it, with reminders 3 days and 1 day before. A license for that browser keeps them,
  including ones converted before activating. Extensions converted before this limit
  existed are kept.
- The CLI isn't baked into the app. Viaduct downloads
  `@magicelk235/viaduct` from npm the first time you open it, keeps it in
  Application Support, and checks on every later launch whether a newer one has
  shipped. An app build from six months ago still converts with today's engine,
  and you never press anything to make that happen.

## Also in the app

- **First-launch setup.** A fresh install opens on a short setup: install or
  finish Xcode, sign in to it with an Apple ID, let Viaduct read your browsers,
  and (optionally) turn on the Add to Safari button. It ends by offering to
  import your browser extensions. Settings → General → Run Setup Again repeats it.

- **Import from Chrome.** Lists the extensions installed in Chrome, Brave, Edge,
  Arc, Vivaldi and Opera (every profile) and converts the ones you tick, one
  after another. It also picks up extensions loaded unpacked. Open it from
  File → Import from Chrome… (⇧⌘I) or the last step of setup.
- **Official Safari versions.** When the maker of an extension already
  publishes it for Safari (1Password, Bitwarden, AdGuard, Dark Reader and a few
  dozen more), the app says so and links to it. Installs from the store page ask
  first.
- **Won't-work check.** As soon as you pick an extension, the app checks it
  for problems Safari won't accept, like a file the manifest names but the
  package doesn't have. If it finds one, it says so before you spend a
  conversion. Warnings that might not matter stay out of it. Ad blockers built
  on blocking `webRequest` convert without a warning: they install and hide
  page elements, but Safari won't let them block requests.
- **Prefilled problem reports.** "Report this issue" opens the CLI's issue form
  with the extension, versions and the end of the log already filled in. A
  converted extension that misbehaves gets a Report a Problem button in its
  history sheet.
- **Bring settings over from Chrome.** Reads the extension's saved
  `chrome.storage.local` and `storage.sync` out of the browser profile and
  seeds them into the Safari version the first time it runs, as long as the
  Safari copy has no settings of its own yet.
- **Convert several at once.** Drop or pick more than one extension and they
  convert in a queue.
- **Move to another Mac.** Settings → Move to another Mac exports your converted
  extensions to a zip. Importing it on the other Mac converts them all again,
  signed for that Mac.
- **Shortcuts.** Convert Chrome Extension and List Converted Extensions show up
  in the Shortcuts app.

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
