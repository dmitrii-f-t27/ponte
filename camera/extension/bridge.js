// Ponte Camera, bridge (the extension's own world in a Meet page): hands the shader's numbers and the pipeline's
// tables from chrome.storage to page.js, and the page's report to the service worker. Nothing is decided here; the
// report's texts are only bounded in size for the trip (the service worker cleans them with the spec's rule).
// The service worker counts this page while its report's lease lasts (camera_rules.t27, cm_page_lease_left_ms): the
// last report is sent again every CM_PAGE_REPORT_MS, and pagehide says the page is gone (a reload, a navigation).
(() => {
  const TAG = '__ponteCamera';
  const STORE = 'ponteCamera';
  const REPORT_MS = 20000;   // CM_PAGE_REPORT_MS

  const post = (state) => {
    const ok = state && Array.isArray(state.params) && Array.isArray(state.crop);
    const p = ok ? { needs: !!state.needs, colorIdentity: !!state.colorIdentity, m: state.params, crop: state.crop } : null;
    const policy = ok && state.policy && typeof state.policy === 'object' ? state.policy : null;
    window.postMessage({ [TAG]: 'params', p, policy }, '*');
  };
  const load = () => chrome.storage.local.get(STORE).then((r) => post(r[STORE])).catch(() => {});

  // The page's last report; sending fails once the extension was reloaded or updated (this script is then orphaned).
  let last = { type: 'status', processed: 0, passing: 0, troubled: 0, error: null };
  const send = (message) => {
    try { chrome.runtime.sendMessage(message).catch(() => {}); } catch {}
  };

  load();
  // A Meet page is open (no camera yet): the service worker counts it and dials Ponte if it may.
  send(last);
  setInterval(() => send(last), REPORT_MS);
  // Leaving (a navigation, a reload, a tab put in the back/forward cache) and coming back.
  window.addEventListener('pagehide', () => send({ type: 'status', gone: true }));
  window.addEventListener('pageshow', (event) => { if (event.persisted) send(last); });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[STORE]) post(changes[STORE].newValue);
  });
  const count = (n) => (Number.isFinite(n) ? Math.trunc(n) : 0);
  const text = (t, n) => String(t ?? '').slice(0, n);
  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data) return;
    const kind = event.data[TAG];
    if (kind === 'ready') load();
    if (kind === 'status') {
      const e = event.data.error;
      last = {
        type: 'status', processed: count(event.data.processed), passing: count(event.data.passing),
        troubled: count(event.data.troubled),
        error: e && typeof e === 'object'
          ? { stage: count(e.stage), renderer: count(e.renderer), name: text(e.name, 256), message: text(e.message, 256) }
          : null,
      };
      send(last);
    }
  });
})();
