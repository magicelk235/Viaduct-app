// How the store page talks to the Viaduct app from Safari. content.js is
// shared with the Firefox add-on and knows nothing about the browser it runs
// in; everything browser-specific lives here, loaded just before it.
//
// Installs and removals open a viaduct:// link, which macOS hands to the app.
// Progress and installed-state queries go content -> background -> native
// handler -> app (content scripts can't message the native side in Safari).
var viaductTransport = {
  browser: 'Safari',

  install(id, name) {
    let url = `viaduct://install?id=${id}`;
    if (name) url += `&name=${encodeURIComponent(name)}`;
    window.location.href = url;
  },

  remove(id) {
    window.location.href = `viaduct://remove?id=${id}`;
  },

  progress() {
    return browser.runtime.sendMessage({ type: 'viaduct-progress' });
  },

  installed(id) {
    return browser.runtime.sendMessage({ type: 'viaduct-installed', id });
  },

  doneMessage(state) {
    return 'Enable it in Safari → Settings → Extensions';
  },

  removingMessage: 'Deleting the Safari app',
  removedMessage: 'Gone from Safari',
  removeTimeoutMs: 15000,
};
