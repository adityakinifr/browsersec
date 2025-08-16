const test = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

// Set up DOM environment expected by options.js
const dom = new JSDOM(`<!DOCTYPE html><form id="settings-form">
  <input id="apiToken">
  <input id="domTracking" type="checkbox">
  <input id="screenCapture" type="checkbox">
  <input id="interactionMonitoring" type="checkbox">
  <input id="retention">
  <div id="status"></div>
</form>`);

global.window = dom.window;
global.document = dom.window.document;

let stored = {};
global.chrome = {
  storage: {
    local: {
      set: (opts, cb) => { stored = opts; cb && cb(); },
      get: (defaults, cb) => { cb({ ...defaults, ...stored }); }
    }
  }
};

const { saveOptions, restoreOptions } = require('../extension/options.js');

test('saveOptions stores settings to chrome.storage', () => {
  document.getElementById('apiToken').value = 'token123';
  document.getElementById('domTracking').checked = true;
  document.getElementById('screenCapture').checked = false;
  document.getElementById('interactionMonitoring').checked = true;
  document.getElementById('retention').value = '45';

  saveOptions({ preventDefault() {} });

  assert.deepEqual(stored, {
    apiToken: 'token123',
    domTracking: true,
    screenCapture: false,
    interactionMonitoring: true,
    retention: 45
  });
});

test('restoreOptions populates form from chrome.storage', () => {
  stored = {
    apiToken: 'saved',
    domTracking: false,
    screenCapture: true,
    interactionMonitoring: false,
    retention: 10
  };

  restoreOptions();

  assert.equal(document.getElementById('apiToken').value, 'saved');
  assert.equal(document.getElementById('domTracking').checked, false);
  assert.equal(document.getElementById('screenCapture').checked, true);
  assert.equal(document.getElementById('interactionMonitoring').checked, false);
  assert.equal(document.getElementById('retention').value, '10');
});
