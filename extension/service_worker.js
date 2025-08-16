// Background service worker for BrowserSec
// Placeholder for continuous monitoring and intent classification

let debug = false;
function debugLog(level, ...args) {
  if (!debug) return;
  console[level]('Browsersec:', ...args);
}

chrome.storage.local.get({ debug: false }, items => {
  debug = items.debug;
  debugLog('log', 'service worker initialized');
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.debug) {
    debug = changes.debug.newValue;
    debugLog('log', `debug mode ${debug ? 'enabled' : 'disabled'}`);
  }
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get({
    domTracking: true,
    screenCapture: true,
    interactionMonitoring: true,
    retention: 30,
    screenshotInterval: 5,
    apiToken: '',
    debug: false
  }, (items) => {
    chrome.storage.local.set(items, () => {
      debugLog('log', 'installed with default settings');
    });
  });
});

let captureTimer;

async function captureAndSend(apiToken) {
  debugLog('debug', 'capturing screenshot');
  chrome.tabs.captureVisibleTab({ format: 'png' }, async (dataUrl) => {
    if (!dataUrl) {
      debugLog('debug', 'captureVisibleTab returned empty data');
      return;
    }
    try {
      const analysisPrompt = `Analyze the screenshot to determine the user's intent. Identify the type of application being used, the action the user appears to be taking, and any important contextual attributes. Respond in JSON with keys "appName", "actionName", and "miscNotes".`;

      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiToken}`
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          messages: [
            {
              role: 'user',
              content: [
                { type: 'text', text: analysisPrompt },
                { type: 'image_url', image_url: { url: dataUrl } }
              ]
            }
          ]
        })
      });
      const data = await response.json();
      const content = data?.choices?.[0]?.message?.content;
      try {
        const parsed = JSON.parse(content);
        debugLog('log', 'OpenAI intent analysis', parsed);
      } catch (parseErr) {
        debugLog('error', 'Failed to parse AI response', parseErr, content);
      }
    } catch (err) {
      debugLog('error', 'Failed to send screenshot to OpenAI', err);
    }
  });
}

function startScreenshotLoop() {
  if (captureTimer) clearInterval(captureTimer);
  chrome.storage.local.get({ apiToken: '', screenCapture: true, screenshotInterval: 5 }, (items) => {
    if (!items.screenCapture || !items.apiToken) return;
    debugLog('debug', `starting screenshot loop every ${items.screenshotInterval}s`);
    captureTimer = setInterval(() => captureAndSend(items.apiToken), items.screenshotInterval * 1000);
  });
}

startScreenshotLoop();

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && (changes.screenshotInterval || changes.apiToken || changes.screenCapture)) {
    debugLog('debug', 'screenshot loop settings changed');
    startScreenshotLoop();
  }
});

function triggerOnSetting(reason) {
  chrome.storage.local.get({ apiToken: '', screenCapture: true }, (items) => {
    if (!items.screenCapture || !items.apiToken) return;
    debugLog('debug', 'triggering capture', reason);
    captureAndSend(items.apiToken);
  });
}

chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'user-click') {
    debugLog('debug', 'received user-click message');
    triggerOnSetting('user-click');
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === 'complete') {
    debugLog('debug', 'tab updated');
    triggerOnSetting('tab-updated');
  }
});

chrome.tabs.onActivated.addListener(() => {
  debugLog('debug', 'tab activated');
  triggerOnSetting('tab-activated');
});

// TODO: Implement DOM state tracking, screen capture analysis,
// user interaction monitoring, and AI-powered intent classification.
