# Viaduct — launch posts (paste-ready)

Site: https://magicelklabs.com/viaduct
CLI: https://www.npmjs.com/package/@magicelk235/viaduct
Buy: $19 one-time (2 free conversions)

---

## 1. Reddit — r/macapps (POST FIRST)

**Post type:** Video post (attach the demo `.mp4` directly — do NOT link YouTube; native video autoplays and outperforms).

**Title:**
```
I built a Mac app that runs any Chrome extension in Safari
```

**Body:**
```
Safari's extension library is thin — half the extensions I use daily (uBlock Origin, Dark Reader, a couple of dev tools) never shipped for it. Apple *does* have a conversion path, but it needs Xcode and the terminal, which is a non-starter for most people.

So I built Viaduct. You drag in a Chrome extension (or paste a Chrome Web Store link) and it converts it into a real native Safari Web Extension, signs it, and installs it. One click, no terminal.

A few things I cared about:
- The conversion engine is source-available (PolyForm Shield, on npm as @magicelk235/viaduct), so the paid app is just the GUI on top.
- It bundles its own Node runtime, so there's nothing to install for the conversion itself. (Xcode is still required — Apple gives no other way to code-sign a Safari extension.)
- Free accounts only sign extensions for ~7 days before Safari drops them, so the app quietly re-signs installed extensions before that lapses. They don't silently disappear.

Free for your first 2 conversions, then $19 one-time (no subscription).

Site + demo: https://magicelklabs.com/viaduct

Happy to answer anything — and genuinely curious which extensions people most want in Safari.
```

**Reply prep (paste as a comment when someone asks "is this safe / how does it work"):**
```
The conversion is just Apple's own safari-web-extension-packager under the hood — Viaduct automates the steps around it (unpacking, naming, signing, install) so you don't touch Xcode's CLI. The engine's open source if you want to read exactly what it does: https://www.npmjs.com/package/@magicelk235/viaduct
```

---

## 2. Hacker News — Show HN (POST SECOND, after r/macapps warms up)

**URL to submit:** https://magicelklabs.com/viaduct/
(HN prefers the product URL, not a blog post. Use trailing slash — the bare path 301-redirects.)

**Title:**
```
Show HN: Viaduct – run any Chrome extension in Safari
```
(No price/CLI parenthetical in the title — those go in the first comment. Leave the "text" box empty when a URL is set.)

**First comment (post immediately after submitting — HN norm for Show HN):**
```
I made this because Safari's extension catalog is thin and every extension I wanted was Chrome-only. Apple has a conversion tool (safari-web-extension-packager) but it's Xcode + terminal only, so it's out of reach for most people who'd actually use these extensions.

Viaduct wraps that. The conversion engine is source-available under the PolyForm Shield license and on npm (@magicelk235/viaduct), so you can convert from the CLI for free forever. The Mac app is a paid GUI ($19 one-time, 2 free conversions) that adds the stuff that's annoying to script: Chrome Web Store install via a URL scheme, auto re-signing before free-account 7-day signatures expire, and self-updating.

Some technical notes / things I learned:
- It bundles a self-contained Node so end users install nothing for the runtime. Xcode is still unavoidable — Apple provides no other way to code-sign a .appex, even ad-hoc.
- Not sandboxed, so it can't be a Mac App Store app — it shells out to node/xcodebuild/lsregister. Notarized direct download instead.
- The 7-day free-signing expiry was the surprise. Extensions just vanish from Safari after a week on a free Apple account; the app rebuilds + re-signs ahead of that.

CLI: https://www.npmjs.com/package/@magicelk235/viaduct

Happy to go deep on the packaging pipeline or the Safari signing quirks — that part was the most interesting to build.
```

---

## 3. Product Hunt — Show (SCHEDULE for a Tue–Thu, 12:01am PT go-live)

Not instant — you schedule a future launch. Prep now. Gallery: demo video FIRST,
then cover image, then 2–3 app screenshots (video-first ranks best). Organic-only
launch → aim for top-5/10 Product of the Day, not #1; the badge + backlink is the
lasting value. Sequence PH AFTER HN + X so those threads become your organic support.

**Name:**
```
Viaduct
```

**Tagline** (60 char max):
```
Run any Chrome extension in Safari
```

**Topics:** Mac · Safari · Browser Extensions · Developer Tools · Productivity

**Description:**
```
Safari's extension library is thin, and uBlock Origin, Dark Reader and half your dev tools never shipped for it. Viaduct converts any Chrome extension into a native Safari extension, signs it, and installs it. One click, no terminal. CLI engine is source-available (PolyForm Shield). $19 one-time.
```

**Link:** https://magicelklabs.com/viaduct/

**First maker comment (post at launch):**
```
Maker here 👋

Built Viaduct because Safari's extension catalog is thin and every extension I actually wanted was Chrome-only. Apple has a conversion path but it's Xcode + terminal — a non-starter for most people.

Viaduct does it in one click: drag in a Chrome extension (or paste a Web Store link), it converts to a real native Safari extension, signs, and installs.

A few things I sweated:
• Conversion engine is source-available under PolyForm Shield, on npm (@magicelk235/viaduct), and the app is the GUI on top.
• Bundles its own Node, so nothing to install for the runtime.
• Free Apple accounts sign extensions for only ~7 days before Safari drops them — so the app quietly re-signs before that lapses. They don't vanish.

Free for 2 conversions, then $19 one-time (no subscription). Would love to know which extensions you most want in Safari.
```

---

## Posting order & timing

1. **r/macapps first** — weekday morning US time (Tue–Thu best). Video attached. Reply to every comment in first 3 hrs (drives the algo).
2. **Show HN second** — separate day, weekday ~8–10am ET (HN's window). Post the first comment within 60 sec of submitting.
3. Don't cross-post the same day — spreads your reply attention too thin, and a dead early thread hurts.
4. **r/safari** as a lighter follow-up a few days later (retarget the same video, trim body).

## Do NOT
- Don't lead with the $19 price in any title. Demo/pain first, price in body.
- Don't post from a fresh brand account on Reddit/HN — personal account, real "I built this" voice.
- Don't auto-post or auto-reply. Both platforms ban it. Manual only.
