#ifndef BARK_BROWSER_HOOKS_H_
#define BARK_BROWSER_HOOKS_H_

#include <vector>

class GURL;
class BrowserWindowInterface;
struct NavigateParams;
namespace content { class NavigationThrottleRegistry; }

namespace bark {
// The native sidebar registers these at startup. Chromium calls them without
// depending on the sidebar, as with pinned_tab_close.h.

// Lets a Bark window present the New Tab command before a destination exists.
using NewTabComposerHook = bool (*)(BrowserWindowInterface*);
inline NewTabComposerHook& NewTabComposer() {
  static NewTabComposerHook hook = nullptr;
  return hook;
}
inline bool ShowNewTabComposer(BrowserWindowInterface* browser) {
  return NewTabComposer() && NewTabComposer()(browser);
}

// Presents Bark's native settings; false keeps Chromium's normal route.
using PreferencesHook = bool (*)(BrowserWindowInterface*);
inline PreferencesHook& PreferencesPresenter() {
  static PreferencesHook hook = nullptr;
  return hook;
}
inline bool ShowPreferences(BrowserWindowInterface* browser) {
  return PreferencesPresenter() && PreferencesPresenter()(browser);
}

// Adds Bark's navigation throttles, such as Peek for links in pinned tabs.
using NavigationThrottleHook = void (*)(content::NavigationThrottleRegistry&);
inline NavigationThrottleHook& NavigationThrottles() {
  static NavigationThrottleHook hook = nullptr;
  return hook;
}
inline void AddNavigationThrottles(content::NavigationThrottleRegistry& registry) {
  if (NavigationThrottles()) NavigationThrottles()(registry);
}

// Places a newly created web browsing context in Peek. A handled request
// returns the original NavigateParams with its normal navigation result.
using NewContentsPeekHook = bool (*)(NavigateParams&);
inline NewContentsPeekHook& NewContentsPeek() {
  static NewContentsPeekHook hook = nullptr;
  return hook;
}
inline bool ShowNewContentsInPeek(NavigateParams& params) {
  return NewContentsPeek() && NewContentsPeek()(params);
}

// Links another app asked Bark to open. Returns true when Bark showed them
// itself (in a Little window); otherwise Chromium opens them as tabs.
using ExternalLinksHook = bool (*)(const std::vector<GURL>&);
inline ExternalLinksHook& ExternalLinks() {
  static ExternalLinksHook hook = nullptr;
  return hook;
}
inline bool OpenExternalLinks(const std::vector<GURL>& urls) {
  return ExternalLinks() && ExternalLinks()(urls);
}

// Chromium has selected the tabbed window that will receive an external URL.
using ExternalTabDestinationHook = void (*)(BrowserWindowInterface*);
inline ExternalTabDestinationHook& ExternalTabDestination() {
  static ExternalTabDestinationHook hook = nullptr;
  return hook;
}
}  // namespace bark
#endif
