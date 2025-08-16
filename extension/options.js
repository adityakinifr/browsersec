// Saves options to chrome.storage
function saveOptions(e) {
  e.preventDefault();
  const options = {
    apiToken: document.getElementById('apiToken').value,
    domTracking: document.getElementById('domTracking').checked,
    screenCapture: document.getElementById('screenCapture').checked,
    interactionMonitoring: document.getElementById('interactionMonitoring').checked,
    retention: (() => {
      const val = parseInt(document.getElementById('retention').value, 10);
      return Number.isNaN(val) ? 30 : val;
    })()
  };
  chrome.storage.local.set(options, () => {
    const status = document.getElementById('status');
    status.textContent = 'Options saved.';
    setTimeout(() => status.textContent = '', 1500);
  });
}

// Restores select box and checkbox state using the preferences
// stored in chrome.storage.
function restoreOptions() {
  chrome.storage.local.get({
    apiToken: '',
    domTracking: true,
    screenCapture: true,
    interactionMonitoring: true,
    retention: 30
  }, (items) => {
    document.getElementById('apiToken').value = items.apiToken;
    document.getElementById('domTracking').checked = items.domTracking;
    document.getElementById('screenCapture').checked = items.screenCapture;
    document.getElementById('interactionMonitoring').checked = items.interactionMonitoring;
    document.getElementById('retention').value = items.retention;
  });
}

document.getElementById('settings-form').addEventListener('submit', saveOptions);
document.addEventListener('DOMContentLoaded', restoreOptions);

// Export functions for testing in Node environment
if (typeof module !== 'undefined') {
  module.exports = { saveOptions, restoreOptions };
}
