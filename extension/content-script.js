// Content script placeholder for BrowserSec
// Interacts with the DOM and forwards relevant data to the background worker.

console.log('BrowserSec content script loaded');

// Send a message to the background script whenever the user clicks on the page
// Guard against "Extension context invalidated" errors by gracefully handling
// messaging failures (e.g. when the extension is reloaded while the content
// script remains attached to the page).
document.addEventListener('click', () => {
  try {
    chrome.runtime.sendMessage({ type: 'user-click' }, () => {
      // Accessing lastError prevents unchecked runtime errors that manifest
      // as "Extension context invalidated" in some environments.
      if (chrome.runtime.lastError) {
        console.debug('BrowserSec: message failed', chrome.runtime.lastError);
      }
    });
  } catch (err) {
    // In rare cases chrome.runtime may itself be unavailable; ignore silently.
    console.debug('BrowserSec: unable to send message', err);
  }
});

// TODO: Monitor DOM changes and additional user interactions.
