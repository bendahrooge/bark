#ifndef BARK_MAC_SIDEBAR_MAC_H_
#define BARK_MAC_SIDEBAR_MAC_H_

#include <memory>

class BrowserView;
class BrowserWindowInterface;
namespace views { class View; }

namespace bark {
// Owns the observation/command bridge; Chromium continues to own every browser,
// profile, tab, permission prompt, and extension service.
class SidebarMac {
 public:
  static bool IsEnabled(BrowserWindowInterface* browser);
  explicit SidebarMac(BrowserView* view);
  ~SidebarMac();
  SidebarMac(const SidebarMac&) = delete;
  SidebarMac& operator=(const SidebarMac&) = delete;
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
