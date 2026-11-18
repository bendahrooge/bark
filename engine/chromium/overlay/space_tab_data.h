#ifndef BARK_SPACE_TAB_DATA_H_
#define BARK_SPACE_TAB_DATA_H_

#include <memory>
#include <string>
#include "base/supports_user_data.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"

namespace bark {
inline constexpr char kTabSpaceKey[] = "bark.space_id";
inline constexpr char kTabWindowGroupKey[] = "bark.window_group";
// Bark's own per-tab state, as a JSON object saved with the session: a
// custom title, the URL a pinned tab returns to, its sidebar folder, and when
// it was last shown (for automatic archiving).
inline constexpr char kTabMetaKey[] = "bark.tab_meta";
// Favorites appear in every space of their profile's window. Their shared
// space ID is distinct from the UUIDs used by the space catalog.
inline constexpr char kFavoritesSpace[] = "bark.favorites";
class SpaceTabData : public base::SupportsUserData::Data {
 public:
  explicit SpaceTabData(std::string value) : id(std::move(value)) {}
  std::string id;
  std::string window_group;
  bool restored_group = false;
};
inline std::string GetTabSpace(content::WebContents* contents) {
  if (!contents) return {};
  auto* data = static_cast<SpaceTabData*>(contents->GetUserData(kTabSpaceKey));
  return data ? data->id : std::string();
}
// Membership stays with the real WebContents, including tab moves and restore.
// Private tabs never acquire persistent space metadata.
inline void SetTabSpace(content::WebContents* contents, const std::string& id) {
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord() ||
      id.empty() || id.size() > 80) return;
  if (auto* data = static_cast<SpaceTabData*>(contents->GetUserData(kTabSpaceKey))) data->id = id;
  else contents->SetUserData(kTabSpaceKey, std::make_unique<SpaceTabData>(id));
}
inline std::string GetTabWindowGroup(content::WebContents* contents) {
  auto* data = static_cast<SpaceTabData*>(contents->GetUserData(kTabSpaceKey));
  return data ? data->window_group : std::string();
}
inline void SetTabWindowGroup(content::WebContents* contents, const std::string& id, bool restored = false) {
  auto* data = static_cast<SpaceTabData*>(contents->GetUserData(kTabSpaceKey));
  if (data && id.size() <= 80) { data->window_group = id; data->restored_group = restored; }
}
inline std::string TakeRestoredWindowGroup(content::WebContents* contents) {
  auto* data = static_cast<SpaceTabData*>(contents->GetUserData(kTabSpaceKey));
  if (!data || !data->restored_group) return {};
  data->restored_group = false;
  return data->window_group;
}
struct TabMetaData : public base::SupportsUserData::Data {
  std::string json;
};
inline std::string GetTabMeta(content::WebContents* contents) {
  if (!contents) return {};
  auto* data = static_cast<TabMetaData*>(contents->GetUserData(kTabMetaKey));
  return data ? data->json : std::string();
}
// Private tabs never keep Bark metadata.
inline void SetTabMeta(content::WebContents* contents, const std::string& meta) {
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord() || meta.size() > 8192) return;
  if (meta.empty()) { contents->RemoveUserData(kTabMetaKey); return; }
  auto* data = static_cast<TabMetaData*>(contents->GetUserData(kTabMetaKey));
  if (!data) {
    auto created = std::make_unique<TabMetaData>();
    data = created.get();
    contents->SetUserData(kTabMetaKey, std::move(created));
  }
  data->json = meta;
}
}  // namespace bark
#endif
