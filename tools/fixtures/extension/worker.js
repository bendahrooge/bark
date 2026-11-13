chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message.type === "action") { chrome.action.openPopup().catch(error => console.error(error)); return; }
  if (message.type !== "probe") return;
  (async () => {
    const {visits = 0} = await chrome.storage.local.get("visits");
    await chrome.storage.local.set({visits: visits + 1});
    const tab = await chrome.tabs.get(sender.tab.id);
    respond({visits: visits + 1, tab: tab.id === sender.tab.id});
  })().catch(error => respond({error: error.message}));
  return true;
});
