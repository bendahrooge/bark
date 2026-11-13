#ifndef BARK_SPACES_UI_SPACES_UI_H_
#define BARK_SPACES_UI_SPACES_UI_H_

#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/webui_config.h"
#include "content/public/common/url_constants.h"

namespace bark {
inline constexpr char kSpacesHost[] = "spaces";

class SpacesUI;

// chrome://spaces: manage Bark's spaces and the profiles they open in.
class SpacesUIConfig : public content::DefaultWebUIConfig<SpacesUI> {
 public:
  SpacesUIConfig() : DefaultWebUIConfig(content::kChromeUIScheme, kSpacesHost) {}
};

class SpacesUI : public content::WebUIController {
 public:
  explicit SpacesUI(content::WebUI* web_ui);
  SpacesUI(const SpacesUI&) = delete;
  SpacesUI& operator=(const SpacesUI&) = delete;
  ~SpacesUI() override;
};
}  // namespace bark

#endif  // BARK_SPACES_UI_SPACES_UI_H_
