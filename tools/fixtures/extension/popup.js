(async () => {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  await chrome.scripting.executeScript({target: {tabId: tab.id}, func: () => { document.title = "Extension action passed"; }});
  document.body.textContent = "Extension action passed";
  await chrome.storage.local.set({actionPassed: true});
})().catch(error => { document.body.textContent = error.message; });
