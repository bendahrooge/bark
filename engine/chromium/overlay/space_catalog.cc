#include "bark/space_catalog.h"
#include <optional>
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
         !emoji.empty() && emoji.size() <= 256;
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
  for (const auto& value : List()) {
    const auto* space = value.GetIfDict();
    if (space && space->FindString("profile") && space->FindString("id") &&
        *space->FindString("profile") == profile) return *space->FindString("id");
  }
  return {};
}
std::string SpaceCatalog::Create(const std::string& name, const std::string& profile,
                                 const std::string& theme, const std::string& emoji) {
  if (!Valid(name, theme, emoji) || profile.empty() || List().size() >= 100) return {};
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
bool SpaceCatalog::Remove(const std::string& id) {
  const auto* space = Find(id);
  const std::string* profile = space ? space->FindString("profile") : nullptr;
  if (!profile) return false;
  int siblings = 0;
  for (const auto& value : List()) {
    const auto* other = value.GetIfDict();
    if (other && other->FindString("profile") && *other->FindString("profile") == *profile) ++siblings;
  }
  if (siblings < 2) return false;
  auto list = List().Clone();
  list.EraseIf([&](const base::Value& value) {
    const auto* item = value.GetIfDict();
    return item && item->FindString("id") && *item->FindString("id") == id;
  });
  prefs_->SetList(kSpacesPref, std::move(list));
  return true;
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
void SetSpaceProfileMover(SpaceProfileMover mover) { Mover() = mover; }
}  // namespace bark
