// Content script placeholder for BrowserSec
// Interacts with the DOM and forwards relevant data to the background worker.

let debug = false;
function debugLog(level, ...args) {
  if (!debug) return;
  console[level]('Browsersec:', ...args);
}

chrome.storage.local.get({ debug: false }, items => {
  debug = items.debug;
  debugLog('log', 'content script loaded');
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.debug) {
    debug = changes.debug.newValue;
    debugLog('log', `debug mode ${debug ? 'enabled' : 'disabled'}`);
  }
});

// Send a message to the background script whenever the user clicks on the page
// Guard against "Extension context invalidated" errors by gracefully handling
// messaging failures (e.g. when the extension is reloaded while the content
// script remains attached to the page).
document.addEventListener('click', () => {
  try {
    debugLog('debug', 'sending user-click message');
    chrome.runtime.sendMessage({ type: 'user-click' }, () => {
      // Accessing lastError prevents unchecked runtime errors that manifest
      // as "Extension context invalidated" in some environments.
      if (chrome.runtime.lastError) {
        debugLog('debug', 'message failed', chrome.runtime.lastError);
      } else {
        debugLog('debug', 'user-click message sent');
      }
    });
  } catch (err) {
    // In rare cases chrome.runtime may itself be unavailable; ignore silently.
    debugLog('debug', 'unable to send message', err);
  }
});

// Notify the background script whenever the user types.
// Each key press resets a short timer in the service worker, ensuring
// that a screenshot is captured only after typing has paused.
document.addEventListener('keydown', () => {
  try {
    debugLog('debug', 'sending user-typing message');
    chrome.runtime.sendMessage({ type: 'user-typing' }, () => {
      if (chrome.runtime.lastError) {
        debugLog('debug', 'message failed', chrome.runtime.lastError);
      } else {
        debugLog('debug', 'user-typing message sent');
      }
    });
  } catch (err) {
    debugLog('debug', 'unable to send message', err);
  }
});

// TODO: Monitor DOM changes and additional user interactions.
