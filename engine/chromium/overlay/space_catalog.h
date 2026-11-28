#ifndef BARK_SPACE_CATALOG_H_
#define BARK_SPACE_CATALOG_H_

#include <string>
#include "base/functional/function_ref.h"
#include "base/memory/raw_ptr.h"
#include "base/values.h"
class PrefService;

namespace bark {
inline constexpr char kSpacesPref[] = "bark.spaces";
inline constexpr char kWindowGroupsPref[] = "bark.window_groups";
class SpaceCatalog {
 public:
  explicit SpaceCatalog(PrefService* prefs) : prefs_(prefs) {}
  const base::ListValue& List() const;
  const base::DictValue* Find(const std::string& id) const;
  bool IsHidden(const std::string& id) const;
  std::string FirstForProfile(const std::string& profile) const;
  // One-time migration of the unchanged stock Personal icon; custom icons stay.
  void MigratePersonalIcon();
  std::string Create(const std::string& name, const std::string& profile,
                     const std::string& theme, const std::string& emoji);
  bool Update(const std::string& id, const std::string& name,
              const std::string& theme, const std::string& emoji);
  // Assigns a space to another profile. `pending_tabs` ({url, pinned}) are
  // stored with the space until that profile's window opens them.
  bool SetProfile(const std::string& id, const std::string& profile,
                  base::ListValue pending_tabs);
  // Returns and clears tabs waiting to reopen in the space's profile.
  base::ListValue TakePendingTabs(const std::string& id);
  // Remembers a space's tabs ({title, url, pinned, active}) so the sidebar can
  // preview the space while its profile's window is not open. Writes only
  // when the list changed.
  void SetPreviewTabs(const std::string& id, base::ListValue tabs);
  // Saved preview of a space: tabs waiting to reopen, else its last tabs.
  base::ListValue SavedPreview(const std::string& id) const;
  // Remembers a profile's Favorites ({title, url}) on its spaces, so a swipe
  // into that profile can show them before its window opens.
  void SetPreviewFavorites(const std::string& profile, base::ListValue tabs);
  base::ListValue SavedFavorites(const std::string& profile) const;
  // Removes a sidebar space, keeping at least one available replacement.
  // A profile's last space is retained privately to preserve its tabs/data.
  bool Remove(const std::string& id, const std::string& replacement);
  // Purges all Spaces and saved window selections owned by a deleted profile.
  void RemoveSpacesForProfile(const std::string& profile);
  // Swaps the positions of two spaces in the sidebar order.
  bool Swap(const std::string& first, const std::string& second);
  // Moves a space to another profile. With an open sidebar its tabs reopen
  // in the new profile (see SetSpaceProfileMover); otherwise only the
  // assignment changes.
  bool MoveToProfile(const std::string& id, const std::string& profile);
  // Archived tabs ({title, url}) of a space, most recently archived first.
  // At most kMaxArchivedTabs are kept.
  static constexpr size_t kMaxArchivedTabs = 50;
  void Archive(const std::string& id, base::ListValue tabs);
  // Returns and removes one archived tab; an empty dict if there is none.
  base::DictValue TakeArchived(const std::string& id, size_t index);
  void ClearArchive(const std::string& id);
  // Sets or (with a none value) removes one of a space's appearance or
  // layout fields: "folders" (a list of {id, name, collapsed, parent}), "pinsCollapsed", "gradient" (a
  // second theme name), "grain" (0-1), or "gradientCanvas" (two RGB colors
  // and two normalized points). Other keys are refused.
  bool SetField(const std::string& id, const std::string& key, base::Value value);
 private:
  // Applies `edit` to space `id`'s entry and saves the list if it returns true.
  bool EditSpace(const std::string& id, base::FunctionRef<bool(base::DictValue&)> edit);
  raw_ptr<PrefService> prefs_;
};

// The Mac sidebar moves a space's open tabs along with it. It registers this
// hook so pages such as chrome://spaces need not depend on the sidebar.
// Returns false when no sidebar window could perform the move.
using SpaceProfileMover = bool (*)(const std::string& space, const std::string& profile);
void SetSpaceProfileMover(SpaceProfileMover mover);
}  // namespace bark
#endif
