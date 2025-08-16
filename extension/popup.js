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
  const counts = {};
  activities.forEach(({ actionType }) => {
    counts[actionType] = (counts[actionType] || 0) + 1;
  });
  const rows = Object.entries(counts)
    .filter(([, count]) => count <= 2)
    .sort((a, b) => a[1] - b[1]);
  const tbody = document.querySelector('#rareTable tbody');
  tbody.innerHTML = '';
  rows.forEach(([actionType, count]) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${actionType}</td><td>${count}</td>`;
    tbody.appendChild(tr);
  });
}

function renderDashboard() {
  chrome.storage.local.get({ activities: [] }, ({ activities }) => {
    renderSiteTable(activities);
    renderSensitiveTable(activities);
    renderRareTable(activities);
  });
}

if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', renderDashboard);
}

// Export for testing if needed
if (typeof module !== 'undefined') {
  module.exports = { renderSiteTable, renderSensitiveTable, renderRareTable };
}
