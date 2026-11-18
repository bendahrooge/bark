#ifndef BARK_LAZY_TAB_H_
#define BARK_LAZY_TAB_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace bark {
// Keep the destination in the navigation history without starting a renderer
// or requesting the page. Chromium loads the restored entry when shown.
inline std::unique_ptr<content::WebContents> CreateLazyTab(
    content::BrowserContext* context, const GURL& url,
    const std::u16string& title = {}) {
  content::WebContents::CreateParams params(context);
  params.initially_hidden = true;
  params.desired_renderer_state = content::WebContents::CreateParams::kNoRendererProcess;
  auto contents = content::WebContents::Create(params);
  std::vector<std::unique_ptr<content::NavigationEntry>> entries;
  auto entry = content::NavigationController::CreateNavigationEntry(
      url, content::Referrer(), std::nullopt, std::nullopt,
      ui::PAGE_TRANSITION_AUTO_TOPLEVEL, false, std::string(), context, nullptr);
  entry->SetTitle(title);
  entries.push_back(std::move(entry));
  contents->GetController().Restore(0, content::RestoreType::kRestored, &entries);
  return contents;
}
}  // namespace bark
#endif
