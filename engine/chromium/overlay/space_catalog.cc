#include "bark/space_catalog.h"
#include <algorithm>
#include <cmath>
#include <optional>
#include <map>
#include <set>
#include <utility>
#include "base/strings/string_util.h"
#include "base/uuid.h"
#include "components/prefs/pref_service.h"

namespace bark {
namespace {
SpaceProfileMover& Mover() {
  static SpaceProfileMover mover = nullptr;
  return mover;
}
bool Valid(const std::string& name, const std::string& theme,
           const std::string& emoji) {
  return !base::TrimWhitespaceASCII(name, base::TRIM_ALL).empty() &&
         name.size() <= 128 && !theme.empty() && theme.size() <= 32 &&
         emoji.size() <= 256;  // Empty: no icon chosen, shown as a dot.
}
}  // namespace
const base::ListValue& SpaceCatalog::List() const { return prefs_->GetList(kSpacesPref); }
const base::DictValue* SpaceCatalog::Find(const std::string& id) const {
  for (const auto& value : List()) {
    const auto* space = value.GetIfDict();
    if (space && space->FindString("id") && *space->FindString("id") == id) return space;
  }
  return nullptr;
}
std::string SpaceCatalog::FirstForProfile(const std::string& profile) const {
  std::string hidden;
  for (const auto& value : List()) {
    const auto* space = value.GetIfDict();
    if (space && space->FindString("profile") && space->FindString("id") &&
        *space->FindString("profile") == profile) {
      if (!space->FindBool("hidden").value_or(false)) return *space->FindString("id");
      hidden = *space->FindString("id");
    }
  }
  return hidden;
}
bool SpaceCatalog::IsHidden(const std::string& id) const {
  const auto* space = Find(id);
  return space && space->FindBool("hidden").value_or(false);
}
void SpaceCatalog::MigratePersonalIcon() {
  const std::string id = FirstForProfile("Default");
  const auto* space = Find(id);
  if (!space || space->FindBool("personalIconMigrated").value_or(false)) return;
  EditSpace(id, [](base::DictValue& entry) {
    const auto* name = entry.FindString("name");
    const auto* theme = entry.FindString("theme");
    const auto* emoji = entry.FindString("emoji");
    if (name && (*name == "Personal" || *name == "Your Chromium" || *name == "Your Bark") &&
        theme && *theme == "gray" && emoji && *emoji == "🍃") {
      entry.Set("emoji", "👤");
    }
    entry.Set("personalIconMigrated", true);
    return true;
  });
}
std::string SpaceCatalog::Create(const std::string& name, const std::string& profile,
                                 const std::string& theme, const std::string& emoji) {
  if (!Valid(name, theme, emoji) || profile.empty()) return {};
  const std::string saved = FirstForProfile(profile);
  if (IsHidden(saved)) {
    // Reusing a preserved profile restores its tabs without an extra default
    // space appearing alongside the space the user just requested.
    EditSpace(saved, [&](base::DictValue& space) {
      space.Remove("hidden");
      space.Set("name", name); space.Set("theme", theme); space.Set("emoji", emoji);
      return true;
    });
    return saved;
  }
  if (List().size() >= 100) return {};
  std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  base::DictValue space;
  space.Set("id", id); space.Set("name", name); space.Set("profile", profile);
  space.Set("theme", theme); space.Set("emoji", emoji);
  auto list = List().Clone(); list.Append(std::move(space));
  prefs_->SetList(kSpacesPref, std::move(list));
  return id;
}
bool SpaceCatalog::Update(const std::string& id, const std::string& name,
                          const std::string& theme, const std::string& emoji) {
  if (!Valid(name, theme, emoji)) return false;
  auto list = List().Clone();
  for (auto& value : list) {
    auto* space = value.GetIfDict();
    if (!space || !space->FindString("id") || *space->FindString("id") != id) continue;
    // The older Manage Spaces page only sends a named theme. Make that
    // selection visible; native canvas edits replace this field immediately
    // afterward through ApplySpaceStyle, retaining their exact custom colors.
    if (const auto* previous_theme = space->FindString("theme"); previous_theme && *previous_theme != theme)
      space->Remove("gradientCanvas");
    space->Set("name", name); space->Set("theme", theme); space->Set("emoji", emoji);
    prefs_->SetList(kSpacesPref, std::move(list));
    return true;
  }
  return false;
}
bool SpaceCatalog::SetProfile(const std::string& id, const std::string& profile,
                              base::ListValue pending_tabs) {
  if (profile.empty()) return false;
  auto list = List().Clone();
  for (auto& value : list) {
    auto* space = value.GetIfDict();
    if (!space || !space->FindString("id") || *space->FindString("id") != id) continue;
    space->Set("profile", profile);
    base::ListValue tabs;
    if (auto* existing = space->FindList("pendingTabs")) tabs = existing->Clone();
    for (auto& tab : pending_tabs) {
      if (tabs.size() >= 200) break;
      tabs.Append(std::move(tab));
    }
    if (tabs.empty()) space->Remove("pendingTabs");
    else space->Set("pendingTabs", std::move(tabs));
    prefs_->SetList(kSpacesPref, std::move(list));
    return true;
  }
  return false;
}
base::ListValue SpaceCatalog::TakePendingTabs(const std::string& id) {
  auto list = List().Clone();
  for (auto& value : list) {
    auto* space = value.GetIfDict();
    if (!space || !space->FindString("id") || *space->FindString("id") != id) continue;
    auto* tabs = space->FindList("pendingTabs");
    if (!tabs) return {};
    base::ListValue result = tabs->Clone();
    space->Remove("pendingTabs");
    prefs_->SetList(kSpacesPref, std::move(list));
    return result;
  }
  return {};
}
void SpaceCatalog::SetPreviewTabs(const std::string& id, base::ListValue tabs) {
  auto list = List().Clone();
  for (auto& value : list) {
    auto* space = value.GetIfDict();
    if (!space || !space->FindString("id") || *space->FindString("id") != id) continue;
    const auto* existing = space->FindList("previewTabs");
    if (existing ? *existing == tabs : tabs.empty()) return;
    if (tabs.empty()) space->Remove("previewTabs");
    else space->Set("previewTabs", std::move(tabs));
    prefs_->SetList(kSpacesPref, std::move(list));
    return;
  }
}
base::ListValue SpaceCatalog::SavedPreview(const std::string& id) const {
  const auto* space = Find(id);
  if (!space) return {};
  if (const auto* pending = space->FindList("pendingTabs"); pending && !pending->empty()) return pending->Clone();
  if (const auto* tabs = space->FindList("previewTabs")) return tabs->Clone();
  return {};
}
void SpaceCatalog::SetPreviewFavorites(const std::string& profile, base::ListValue tabs) {
  auto list = List().Clone();
  bool changed = false;
  for (auto& value : list) {
    auto* space = value.GetIfDict();
    if (!space || !space->FindString("profile") || *space->FindString("profile") != profile) continue;
    const auto* existing = space->FindList("previewFavorites");
    if (existing ? *existing == tabs : tabs.empty()) continue;
    if (tabs.empty()) space->Remove("previewFavorites");
    else space->Set("previewFavorites", tabs.Clone());
    changed = true;
  }
  if (changed) prefs_->SetList(kSpacesPref, std::move(list));
}
base::ListValue SpaceCatalog::SavedFavorites(const std::string& profile) const {
  for (const auto& value : List()) {
    const auto* space = value.GetIfDict();
    if (!space || !space->FindString("profile") || *space->FindString("profile") != profile) continue;
    if (const auto* tabs = space->FindList("previewFavorites")) return tabs->Clone();
  }
  return {};
}
bool SpaceCatalog::Remove(const std::string& id, const std::string& replacement) {
  if (id == replacement || !Find(replacement) || IsHidden(replacement) || IsHidden(id)) return false;
  const auto* space = Find(id);
  const std::string* profile = space ? space->FindString("profile") : nullptr;
  if (!profile) return false;
  int siblings = 0;
  for (const auto& value : List()) {
    const auto* other = value.GetIfDict();
    if (other && !other->FindBool("hidden").value_or(false) && other->FindString("profile") &&
        *other->FindString("profile") == *profile) ++siblings;
  }
  if (siblings < 2) return EditSpace(id, [](base::DictValue& entry) {
    entry.Set("hidden", true);
    return true;
  });
  auto list = List().Clone();
  list.EraseIf([&](const base::Value& value) {
    const auto* item = value.GetIfDict();
    return item && item->FindString("id") && *item->FindString("id") == id;
  });
  prefs_->SetList(kSpacesPref, std::move(list));
  return true;
}
void SpaceCatalog::RemoveSpacesForProfile(const std::string& profile) {
  auto list = List().Clone();
  std::set<std::string> removed_ids;
  const size_t removed = list.EraseIf([&](const base::Value& value) {
    const auto* space = value.GetIfDict();
    const auto* owner = space ? space->FindString("profile") : nullptr;
    if (!owner || *owner != profile) return false;
    if (const auto* id = space->FindString("id")) removed_ids.insert(*id);
    return true;
  });
  if (!removed) return;
  // Deleting a profile can remove every visible Space while another profile
  // still has its preserved, hidden Space. Make that Space reachable again.
  if (!list.empty() && std::ranges::all_of(list, [](const base::Value& value) {
        return value.is_dict() && value.GetDict().FindBool("hidden").value_or(false);
      })) {
    list.front().GetDict().Remove("hidden");
  }
  const auto& groups = prefs_->GetDict(kWindowGroupsPref);
  auto remaining = groups.Clone();
  for (const auto [group, space] : groups) {
    if (space.is_string() && removed_ids.contains(space.GetString())) remaining.Remove(group);
  }
  if (remaining.size() != groups.size()) prefs_->SetDict(kWindowGroupsPref, std::move(remaining));
  prefs_->SetList(kSpacesPref, std::move(list));
}
bool SpaceCatalog::Swap(const std::string& first, const std::string& second) {
  auto list = List().Clone();
  auto position = [&](const std::string& id) -> std::optional<size_t> {
    for (size_t i = 0; i < list.size(); ++i) {
      const auto* item = list[i].GetIfDict();
      if (item && item->FindString("id") && *item->FindString("id") == id) return i;
    }
    return std::nullopt;
  };
  const auto a = position(first);
  const auto b = position(second);
  if (!a || !b || *a == *b) return false;
  std::swap(list[*a], list[*b]);
  prefs_->SetList(kSpacesPref, std::move(list));
  return true;
}
bool SpaceCatalog::MoveToProfile(const std::string& id, const std::string& profile) {
  const auto* space = Find(id);
  if (!space || profile.empty()) return false;
  if (const auto* current = space->FindString("profile"); current && *current == profile) return true;
  if (Mover() && Mover()(id, profile)) return true;
  return SetProfile(id, profile, base::ListValue());
}
bool SpaceCatalog::EditSpace(const std::string& id,
                             base::FunctionRef<bool(base::DictValue&)> edit) {
  auto list = List().Clone();
  for (auto& value : list) {
    auto* space = value.GetIfDict();
    if (!space || !space->FindString("id") || *space->FindString("id") != id) continue;
    if (!edit(*space)) return false;
    prefs_->SetList(kSpacesPref, std::move(list));
    return true;
  }
  return false;
}
void SpaceCatalog::Archive(const std::string& id, base::ListValue tabs) {
  if (tabs.empty()) return;
  EditSpace(id, [&](base::DictValue& space) {
    if (const auto* existing = space.FindList("archivedTabs"))
      for (const auto& tab : *existing) tabs.Append(tab.Clone());
    while (tabs.size() > kMaxArchivedTabs) tabs.erase(tabs.end() - 1);
    space.Set("archivedTabs", std::move(tabs));
    return true;
  });
}
base::DictValue SpaceCatalog::TakeArchived(const std::string& id, size_t index) {
  base::DictValue taken;
  EditSpace(id, [&](base::DictValue& space) {
    auto* tabs = space.FindList("archivedTabs");
    if (!tabs || index >= tabs->size() || !(*tabs)[index].is_dict()) return false;
    taken = (*tabs)[index].GetDict().Clone();
    tabs->erase(tabs->begin() + index);
    if (tabs->empty()) space.Remove("archivedTabs");
    return true;
  });
  return taken;
}
void SpaceCatalog::ClearArchive(const std::string& id) {
  EditSpace(id, [](base::DictValue& space) { return space.Remove("archivedTabs"); });
}
bool SpaceCatalog::SetField(const std::string& id, const std::string& key, base::Value value) {
  if (key == "folders") {
    if (!value.is_none()) {
      if (!value.is_list() || value.GetList().size() > 64) return false;
      std::map<std::string, std::string> parents;
      for (const auto& item : value.GetList()) {
        const auto* folder = item.GetIfDict();
        const auto* folder_id = folder ? folder->FindString("id") : nullptr;
        const auto* name = folder ? folder->FindString("name") : nullptr;
        const auto* parent = folder ? folder->FindString("parent") : nullptr;
        if (!folder_id || folder_id->empty() || folder_id->size() > 80 || !name || name->empty() || name->size() > 64 ||
            (folder->Find("parent") && !parent) ||
            !parents.emplace(*folder_id, parent ? *parent : std::string()).second) return false;
      }
      // A folder may only be nested under a folder in this space. Checking
      // each ancestry also rejects self-parenting and longer cycles.
      for (const auto& [folder_id, parent] : parents) {
        std::set<std::string> visited{folder_id};
        for (std::string ancestor = parent; !ancestor.empty();) {
          auto found = parents.find(ancestor);
          if (found == parents.end() || !visited.insert(ancestor).second) return false;
          ancestor = found->second;
        }
      }
    }
  } else if (key == "pinsCollapsed") {
    if (!value.is_none() && !value.is_bool()) return false;
  } else if (key == "gradient") {
    if (!value.is_none() && (!value.is_string() || value.GetString().size() > 32)) return false;
  } else if (key == "grain") {
    if (!value.is_none() && (!value.is_double() || value.GetDouble() < 0 || value.GetDouble() > 1)) return false;
  } else if (key == "gradientCanvas") {
    if (!value.is_none()) {
      const auto* canvas = value.GetIfDict();
      if (!canvas || canvas->size() != 4) return false;
      for (const char* color_key : {"startColor", "endColor"}) {
        const auto* color = canvas->FindString(color_key);
        if (!color || color->size() != 7 || (*color)[0] != '#' ||
            !base::ContainsOnlyChars(color->substr(1), "0123456789abcdefABCDEF")) return false;
      }
      for (const char* point_key : {"start", "end"}) {
        const auto* point = canvas->FindDict(point_key);
        if (!point || point->size() != 2) return false;
        for (const char* axis : {"x", "y"}) {
          const auto position = point->FindDouble(axis);
          if (!position || !std::isfinite(*position) || *position < 0 || *position > 1) return false;
        }
      }
    }
  } else {
    return false;
  }
  return EditSpace(id, [&](base::DictValue& space) {
    const base::Value* current = space.Find(key);
    if (value.is_none()) return space.Remove(key);
    if (current && *current == value) return false;
    space.Set(key, std::move(value));
    return true;
  });
}
void SetSpaceProfileMover(SpaceProfileMover mover) { Mover() = mover; }
}  // namespace bark
