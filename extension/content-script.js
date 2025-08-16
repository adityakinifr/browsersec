// Content script placeholder for BrowserSec
// Interacts with the DOM and forwards relevant data to the background worker.

console.log('BrowserSec content script loaded');

// Send a message to the background script whenever the user clicks on the page
document.addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'user-click' });
});

// TODO: Monitor DOM changes and additional user interactions.
