// Heartbeat: Safari only starts this worker while the extension is enabled,
// so one hello per start tells the Viaduct app to stop pointing the user at
// a switch they already flipped. Failure means the app isn't running — fine.
browser.runtime
  .sendNativeMessage('com.magicelk235.viaduct.Extension', { type: 'hello' })
  .catch(() => {});

// Relay: content scripts can't call sendNativeMessage in Safari, so progress
// polls route through here to the native SafariWebExtensionHandler.
// sendResponse + `return true` (not a returned Promise) — Safari resolves the
// content script's sendMessage() only via sendResponse; a returned Promise can
// leave the caller's await hanging forever.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === 'viaduct-progress') {
    browser.runtime
      .sendNativeMessage('com.magicelk235.viaduct.Extension', { type: 'progress' })
      .then(sendResponse,
            // Pass the real failure through — the page shows it after repeated
            // misses, which beats debugging a generic "couldn't reach".
            (e) => sendResponse({ state: 'unreachable', error: String((e && e.message) || e) }));
    return true;
  }
  if (message && message.type === 'viaduct-installed') {
    browser.runtime
      .sendNativeMessage('com.magicelk235.viaduct.Extension', { type: 'installed', id: message.id })
      .then(sendResponse,
            (e) => sendResponse({ installed: false, error: String((e && e.message) || e) }));
    return true;
  }
});
