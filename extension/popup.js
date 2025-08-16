function renderSiteTable(activities) {
  const counts = {};
  activities.forEach(({ url, actionType }) => {
    if (!url) return;
    let host;
    try { host = new URL(url).hostname; } catch { return; }
    const key = `${host}|${actionType}`;
    counts[key] = (counts[key] || 0) + 1;
  });
  const rows = Object.entries(counts)
    .map(([key, count]) => {
      const [host, actionType] = key.split('|');
      return { host, actionType, count };
    })
    .sort((a, b) => b.count - a.count)
    .slice(0, 10);
  const tbody = document.querySelector('#siteTable tbody');
  tbody.innerHTML = '';
  rows.forEach(({ host, actionType, count }) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${host}</td><td>${actionType}</td><td>${count}</td>`;
    tbody.appendChild(tr);
  });
}

function renderSensitiveTable(activities) {
  const sensitive = new Set(['SETTINGS-CHANGE', 'EMAIL-SENSITIVE-SEND']);
  const counts = {};
  activities
    .filter(a => sensitive.has(a.actionType))
    .forEach(({ actionName, url }) => {
      let host;
      try { host = new URL(url).hostname; } catch { host = url; }
      const key = `${actionName}|${host}`;
      counts[key] = (counts[key] || 0) + 1;
    });
  const rows = Object.entries(counts)
    .map(([key, count]) => {
      const [actionName, host] = key.split('|');
      return { actionName, host, count };
    })
    .sort((a, b) => b.count - a.count);
  const tbody = document.querySelector('#sensitiveTable tbody');
  tbody.innerHTML = '';
  rows.forEach(({ actionName, host, count }) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${actionName}</td><td>${host}</td><td>${count}</td>`;
    tbody.appendChild(tr);
  });
}

function renderRareTable(activities) {
  const stats = {};
  activities.forEach(({ actionType, riskScore }) => {
    if (!stats[actionType]) stats[actionType] = { count: 0, risk: 0 };
    stats[actionType].count += 1;
    stats[actionType].risk += riskScore || 0;
  });
  const rows = Object.entries(stats)
    .filter(([, { count }]) => count <= 2)
    .map(([actionType, { count, risk }]) => ({ actionType, count, avgRisk: (risk / count).toFixed(2) }))
    .sort((a, b) => a.count - b.count);
  const tbody = document.querySelector('#rareTable tbody');
  tbody.innerHTML = '';
  rows.forEach(({ actionType, count, avgRisk }) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${actionType}</td><td>${count}</td><td>${avgRisk}</td>`;
    tbody.appendChild(tr);
  });
}

function renderRiskTable(activities) {
  const stats = {};
  activities.forEach(({ url, riskScore }) => {
    if (!url) return;
    let host;
    try { host = new URL(url).hostname; } catch { return; }
    if (!stats[host]) stats[host] = { count: 0, risk: 0 };
    stats[host].count += 1;
    stats[host].risk += riskScore || 0;
  });
  const rows = Object.entries(stats)
    .map(([host, { count, risk }]) => ({ host, count, avgRisk: (risk / count).toFixed(2) }))
    .sort((a, b) => b.avgRisk - a.avgRisk)
    .slice(0, 10);
  const tbody = document.querySelector('#riskTable tbody');
  tbody.innerHTML = '';
  rows.forEach(({ host, avgRisk, count }) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${host}</td><td>${avgRisk}</td><td>${count}</td>`;
    tbody.appendChild(tr);
  });
}

function populateSiteSelect(activities) {
  const select = document.getElementById('siteSelect');
  if (!select) return;
  const hosts = Array.from(new Set(activities.map(a => {
    try { return new URL(a.url).hostname; } catch { return null; }
  }).filter(Boolean))).sort();
  select.innerHTML = hosts.map(h => `<option value="${h}">${h}</option>`).join('');
}

function analyzeWebsite(site, activities, apiToken) {
  const siteActivities = activities.filter(a => {
    try { return new URL(a.url).hostname === site; } catch { return false; }
  });
  if (siteActivities.length === 0 || !apiToken) return;

  const prompt = `You are a security analyst. Review the following user interactions on ${site}. Consider prevalence of actions and common risky patterns such as phishing or insider threat. Summarize any risky behavior and explain why. Return JSON {analysis: [{action, reason}]}.`;

  return fetch('https://api.openai.com/v1/chat/completions', {
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
            { type: 'text', text: prompt },
            { type: 'text', text: JSON.stringify(siteActivities) }
          ]
        }
      ]
    })
  }).then(r => r.json()).then(data => {
    const content = data?.choices?.[0]?.message?.content;
    let parsed;
    try { parsed = JSON.parse(content); } catch { parsed = { analysis: [] }; }
    const tbody = document.querySelector('#analysisTable tbody');
    if (!tbody) return;
    tbody.innerHTML = '';
    (parsed.analysis || []).forEach(({ action, reason }) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${action}</td><td>${reason}</td>`;
      tbody.appendChild(tr);
    });
  }).catch(() => {});
}

function renderDashboard() {
  chrome.storage.local.get({ activities: [], apiToken: '' }, ({ activities, apiToken }) => {
    renderSiteTable(activities);
    renderRiskTable(activities);
    renderSensitiveTable(activities);
    renderRareTable(activities);
    populateSiteSelect(activities);
    const btn = document.getElementById('analyzeBtn');
    if (btn) {
      btn.onclick = () => {
        const site = document.getElementById('siteSelect').value;
        analyzeWebsite(site, activities, apiToken);
      };
    }
  });
}

if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', renderDashboard);
}

// Export for testing if needed
if (typeof module !== 'undefined') {
  module.exports = { renderSiteTable, renderSensitiveTable, renderRareTable, renderRiskTable };
}
