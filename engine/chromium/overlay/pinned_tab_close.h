#ifndef BARK_PINNED_TAB_CLOSE_H_
#define BARK_PINNED_TAB_CLOSE_H_

class BrowserWindowInterface;
namespace content { class WebContents; }

namespace bark {
enum class PinnedTabCloseAction { kRequest, kConfirm, kCancel };
using PinnedTabCloseHandler = bool (*)(BrowserWindowInterface*, content::WebContents*, PinnedTabCloseAction);

// The native sidebar registers the implementation without introducing a
// dependency cycle between Chromium's browser commands and Bark's sidebar.
inline PinnedTabCloseHandler& PinnedTabCloser() {
  static PinnedTabCloseHandler handler = nullptr;
  return handler;
}
inline bool HandlePinnedTabClose(BrowserWindowInterface* browser,
                                content::WebContents* contents,
                                PinnedTabCloseAction action = PinnedTabCloseAction::kRequest) {
  return PinnedTabCloser() && PinnedTabCloser()(browser, contents, action);
}
}  // namespace bark
#endif
