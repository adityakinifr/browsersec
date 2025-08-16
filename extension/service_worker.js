// Background service worker for BrowserSec
// Placeholder for continuous monitoring and intent classification

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get({
    domTracking: true,
    screenCapture: true,
    interactionMonitoring: true,
    retention: 30,
    screenshotInterval: 5,
    apiToken: ''
  }, (items) => {
    chrome.storage.local.set(items, () => {
      console.log('BrowserSec installed with default settings');
    });
  });
});

let captureTimer;

async function captureAndSend(apiToken) {
  chrome.tabs.captureVisibleTab({ format: 'png' }, async (dataUrl) => {
    if (!dataUrl) return;
    try {
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
                { type: 'text', text: 'Analyze this screenshot' },
                { type: 'image_url', image_url: { url: dataUrl } }
              ]
            }
          ]
        })
      });
      const data = await response.json();
      console.log('OpenAI response', data);
    } catch (err) {
      console.error('Failed to send screenshot to OpenAI', err);
    }
  });
}

function startScreenshotLoop() {
  if (captureTimer) clearInterval(captureTimer);
  chrome.storage.local.get({ apiToken: '', screenCapture: true, screenshotInterval: 5 }, (items) => {
    if (!items.screenCapture || !items.apiToken) return;
    captureTimer = setInterval(() => captureAndSend(items.apiToken), items.screenshotInterval * 1000);
  });
}

startScreenshotLoop();

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && (changes.screenshotInterval || changes.apiToken || changes.screenCapture)) {
    startScreenshotLoop();
  }
});

function triggerOnSetting() {
  chrome.storage.local.get({ apiToken: '', screenCapture: true }, (items) => {
    if (!items.screenCapture || !items.apiToken) return;
    captureAndSend(items.apiToken);
  });
}

chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'user-click') {
    triggerOnSetting();
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === 'complete') {
    triggerOnSetting();
  }
});

chrome.tabs.onActivated.addListener(() => {
  triggerOnSetting();
});

// TODO: Implement DOM state tracking, screen capture analysis,
// user interaction monitoring, and AI-powered intent classification.
