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
// Space ID of a Favorites tab: shown in every space of its profile's window,
// like Arc's Favorites. Never a catalog space ID (those are UUIDs).
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
}  // namespace bark
#endif
