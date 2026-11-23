#ifndef BARK_MAC_SIDEBAR_MAC_H_
#define BARK_MAC_SIDEBAR_MAC_H_

#include <memory>

class GURL;
class Profile;
class BrowserView;
class BrowserWindowInterface;
namespace content { class WebContents; }
namespace views { class View; }

namespace bark {
// Owns the observation/command bridge; Chromium continues to own every browser,
// profile, tab, permission prompt, and extension service.
class SidebarMac {
 public:
  static bool OpenStandaloneLittleWindow(Profile* profile, const GURL& url);
  static bool IsEnabled(BrowserWindowInterface* browser);
  static bool IsPeek(const BrowserView* view);
  // Called for each page added to a popup window, including restored ones.
  static void AttachLittleWindow(BrowserWindowInterface* browser, content::WebContents* page);
  static views::View* LittleToolbarAnchor(const BrowserView* view, bool extensions);
  explicit SidebarMac(BrowserView* view);
  ~SidebarMac();
  SidebarMac(const SidebarMac&) = delete;
  SidebarMac& operator=(const SidebarMac&) = delete;
  // A collapsed sidebar can still be revealed. Content fullscreen and kiosk
  // fullscreen reserve the entire window for the page.
  bool CanShow() const;
  int width() const;
  void Layout();
  void FocusAddress();
  views::View* bubble_anchor(bool extensions) const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace bark

#endif  // BARK_MAC_SIDEBAR_MAC_H_
