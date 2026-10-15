// Ponte Camera, bridge (the extension's own world in a Meet page): hands the shader's numbers from chrome.storage
// to page.js and the page's camera count to the service worker. Nothing is decided here.
(() => {
  const TAG = '__ponteCamera';
  const STORE = 'ponteCamera';

  const post = (state) => {
    const p = state && Array.isArray(state.params) && Array.isArray(state.crop)
      ? { needs: !!state.needs, m: state.params, crop: state.crop } : null;
    window.postMessage({ [TAG]: 'params', p }, '*');
  };
  const load = () => chrome.storage.local.get(STORE).then((r) => post(r[STORE])).catch(() => {});

  load();
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[STORE]) post(changes[STORE].newValue);
  });
  window.addEventListener('message', (event) => {
    if (event.source !== window || !event.data) return;
    const kind = event.data[TAG];
    if (kind === 'ready') load();
    if (kind === 'status') {
      chrome.runtime.sendMessage({ type: 'status', cameras: event.data.cameras | 0 }).catch(() => {});
    }
  });
})();
