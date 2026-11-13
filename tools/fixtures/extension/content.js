if (location.pathname === "/extensions") {
  (async () => {
    try {
      const reply = await chrome.runtime.sendMessage({type: "probe"});
      const blocked = await fetch("/extension-blocked").then(() => false, () => true);
      const allowed = await fetch("/extension-allowed").then(r => r.ok);
      document.title = `EXT:${reply.visits}:${blocked && allowed ? "filtered" : "unfiltered"}:${reply.tab ? "tab" : "no-tab"}`;
      document.body.textContent = document.title;
    } catch (error) { document.title = "EXT-ERROR:" + error.message; }
  })();
}
if (location.pathname === "/extension-action") chrome.runtime.sendMessage({type: "action"});
