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

async function captureAndSend(apiToken) {
  debugLog('debug', 'capturing screenshot');
  chrome.tabs.captureVisibleTab({ format: 'png' }, async (dataUrl) => {
    if (!dataUrl) {
      debugLog('debug', 'captureVisibleTab returned empty data');
      return;
    }
    try {
      const analysisPrompt = `Analyze the screenshot to determine the user's intent. Identify the type of application being used, the action the user appears to be taking, and any important contextual attributes. Categorize the user's action into one of the following: READ (the user is exploring without making changes), BROWSE (the user navigates to a new portion of the site or a new site altogether), SETTINGS-CHANGE (the user changes a setting), or EMAIL-SENSITIVE-SEND (the user sends an API token or other sensitive information). Respond with a valid JSON object containing the keys "appName", "actionName", "miscNotes", and "actionType". Return only the JSON object with no extra text or code fences.`;

      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiToken}`
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini',
          response_format: { type: 'json_object' },
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

let typingTimer;

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
  } else if (msg.type === 'user-typing') {
    debugLog('debug', 'received user-typing message');
    if (typingTimer) clearTimeout(typingTimer);
    typingTimer = setTimeout(() => {
      triggerOnSetting('user-typing');
      typingTimer = null;
    }, 3000);
  }
});

// TODO: Implement DOM state tracking, screen capture analysis,
// user interaction monitoring, and AI-powered intent classification.
