#include "bark/mac/arc_importer.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <set>
#include <utility>
#include <vector>

#include "bark/space_catalog.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/memory/ref_counted.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/history/core/browser/history_backend.h"
#include "components/history/core/browser/history_database.h"
#include "components/history/core/browser/history_db_task.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "components/prefs/pref_service.h"
#include "url/gurl.h"

namespace bark {
namespace {
constexpr char kBookmarkSource[] = "bark.arc.source";
bool importing = false;  // UI sequence; one import across all browser windows.

bool Text(const base::DictValue& value, const char* key, size_t limit,
          bool empty = false) {
  const auto* text = value.FindString(key);
  return text && (empty || !text->empty()) && text->size() <= limit;
}
bool WebURL(const base::DictValue& value) {
  const auto* url = value.FindString("url");
  return url && url->size() <= 65536 && GURL(*url).is_valid() && GURL(*url).SchemeIsHTTPOrHTTPS();
}

// Runs in small batches on Chromium's history sequence. Comparing actual visit
// timestamps makes retries idempotent even after a partially completed import.
class ImportHistoryTask : public history::HistoryDBTask {
 public:
  ImportHistoryTask(history::URLRows rows, base::OnceCallback<void(int, int, bool)> done)
      : rows_(std::move(rows)), done_(std::move(done)) {}
  bool RunOnDBThread(history::HistoryBackend* backend, history::HistoryDatabase* db) override {
    if (!db) { failed_ = true; return true; }
    history::URLRows batch;
    const size_t end = std::min(rows_.size(), offset_ + 500);
    for (; offset_ < end; ++offset_) {
      const auto& row = rows_[offset_];
      if (backend->IsExpiredVisitTime(row.last_visit())) { ++expired_; continue; }
      history::URLRow existing;
      const auto id = db->GetRowForURL(row.url(), &existing);
      history::VisitVector visits;
      if (id && !db->GetVisitsForURL(id, &visits)) { failed_ = true; return true; }
      if (std::ranges::any_of(visits, [&](const auto& visit) { return visit.visit_time == row.last_visit(); })) continue;
      batch.push_back(row);
    }
    backend->AddPagesWithDetails(batch, history::SOURCE_OS_MIGRATION_IMPORTED);
    for (const auto& row : batch) {
      history::URLRow saved;
      history::VisitVector visits;
      const auto id = db->GetRowForURL(row.url(), &saved);
      if (!id || !db->GetVisitsForURL(id, &visits) ||
          !std::ranges::any_of(visits, [&](const auto& visit) { return visit.visit_time == row.last_visit(); })) {
        failed_ = true; return true;
      }
      ++added_;
    }
    return offset_ == rows_.size();
  }
  void DoneRunOnMainThread() override { std::move(done_).Run(added_, expired_, !failed_); }
 private:
  history::URLRows rows_;
  base::OnceCallback<void(int, int, bool)> done_;
  size_t offset_ = 0;
  int added_ = 0, expired_ = 0;
  bool failed_ = false;
};

class ArcImporter : public base::RefCounted<ArcImporter> {
 public:
  explicit ArcImporter(base::OnceCallback<void(base::DictValue)> done) : done_(std::move(done)) {
    result_.Set("request", ""); result_.Set("success", false);
    for (const char* field : {"profiles", "spaces", "tabs", "history", "bookmarks", "extensions", "expiredHistory"}) result_.Set(field, 0);
  }
  void Start(const std::string& json) {
    auto parsed = json.size() <= 64 * 1024 * 1024 ? base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC) : std::nullopt;
    if (parsed && Text(*parsed, "request", 128)) result_.Set("request", *parsed->FindString("request"));
    if (importing) { Finish("Another Arc import is running. Try again when it finishes."); return; }
    if (!parsed || !Validate(*parsed)) { Finish("This import is invalid or exceeds Bark’s limit of 100 spaces or 5,000 tabs. Select fewer items and try again."); return; }
    importing = true; owns_import_ = true;
    profiles_ = std::move(*parsed->FindList("profiles"));
    NextProfile();
  }
 private:
  friend class base::RefCounted<ArcImporter>;
  ~ArcImporter() { if (owns_import_) importing = false; }
  bool Validate(const base::DictValue& request) {
    const auto* profiles = request.FindList("profiles");
    if (!Text(request, "request", 128) || !profiles || profiles->empty() || profiles->size() > 100) return false;
    std::set<std::string> sources, spaces;
    size_t new_spaces = 0, tabs = 0;
    SpaceCatalog catalog(g_browser_process->local_state());
    for (const auto& value : *profiles) {
      const auto* profile = value.GetIfDict();
      if (!profile || !Text(*profile, "source", 128) || !Text(*profile, "name", 512) ||
          !sources.insert(*profile->FindString("source")).second) return false;
      const auto* items = profile->FindList("spaces");
      const auto* bookmarks = profile->FindList("bookmarks");
      const auto* history = profile->FindList("history");
      if (!items || items->empty() || !bookmarks || bookmarks->size() > 20000 || !history || history->size() > 100000) return false;
      for (const auto& item : *items) {
        const auto* space = item.GetIfDict();
        if (!space || !Text(*space, "id", 128) || !Text(*space, "name", 128) || !Text(*space, "theme", 32) || !Text(*space, "emoji", 256) ||
            !spaces.insert(*space->FindString("id")).second) return false;
        const auto* existing = catalog.Find(*space->FindString("id"));
        if (existing) {
          const auto* source = existing->FindString("arcSource");
          if (!source || *source != *profile->FindString("source")) return false;
        } else { ++new_spaces; }
        const auto* entries = space->FindList("tabs");
        if (!entries) return false;
        tabs += entries->size();
        std::set<std::string> ids;
        for (const auto& entry : *entries) {
          const auto* tab = entry.GetIfDict();
          if (!tab || !Text(*tab, "id", 128) || !Text(*tab, "title", 2048, true) || !WebURL(*tab) ||
              !tab->FindBool("pinned").has_value() || !ids.insert(*tab->FindString("id")).second) return false;
        }
      }
      std::set<std::string> ids, folders = {""};
      for (const auto& item : *bookmarks) {
        const auto* bookmark = item.GetIfDict();
        if (!bookmark || !Text(*bookmark, "id", 256) || !Text(*bookmark, "parent", 256, true) ||
            !Text(*bookmark, "title", 2048, true) || !ids.insert(*bookmark->FindString("id")).second ||
            !folders.contains(*bookmark->FindString("parent"))) return false;
        if (bookmark->contains("url")) { if (!WebURL(*bookmark)) return false; }
        else folders.insert(*bookmark->FindString("id"));
      }
      std::set<std::pair<std::string, double>> visits;
      for (const auto& item : *history) {
        const auto* visit = item.GetIfDict();
        if (!visit || !Text(*visit, "title", 2048, true) || !WebURL(*visit)) return false;
        const auto time = visit->FindDouble("visitedAt");
        if (!time || !std::isfinite(*time) || *time <= 0 || *time > base::Time::Now().InMillisecondsFSinceUnixEpoch() ||
            !visits.emplace(*visit->FindString("url"), *time).second) return false;
      }
    }
    return catalog.List().size() + new_spaces <= 100 && tabs <= 5000;
  }
  void Add(const char* field, int count = 1) { result_.Set(field, result_.FindInt(field).value_or(0) + count); }
  void Finish(const std::string& error = {}) {
    if (owns_import_) { importing = false; owns_import_ = false; }
    result_.Set("success", error.empty());
    if (!error.empty()) result_.Set("error", error + " Any items already imported have been kept; retrying won’t duplicate them.");
    std::move(done_).Run(std::move(result_));
  }
  void NextProfile() {
    keep_alive_.reset();
    if (index_ == profiles_.size()) { Finish(); return; }
    const auto& source = profiles_[index_].GetDict();
    auto* manager = g_browser_process->profile_manager();
    // Find the profile by its import marker, never by a coincidentally equal
    // name or Arc's directory basename (which may be an existing Bark profile).
    for (const auto& value : SpaceCatalog(g_browser_process->local_state()).List()) {
      if (!value.is_dict()) continue;
      const auto& space = value.GetDict();
      const auto* origin = space.FindString("arcSource");
      const auto* key = space.FindString("arcProfile");
      if (!origin || !key || *origin != *source.FindString("source")) continue;
      for (auto* entry : manager->GetProfileAttributesStorage().GetAllProfilesAttributes()) {
        if (!entry->IsOmitted() && entry->GetPath().BaseName().AsUTF8Unsafe() == *key) {
          manager->CreateProfileAsync(entry->GetPath(), base::BindOnce(&ArcImporter::ProfileReady, this, false));
          return;
        }
      }
    }
    ProfileManager::CreateMultiProfileAsync(base::UTF8ToUTF16(*source.FindString("name")), 0, false,
        base::BindOnce(&ArcImporter::ProfileReady, this, true));
  }
  void ProfileReady(bool created, Profile* profile) {
    if (!profile) { Finish("Bark couldn’t create or load an imported profile."); return; }
    keep_alive_ = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kWaitingForBookmarksImportOnFirstRun);
    if (!keep_alive_) { Finish("The destination profile is closing."); return; }
    if (created) Add("profiles");
    if (!SaveSpaces(profile)) { Finish("There isn’t room for the selected spaces. Select fewer spaces and retry."); return; }
    WaitForBookmarks(0);
  }
  bool SaveSpaces(Profile* profile) {
    const auto& source = profiles_[index_].GetDict();
    auto* prefs = g_browser_process->local_state();
    auto catalog = prefs->GetList(kSpacesPref).Clone();
    int added_spaces = 0, added_tabs = 0;
    std::set<std::string> profile_keys;
    for (auto* entry : g_browser_process->profile_manager()->GetProfileAttributesStorage().GetAllProfilesAttributes())
      if (!entry->IsOmitted()) profile_keys.insert(entry->GetPath().BaseName().AsUTF8Unsafe());
    const std::string profile_key = profile->GetPath().BaseName().AsUTF8Unsafe();
    for (const auto& value : *source.FindList("spaces")) {
      const auto& incoming = value.GetDict();
      const auto& id = *incoming.FindString("id");
      base::DictValue* destination = nullptr;
      for (auto& existing : catalog) if (existing.is_dict() && existing.GetDict().FindString("id") && *existing.GetDict().FindString("id") == id) destination = &existing.GetDict();
      if (!destination) {
        if (catalog.size() >= 100) return false;
        base::DictValue space;
        for (const char* field : {"id", "name", "theme", "emoji"}) space.Set(field, *incoming.FindString(field));
        space.Set("profile", profile->GetPath().BaseName().AsUTF8Unsafe());
        space.Set("arcSource", *source.FindString("source"));
        space.Set("arcProfile", profile->GetPath().BaseName().AsUTF8Unsafe());
        catalog.Append(std::move(space)); destination = &catalog.back().GetDict();
        ++added_spaces;
      }
      destination->Set("arcProfile", profile_key);
      const auto* assigned = destination->FindString("profile");
      if (!assigned || !profile_keys.contains(*assigned)) destination->Set("profile", profile_key);
      // Keep the user's customization and profile assignment on a retry.
      std::set<std::string> imported;
      if (const auto* ids = destination->FindList("arcTabIds")) for (const auto& item : *ids) if (item.is_string()) imported.insert(item.GetString());
      base::ListValue pending;
      if (const auto* old = destination->FindList("pendingTabs")) pending = old->Clone();
      for (const auto& item : *incoming.FindList("tabs")) {
        const auto& tab = item.GetDict();
        if (!imported.insert(*tab.FindString("id")).second) continue;
        pending.Append(tab.Clone()); ++added_tabs;
      }
      base::ListValue ids;
      for (const auto& item : imported) ids.Append(item);
      destination->Set("arcTabIds", std::move(ids));
      destination->Set("pendingTabs", std::move(pending));
    }
    prefs->SetList(kSpacesPref, std::move(catalog));
    Add("spaces", added_spaces); Add("tabs", added_tabs);
    return true;
  }
  void WaitForBookmarks(int attempt) {
    Profile* profile = keep_alive_ ? keep_alive_->profile() : nullptr;
    if (!profile) { Finish("The destination profile closed during import."); return; }
    auto* model = BookmarkModelFactory::GetForBrowserContext(profile);
    if (!model) { Finish("Bookmarks are unavailable in the destination profile."); return; }
    if (!model->loaded()) {
      if (attempt >= 300) { Finish("Bookmarks took too long to load. Try again."); return; }
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
          base::BindOnce(&ArcImporter::WaitForBookmarks, this, attempt + 1), base::Milliseconds(100));
      return;
    }
    SaveBookmarks(model);
    const auto& source = profiles_[index_].GetDict();
    const auto* visits = source.FindList("history");
    if (visits->empty()) { ++index_; NextProfile(); return; }
    auto* service = HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::EXPLICIT_ACCESS);
    if (!service) { Finish("History is unavailable in the destination profile."); return; }
    history::URLRows rows;
    for (const auto& value : *visits) {
      const auto& visit = value.GetDict();
      history::URLRow row(GURL(*visit.FindString("url")));
      row.set_title(base::UTF8ToUTF16(*visit.FindString("title")));
      row.set_last_visit(base::Time::FromMillisecondsSinceUnixEpoch(*visit.FindDouble("visitedAt")));
      row.set_visit_count(1); row.set_typed_count(0);
      rows.push_back(std::move(row));
    }
    service->ScheduleDBTask(FROM_HERE, std::make_unique<ImportHistoryTask>(std::move(rows),
        base::BindOnce(&ArcImporter::HistoryReady, this)), &history_tasks_);
  }
  void SaveBookmarks(bookmarks::BookmarkModel* model) {
    const auto& source = profiles_[index_].GetDict();
    const auto& entries = *source.FindList("bookmarks");
    if (entries.empty()) return;
    const std::string prefix = *source.FindString("source") + "/";
    std::map<std::string, const bookmarks::BookmarkNode*> nodes;
    // Scan all local bookmarks so moving/renaming an imported folder doesn't
    // cause a second copy on the next import.
    std::vector<const bookmarks::BookmarkNode*> stack = {model->root_node()};
    while (!stack.empty()) {
      const auto* node = stack.back(); stack.pop_back();
      std::string marker;
      if (node->GetMetaInfo(kBookmarkSource, &marker) && marker.starts_with(prefix)) nodes[marker.substr(prefix.size())] = node;
      for (const auto& child : node->children()) stack.push_back(child.get());
    }
    model->BeginExtensiveChanges();
    if (!nodes.contains("")) {
      bookmarks::BookmarkNode::MetaInfoMap meta = {{kBookmarkSource, prefix}};
      const auto* parent = model->other_node();
      nodes[""] = model->AddFolder(parent, parent->children().size(), u"Imported from Arc", &meta);
    }
    for (const auto& value : entries) {
      const auto& item = value.GetDict();
      const auto& id = *item.FindString("id");
      if (nodes.contains(id)) continue;
      const auto* parent = nodes.at(*item.FindString("parent"));
      bookmarks::BookmarkNode::MetaInfoMap meta = {{kBookmarkSource, prefix + id}};
      const auto title = base::UTF8ToUTF16(*item.FindString("title"));
      const auto* url = item.FindString("url");
      nodes[id] = url ? model->AddURL(parent, parent->children().size(), title, GURL(*url), &meta)
                      : model->AddFolder(parent, parent->children().size(), title, &meta);
      Add("bookmarks");
      if (id.starts_with("extension/")) Add("extensions");
    }
    model->EndExtensiveChanges();
  }
  void HistoryReady(int added, int expired, bool success) {
    Add("history", added); Add("expiredHistory", expired);
    if (!success) { Finish("Some history entries could not be saved. Try again."); return; }
    ++index_; NextProfile();
  }
  base::OnceCallback<void(base::DictValue)> done_;
  base::DictValue result_;
  base::ListValue profiles_;
  size_t index_ = 0;
  bool owns_import_ = false;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive_;
  base::CancelableTaskTracker history_tasks_;
};
}  // namespace

bool IsArcImportInProgress() { return importing; }

void ImportArc(const std::string& json, base::OnceCallback<void(base::DictValue)> completion) {
  base::MakeRefCounted<ArcImporter>(std::move(completion))->Start(json);
}
}  // namespace bark
