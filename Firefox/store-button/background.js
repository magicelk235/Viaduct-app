// Relay: content scripts can't call sendNativeMessage, so every request from
// the store page comes through here to ViaductHelper, which Firefox starts as
// this add-on's native messaging host.
//
// No heartbeat and no onInstalled page: Firefox reloads a temporary add-on at
// every start and reports each load as a fresh install.
const HOST = 'com.magicelk235.viaduct';

function hostRequest(message) {
  switch (message && message.type) {
    case 'viaduct-progress':
      return { type: 'progress' };
    case 'viaduct-installed':
      return { type: 'installed', id: message.id };
    case 'viaduct-open':
      return { type: message.action, id: message.id, name: message.name };
    default:
      return null;
  }
}

// sendResponse + `return true` rather than a returned Promise, matching the
// Safari extension, so both browsers answer the page the same way.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const request = hostRequest(message);
  if (!request) return;
  browser.runtime
    .sendNativeMessage(HOST, request)
    .then(sendResponse,
          // Pass the real failure through; the page shows it after repeated misses.
          (e) => sendResponse({ state: 'unreachable', installed: false, error: String((e && e.message) || e) }));
  return true;
});
