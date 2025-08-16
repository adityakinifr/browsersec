const test = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

const { renderSiteTable, renderSensitiveTable, renderRareTable } = require('../extension/popup.js');

test('renderSiteTable groups by host and action type', () => {
  const dom = new JSDOM('<table id="siteTable"><tbody></tbody></table>');
  global.document = dom.window.document;
  renderSiteTable([
    { url: 'https://example.com', actionType: 'READ' },
    { url: 'https://example.com', actionType: 'READ' },
    { url: 'https://example.com', actionType: 'BROWSE' },
    { url: 'https://other.com', actionType: 'READ' }
  ]);
  const rows = dom.window.document.querySelectorAll('tbody tr');
  assert.equal(rows.length, 3);
});

test('renderSensitiveTable shows only sensitive actions', () => {
  const dom = new JSDOM('<table id="sensitiveTable"><tbody></tbody></table>');
  global.document = dom.window.document;
  renderSensitiveTable([
    { actionName: 'change password', actionType: 'SETTINGS-CHANGE', url: 'https://ex.com' },
    { actionName: 'view', actionType: 'READ', url: 'https://ex.com' }
  ]);
  const rows = dom.window.document.querySelectorAll('tbody tr');
  assert.equal(rows.length, 1);
});

test('renderRareTable lists low prevalence actions', () => {
  const dom = new JSDOM('<table id="rareTable"><tbody></tbody></table>');
  global.document = dom.window.document;
  renderRareTable([
    { actionType: 'READ' },
    { actionType: 'READ' },
    { actionType: 'BROWSE' },
    { actionType: 'SETTINGS-CHANGE' }
  ]);
  const rows = dom.window.document.querySelectorAll('tbody tr');
  assert.equal(rows.length, 3);
});
