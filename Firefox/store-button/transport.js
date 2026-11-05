// How the store page talks to the Viaduct app from Firefox. content.js is
// shared with the Safari extension and knows nothing about the browser it runs
// in; everything browser-specific lives here, loaded just before it.
//
// Every request goes content -> background -> ViaductHelper (Firefox's native
// messaging host) -> app. Installs and removals don't wait for an answer: the
// page follows them by polling progress and installed-state like Safari does.
var viaductTransport = {
  browser: 'Firefox',

  install(id, name) {
    browser.runtime.sendMessage({ type: 'viaduct-open', action: 'install', id, name }).catch(() => {});
  },

  remove(id) {
    browser.runtime.sendMessage({ type: 'viaduct-open', action: 'remove', id }).catch(() => {});
  },

  progress() {
    return browser.runtime.sendMessage({ type: 'viaduct-progress' });
  },

  installed(id) {
    return browser.runtime.sendMessage({ type: 'viaduct-installed', id });
  },

  // A pending add-on is in the profile but only loads the next time Firefox
  // starts.
  doneMessage(state) {
    return state && state.pending ? 'It arrives the next time you open Firefox' : 'Ready to use in Firefox';
  },

  removingMessage: 'Removing it and its data',
  removedMessage: 'Gone from Firefox',
  // Persist clears the add-on's data through Firefox, which takes longer than
  // deleting a Safari app.
  removeTimeoutMs: 30000,
};
