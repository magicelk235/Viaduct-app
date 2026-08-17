function installViaduct(extId, name, btn) {
  let url = `viaduct://install?id=${extId}`;
  if (name) url += `&name=${encodeURIComponent(name)}`;
  window.location.href = url;
  // The app converts headless (no Viaduct window); the button becomes the UI.
  startProgressPolling(btn, extId);
}

// ---- Installed state ------------------------------------------------------
// Whether each store extension (by CWS id) is installed in Safari, so the page
// can show "Remove from Safari" instead of "Add to Safari". Filled lazily by
// asking the app (content -> background -> native handler -> app); a resolved
// answer that changes state re-runs apply() to repaint the button.
const installedById = new Map();      // id -> boolean (definitive answers only)
const installedInFlight = new Set();  // ids with a query in progress
const installedTried = new Map();     // id -> last attempt ms (backoff)

function currentDetailId() {
  const m = window.location.pathname.match(/\/detail\/[^/]+\/([a-z]{32})/);
  return m ? m[1] : null;
}

function isInstalledNow() {
  const id = currentDetailId();
  return !!(id && installedById.get(id) === true);
}

function desiredLabel() {
  return isInstalledNow() ? 'Remove from Safari' : 'Add to Safari';
}

// Teal = add (dark text), red = remove (white text).
function desiredPaint() {
  return isInstalledNow()
    ? { bg: '#B23B32', fg: '#FFFFFF' }
    : { bg: '#4A9DAD', fg: '#0A1A1E' };
}

// The Chrome Web Store localizes and even declines its button labels ("Add to
// Chrome", "Hinzufügen", "Přidat do Chromu", "Добавяне"), and translates the
// "Chrome Web Store" brand in its logo/footer links — so matching on text is
// unreliable and mislabels the logo. Google's internal jsname ids are stable
// across every locale, so key on those instead.
const CTA_SEL = 'button[jsname="wQO0od"]';        // the detail-page install button
const BANNER_BTN_SEL = 'button[jsname="oGfC5c"]'; // the "install Chrome" promo button

// Buttons we've already relabelled or injected, so a state flip repaints them.
function isOurLabel(text) {
  const t = (text || '').toLowerCase().trim();
  return t.includes('add to safari') || t.includes('remove from safari');
}

// Style our own injected button (not a repurposed store button) for the
// current add/remove state.
function paintInjected(btn) {
  const label = desiredLabel();
  // Steady-state no-op: bail once the button already reflects the desired mode.
  // Assigning textContent replaces child nodes — a childList mutation that would
  // re-fire the MutationObserver into apply() forever. The dataset flag (an
  // attribute, not watched) gates all writes so a stable state mutates nothing.
  if (btn.dataset.vdMode === label) return;
  const paint = desiredPaint();
  btn.dataset.vdMode = label;
  btn.textContent = label;
  btn.style.cssText = VD_BTN_CSS;
  btn.style.background = paint.bg;
  btn.style.color = paint.fg;
}

function refreshInstalled(id) {
  // Query once per id and keep the definitive answer. Install/remove update the
  // cache directly, so there's no need to re-poll on every mutation.
  if (!id || installedInFlight.has(id) || installedById.has(id)) return;
  const now = Date.now();
  if (now - (installedTried.get(id) || 0) < 1500) return; // backoff if app asleep
  installedTried.set(id, now);
  installedInFlight.add(id);
  browser.runtime.sendMessage({ type: 'viaduct-installed', id }).then(
    (res) => {
      installedInFlight.delete(id);
      if (res && typeof res.installed === 'boolean') {
        installedById.set(id, res.installed);
        apply(); // repaint with the real state
      }
      // No definitive answer (app unreachable): leave uncached so a later tick
      // retries. The button stays "Add to Safari" until then.
    },
    () => { installedInFlight.delete(id); }
  );
}

// "Remove from Safari" click: ask the app to delete the installed .app, then
// confirm by polling installed-state. The app reports no removal phases, so we
// verify the result instead of streaming progress.
function removeViaduct(id, btn) {
  window.location.href = `viaduct://remove?id=${id}`;
  const gen = ++pollGen;
  installState = { path: window.location.pathname, id };
  setState('Removing…', 'Deleting the Safari app', 0.5, '#B23B32');
  if (btn) renderProgress(btn);
  const startedAt = Date.now();
  const tick = async () => {
    if (gen !== pollGen) return;
    let installed = null;
    try {
      const req = browser.runtime.sendMessage({ type: 'viaduct-installed', id });
      req.catch(() => {});
      const res = await Promise.race([
        req, new Promise(resolve => setTimeout(() => resolve(null), 2000)),
      ]);
      if (res && typeof res.installed === 'boolean') installed = res.installed;
    } catch (e) { /* app asleep; try next tick */ }
    if (gen !== pollGen) return;
    if (installed === false) {
      installedById.set(id, false);
      setState('Removed ✓', 'Gone from Safari', 1, '#B23B32');
      // Return the card to an "Add to Safari" button shortly.
      setTimeout(() => { if (gen === pollGen) dismissProgress(); }, 1200);
      return;
    }
    if (Date.now() - startedAt > 15000) {
      setState('Remove failed', 'Open Viaduct to remove it.', 1, '#F87171');
      return;
    }
    setTimeout(tick, 700);
  };
  tick();
}

function removeChromePromos() {
  // Two locale-independent nags:
  //   1. The blue "Switch to Chrome to install extensions and themes" banner,
  //      located via the stable jsname of its "install Chrome" button.
  //   2. The "Switch to Chrome?" promo modal, identified by its stable
  //      aria-labelledby="promo-header" (the visible copy is localized, and in
  //      some locales, e.g. Japanese, omits the word "Google" entirely).
  const bannerBtn = document.querySelector(BANNER_BTN_SEL);
  if (bannerBtn && bannerBtn.offsetHeight) {
    // Hide the short banner row that wraps the button, not just the button:
    // climb to the tallest ancestor still under a banner's height, stopping
    // before the (tall) page content.
    let el = bannerBtn, row = null;
    for (let i = 0; i < 6 && el && el !== document.body; i++) {
      const h = el.offsetHeight;
      if (!(h > 0 && h < 120)) break;
      row = el;
      el = el.parentElement;
    }
    if (row) row.style.display = 'none';
  }

  let hidModal = false;
  for (const el of document.querySelectorAll('[aria-labelledby="promo-header"]')) {
    if (!el.offsetHeight) continue;
    if (hideChromeModal(el)) hidModal = true;
  }
  // A full-screen modal locks page scroll (inline overflow:hidden); hiding the
  // overlay leaves that lock in place, so clear it.
  if (hidModal) {
    document.documentElement.style.overflow = '';
    document.body.style.overflow = '';
  }
}

// Hide the whole modal overlay (dialog card + dimming backdrop), not just the
// card — otherwise the backdrop stays and swallows every click. Walk up to the
// dialog/fixed wrapper that holds both layers.
function hideChromeModal(el) {
  let node = el;
  for (let i = 0; i < 8 && node && node !== document.body; i++) {
    const role = node.getAttribute && node.getAttribute('role');
    if (
      node.tagName === 'DIALOG' ||
      role === 'dialog' ||
      role === 'alertdialog' ||
      getComputedStyle(node).position === 'fixed'
    ) {
      node.style.display = 'none';
      return true;
    }
    node = node.parentElement;
  }
  el.style.display = 'none';
  return true;
}

// Pill styling for the button we inject ourselves (also reapplied after a
// progress-card dismissal, which wipes inline styles).
const VD_BTN_CSS =
  'display:inline-flex;align-items:center;margin:10px 0;padding:10px 20px;' +
  'background:#4A9DAD;color:#0A1A1E;border:none;border-radius:99px;' +
  'font:600 14px/1 -apple-system,BlinkMacSystemFont,sans-serif;cursor:pointer;' +
  // The title header is a grid; without these the button gets squeezed into
  // a ~60px column and the label wraps.
  'white-space:nowrap;width:max-content';

// The store's client-side router omits its install button entirely on
// non-Chrome browsers: the initial server-rendered HTML has one (we relabel
// it), but SPA navigation re-renders the header without it, leaving nothing
// to repurpose — the button "disappears" when browsing between extensions.
// Inject our own below the title whenever a detail page has no button at all.
// A surviving store button (relabeled or not) or live progress card, other
// than `skip` (our own injected button).
function storeInstallButton(skip) {
  for (const btn of document.querySelectorAll('button, [role="button"], a')) {
    if (btn === skip) continue;
    if (btn.dataset.vdProgress) return btn;
    // Google keeps previous SPA views in the DOM inside display:none
    // containers — their leftover buttons don't count as present.
    if (!btn.offsetHeight) continue;
    if (btn.matches(CTA_SEL)) return btn;
  }
  return null;
}

function ensureInstallButton() {
  const injected = document.querySelector('.vd-install');
  // Never touch an injected button that became the live progress card.
  if (injected && injected.dataset.vdProgress) return;
  const onDetail = /\/detail\/[^/]+\/[a-z]{32}/.test(window.location.pathname);
  const store = storeInstallButton(injected);
  // A hidden injected button sits in a dead SPA view — stale, replace it.
  const keep = onDetail && !store && injected && injected.offsetHeight > 0;
  if (injected && !keep) injected.remove();
  // Keeping our live injected button: refresh its label, since an install or
  // remove may have changed the state and Google never re-renders our node.
  if (keep) { paintInjected(injected); return; }
  if (!onDetail || store) return;
  // Anchor on the visible title, not the first <h1> (that can be a dead view).
  const h1 = [...document.querySelectorAll('h1')].find(el => el.offsetHeight > 0);
  if (!h1) return; // header not rendered yet; the next mutation tick retries
  const btn = document.createElement('button');
  btn.className = 'vd-install';
  paintInjected(btn);
  h1.insertAdjacentElement('afterend', btn);
  // An install is running for this page and the SPA dropped the node that was
  // showing progress — the fresh button becomes the progress card.
  if (installState && window.location.pathname === installState.path) renderProgress(btn);
}

function enableInstallButton() {
  const label = desiredLabel();
  const paint = desiredPaint();
  // Match the store's install button by jsname, not text — its label is
  // localized and sometimes lacks the word "Chrome" entirely (e.g. German
  // "Hinzufügen"), and text matching wrongly caught the "Chrome Web Store" logo.
  for (const btn of document.querySelectorAll(CTA_SEL)) {
    // Already showing install/remove progress — leave it alone.
    if (btn.dataset.vdProgress) continue;
    // Skip a button hidden in a dead SPA view.
    if (!btn.offsetHeight) continue;

    // An install is running for THIS page and the SPA re-rendered the button
    // back to its store label — re-adopt it as the progress card.
    if (installState && window.location.pathname === installState.path) {
      renderProgress(btn);
      continue;
    }

    // The store disables the button on non-Chrome browsers; re-enable it.
    if (btn.hasAttribute('disabled')) {
      btn.removeAttribute('disabled');
    }
    btn.style.pointerEvents = 'auto';

    // Paint it the app's brand color so the repurposed button reads as "ours",
    // not Google's. setProperty(..., 'important') beats the store's own rules.
    btn.style.setProperty('background', paint.bg, 'important');
    btn.style.setProperty('color', paint.fg, 'important');
    btn.style.setProperty('border-color', paint.bg, 'important');

    // The button carries a single label text node (verified across locales);
    // rewrite it in place, preserving Google's font-bearing spans. Google resets
    // the label to its store text on SPA navigation, so relabel on every pass.
    const changeText = (el) => {
      for (const child of el.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          if (child.nodeValue.trim() && child.nodeValue.trim() !== label) {
            child.nodeValue = label;
          }
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          // Inherit the button text color over Google's per-span colors.
          child.style.setProperty('color', paint.fg, 'important');
          changeText(child);
        }
      }
    };
    changeText(btn);
  }
}

// The store is an SPA: it swaps page content via the History API without a full reload.
// We run on every store page (run_at document_start, so document.body may not exist yet)
// and keep a MutationObserver live for the whole session so client-side navigations are
// handled without a manual reload.
function apply() {
  removeChromePromos();
  enableInstallButton();
  ensureInstallButton();
  refreshInstalled(currentDetailId());
}

function start() {
  apply();
  // Content scripts run in an isolated world, so we can't hook the page's history.pushState
  // to catch SPA navigations. The MutationObserver is the reliable signal: every client-side
  // route change swaps DOM nodes, which fires this. It stays live for the whole session, so
  // navigating into an extension without a reload is handled. popstate covers back/forward.
  new MutationObserver(apply).observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('popstate', apply);
}

if (document.body) {
  start();
} else {
  document.addEventListener('DOMContentLoaded', start, { once: true });
}

document.addEventListener('click', (e) => {
  const btn = e.target.closest('button, [role="button"], a');
  if (!btn || btn.dataset.vdProgress) return;

  const text = (btn.textContent || '').toLowerCase().trim();
  // Act on our own button (injected or relabelled) or the store's install
  // button, matched by jsname since its label is localized.
  if (!btn.matches(CTA_SEL) && !btn.classList.contains('vd-install') && !isOurLabel(text)) return;

  // Store URL is /detail/<slug>/<id>. Capture both: the slug names the app so
  // it isn't named after the random-looking id.
  const match = window.location.pathname.match(/\/detail\/([^/]+)\/([a-z]{32})/);
  if (!match) return;
  e.preventDefault();
  e.stopPropagation();
  if (text.includes('remove from safari')) {
    removeViaduct(match[2], btn);
    return;
  }
  // The store title is "<Extension Name> - <Chrome Web Store>", the suffix
  // localized but always keeping the Latin word "Chrome"; drop that trailing
  // segment. De-slugged URL segment is the fallback.
  const fromTitle = document.title
    .replace(/\s*[-–|]\s*[^-–|]*chrome[^-–|]*\s*$/i, '')
    .trim();
  const fromSlug = decodeURIComponent(match[1])
    .replace(/-/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
  installViaduct(match[2], fromTitle || fromSlug, btn);
}, true);

// ---- In-place install progress card ---------------------------------------
// The Viaduct app runs the conversion hidden; we poll it (content -> background
// -> native handler -> app) and render a progress card IN PLACE of the install
// button. The store SPA can re-render the button node mid-install, so all state
// lives in `installState` and enableInstallButton() re-adopts any reset button.

let installState = null; // { path, title, sub, fraction, color }
let pollGen = 0; // bumping cancels any in-flight polling loop
// Original button markup, saved before we replace it with the progress card.
// Restoring innerHTML (not textContent) keeps Google's font-bearing spans, so
// the button doesn't fall back to a generic font after dismissal.
const origMarkup = new WeakMap();

function renderProgress(btn) {
  if (!installState) return;
  btn.dataset.vdProgress = '1';
  if (btn.hasAttribute('disabled')) btn.removeAttribute('disabled');
  // Let the button grow into a card: the store gives it a fixed pill height.
  btn.style.setProperty('background', '#0A1A1E', 'important');
  btn.style.setProperty('border-color', '#0A1A1E', 'important');
  btn.style.setProperty('height', 'auto', 'important');
  btn.style.setProperty('min-height', '0', 'important');
  btn.style.setProperty('max-width', 'none', 'important');
  btn.style.setProperty('border-radius', '14px', 'important');
  btn.style.setProperty('box-shadow', '0 8px 30px rgba(0,0,0,.35)', 'important');
  btn.style.pointerEvents = 'none';

  let box = btn.querySelector('.vd-box');
  if (!box) {
    if (!origMarkup.has(btn)) origMarkup.set(btn, btn.innerHTML);
    btn.textContent = '';
    box = document.createElement('span');
    box.className = 'vd-box';
    box.style.cssText =
      'display:flex;flex-direction:column;align-items:stretch;text-align:left;' +
      'width:340px;max-width:75vw;padding:14px 18px;' +
      'font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif';
    box.innerHTML =
      '<span style="display:flex;justify-content:space-between;align-items:baseline">' +
      '<span class="vd-title" style="color:#fff;font-weight:600;font-size:15px;line-height:1.3"></span>' +
      '<span class="vd-close" style="pointer-events:auto;cursor:pointer;' +
      'color:rgba(255,255,255,.6);font-size:13px;padding:0 2px">✕</span></span>' +
      '<span class="vd-sub" style="color:rgba(255,255,255,.65);font-size:13px;' +
      'line-height:1.35;display:block;margin:2px 0 10px;min-height:1em"></span>' +
      '<span style="background:rgba(255,255,255,.15);border-radius:99px;height:6px;' +
      'overflow:hidden;display:block">' +
      '<span class="vd-bar" style="background:#4A9DAD;height:100%;width:4%;display:block;' +
      'border-radius:99px;transition:width .6s ease"></span></span>';
    btn.appendChild(box);
    box.querySelector('.vd-close').addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      dismissProgress();
    });
  }
  box.querySelector('.vd-title').textContent = installState.title;
  const sub = box.querySelector('.vd-sub');
  sub.textContent = installState.sub || '';
  sub.title = installState.sub || '';
  const bar = box.querySelector('.vd-bar');
  bar.style.width = `${Math.round(installState.fraction * 100)}%`;
  bar.style.background = installState.color;
}

// Put the button back to its "Add to Safari" self (✕ clicked).
function dismissProgress() {
  stopProgressPolling();
  installState = null;
  document.querySelectorAll('[data-vd-progress]').forEach((btn) => {
    delete btn.dataset.vdProgress;
    btn.style.cssText = '';
    const saved = origMarkup.get(btn);
    if (saved != null) {
      // Google's own spans back in place — original font included. The saved
      // markup already reads "Add to Safari" (we relabel before any click).
      btn.innerHTML = saved;
      origMarkup.delete(btn);
    } else {
      // SPA replaced the node mid-install; no saved markup for this one.
      btn.textContent = 'Add to Safari';
    }
    if (btn.classList.contains('vd-install')) {
      // Our injected button has no store CSS classes — inline styles are all
      // it has, and the cssText reset above just wiped them.
      btn.style.cssText = VD_BTN_CSS;
      return;
    }
    btn.style.pointerEvents = 'auto';
    btn.style.setProperty('background', '#4A9DAD', 'important');
    btn.style.setProperty('color', '#0A1A1E', 'important');
    btn.style.setProperty('border-color', '#4A9DAD', 'important');
  });
  // Reconcile the just-restored button(s) with the current install state: after
  // an install/remove the desired label may be "Remove from Safari", not "Add".
  apply();
}

function setState(title, sub, fraction, color) {
  installState = { ...installState, title, sub, fraction, color };
  document.querySelectorAll('[data-vd-progress]').forEach(renderProgress);
  // Adopt any freshly re-rendered (unmarked) button too.
  enableInstallButton();
}

function stopProgressPolling() {
  pollGen++;
}

function startProgressPolling(btn, id) {
  const gen = ++pollGen;
  installState = { path: window.location.pathname, id };
  setState('Contacting Viaduct…', 'Launching the converter', 0.04, '#4A9DAD');
  if (btn) renderProgress(btn);
  const startedAt = Date.now();
  // Terminal states can be stale leftovers from a previous run (the app keeps
  // its last phase until the new install resets it), so ignore done/failed
  // until we've seen this run actually working.
  let sawActivity = false;
  let lastError = '';

  // Sequential loop, not setInterval: the native handler is spawned cold for
  // every poll and can take well over a second end to end. Overlapping ticks
  // with a tight race timeout read as "unreachable" even when the chain works.
  const tick = async () => {
    if (gen !== pollGen) return;
    let state = null;
    try {
      // Race a timeout: if anything along content -> background -> native ->
      // app stalls, sendMessage's promise may never settle, and an await with
      // no timeout would wedge the loop at "Contacting…" forever.
      const req = browser.runtime.sendMessage({ type: 'viaduct-progress' });
      req.catch(() => {});
      state = await Promise.race([
        req,
        new Promise(resolve => setTimeout(() => resolve(null), 2500)),
      ]);
    } catch (e) { /* background asleep; try next tick */ }
    if (gen !== pollGen) return;
    const s = state && state.state;
    if (state && state.error) lastError = state.error;
    const elapsed = Date.now() - startedAt;

    if (s === 'active') {
      sawActivity = true;
      setState(state.title || 'Converting…', state.subtitle || '',
               Math.max(0.04, state.fraction || 0), '#4A9DAD');
    } else if (s === 'done' && sawActivity) {
      if (id) installedById.set(id, true);
      setState('Installed ✓', 'Enable it in Safari → Settings → Extensions', 1, '#4A9DAD');
      // Let the success message land, then close the card on its own.
      setTimeout(() => { if (gen === pollGen) dismissProgress(); }, 2500);
      return;
    } else if (s === 'failed' && (sawActivity || elapsed > 10000)) {
      setState('Install failed', state.message || 'Open Viaduct for details.', 1, '#F87171');
      return;
    } else if (!sawActivity && elapsed > 30000) {
      setState('Install failed',
               lastError ? `Couldn't reach Viaduct: ${lastError}`
                         : "Couldn't reach Viaduct — open the app to see what happened.",
               1, '#F87171');
      return;
    } else if (elapsed > 20 * 60 * 1000) {
      setState('Still working…',
               'Taking unusually long — open Viaduct to check on it.', 1, '#FBBF24');
      return;
    }
    setTimeout(tick, 800);
  };
  tick();
}
