#include "bark/spaces_ui/spaces_ui.h"

#include <algorithm>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "bark/space_catalog.h"
#include "bark/spaces_ui/spaces_resources.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/ref_counted_memory.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "build/build_config.h"
#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_LINUX)
#include "bark/factory_reset.h"
#include "base/task/thread_pool.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#endif
#if BUILDFLAG(IS_MAC)
#include "chrome/browser/ui/webui/profile_helper.h"
#endif
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_attributes_storage_observer.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/ui_features.h"
#include "chrome/browser/ui/webui/theme_source.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/url_data_source.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
#include "content/public/browser/web_ui_message_handler.h"
#include "ui/webui/webui_util.h"

namespace bark {
namespace {
// Must match SpaceTheme in packages/core/src/SpaceTheme.swift.
constexpr const char* kThemes[] = {"gray", "sage",  "clay", "lavender", "ocean",
                                   "rose", "amber", "mint", "slate"};
constexpr size_t kMaxNameLength = 128;

std::string DisplayName(const ProfileAttributesEntry& entry) {
  std::string name = base::UTF16ToUTF8(entry.GetName());
  return name == "Your Chromium" || name == "Your Bark" ? "Personal" : name;
}

std::string ProfileKey(const base::FilePath& path) {
  return path.BaseName().AsUTF8Unsafe();
}

// Trimmed name, or empty when the name is blank or too long.
std::string CleanName(const std::string& name) {
  std::string trimmed(base::TrimWhitespaceASCII(name, base::TRIM_ALL));
  return trimmed.size() <= kMaxNameLength ? trimmed : std::string();
}

class SpacesHandler : public content::WebUIMessageHandler,
                      public ProfileAttributesStorageObserver {
 public:
  SpacesHandler()
      : catalog_(g_browser_process->local_state()),
        storage_(&g_browser_process->profile_manager()->GetProfileAttributesStorage()) {
    prefs_.Init(g_browser_process->local_state());
  }
  SpacesHandler(const SpacesHandler&) = delete;
  SpacesHandler& operator=(const SpacesHandler&) = delete;
  ~SpacesHandler() override = default;

  void RegisterMessages() override {
    Register("getState", &SpacesHandler::HandleGetState);
    Register("updateSpace", &SpacesHandler::HandleUpdateSpace);
    Register("swapSpaces", &SpacesHandler::HandleSwapSpaces);
    Register("deleteSpace", &SpacesHandler::HandleDeleteSpace);
    Register("setSpaceProfile", &SpacesHandler::HandleSetSpaceProfile);
    Register("createProfile", &SpacesHandler::HandleCreateProfile);
    Register("renameProfile", &SpacesHandler::HandleRenameProfile);
#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_LINUX)
    Register("factoryResetRequiringGesture", &SpacesHandler::HandleFactoryReset);
#endif
#if BUILDFLAG(IS_MAC)
    Register("deleteProfile", &SpacesHandler::HandleDeleteProfile);
#endif
  }

  void OnJavascriptAllowed() override {
    // The sidebar also rewrites this pref with tab previews; Push() sends
    // only changes that affect this page.
    prefs_.Add(kSpacesPref, base::BindRepeating(&SpacesHandler::Push, base::Unretained(this)));
    observation_.Observe(storage_);
  }
  void OnJavascriptDisallowed() override {
    weak_ptr_factory_.InvalidateWeakPtrs();
    prefs_.RemoveAll();
    observation_.Reset();
    last_state_.clear();
  }

  void OnProfileAdded(const base::FilePath&) override { Push(); }
  void OnProfileWasRemoved(const base::FilePath&, const std::u16string&) override { Push(); }
  void OnProfileNameChanged(const base::FilePath&, const std::u16string&) override { Push(); }
  void OnProfileIsOmittedChanged(const base::FilePath&) override { Push(); }

 private:
  void Register(std::string_view message, void (SpacesHandler::*method)(const base::ListValue&)) {
    web_ui()->RegisterMessageCallback(message, base::BindRepeating(method, base::Unretained(this)));
  }

  // All arguments must be strings; returns them, or nothing on a mismatch.
  static std::optional<std::vector<std::string>> Strings(const base::ListValue& args, size_t count) {
    if (args.size() != count) return std::nullopt;
    std::vector<std::string> values;
    for (const auto& value : args) {
      if (!value.is_string()) return std::nullopt;
      values.push_back(value.GetString());
    }
    return values;
  }

  ProfileAttributesEntry* FindProfile(const std::string& key) const {
    for (auto* entry : storage_->GetAllProfilesAttributes()) {
      if (!entry->IsOmitted() && ProfileKey(entry->GetPath()) == key) return entry;
    }
    return nullptr;
  }

  base::DictValue State() {
    base::ListValue profiles;
    std::set<std::string> keys;
    for (const auto* entry : storage_->GetAllProfilesAttributesSortedForDisplay()) {
      if (entry->IsOmitted()) continue;
      const std::string key = ProfileKey(entry->GetPath());
      keys.insert(key);
      base::DictValue profile;
      profile.Set("id", key);
      profile.Set("name", DisplayName(*entry));
      profiles.Append(std::move(profile));
    }
    // Spaces of removed profiles stay hidden, as in the sidebar.
    base::ListValue spaces;
    std::map<std::string, int> counts;
    for (const auto& value : catalog_.List()) {
      const auto* item = value.GetIfDict();
      if (!item || item->FindBool("hidden").value_or(false)) continue;
      const auto* id = item->FindString("id");
      const auto* profile = item->FindString("profile");
      if (!id || !profile || !keys.contains(*profile)) continue;
      base::DictValue space;
      space.Set("id", *id);
      space.Set("profile", *profile);
      for (const char* field : {"name", "theme", "emoji"}) {
        const auto* text = item->FindString(field);
        space.Set(field, text ? *text : std::string());
      }
      ++counts[*profile];
      spaces.Append(std::move(space));
    }
    for (auto& value : profiles) {
      auto& profile = value.GetDict();
      profile.Set("spaces", counts[*profile.FindString("id")]);
    }
    base::ListValue themes;
    for (const char* theme : kThemes) themes.Append(theme);
    base::DictValue state;
    state.Set("spaces", std::move(spaces));
    state.Set("profiles", std::move(profiles));
    state.Set("canDeleteProfiles", BUILDFLAG(IS_MAC) && Profile::FromWebUI(web_ui())->IsRegularProfile());
    state.Set("canFactoryReset", (BUILDFLAG(IS_MAC) || BUILDFLAG(IS_LINUX)) &&
                                 Profile::FromWebUI(web_ui())->IsRegularProfile());
    state.Set("themes", std::move(themes));
    return state;
  }

  void Push() {
    if (!IsJavascriptAllowed()) return;
    auto state = State();
    auto json = base::WriteJson(state);
    if (!json || *json == last_state_) return;
    last_state_ = *json;
    FireWebUIListener("state-changed", state);
  }

  void HandleGetState(const base::ListValue& args) {
    if (args.empty()) return;
    AllowJavascript();
    auto state = State();
    if (auto json = base::WriteJson(state)) last_state_ = *json;
    ResolveJavascriptCallback(args[0], state);
  }

  // [id, name, theme, emoji]
  void HandleUpdateSpace(const base::ListValue& args) {
    auto values = Strings(args, 4);
    if (!values) return;
    const std::string& id = (*values)[0];
    const std::string& theme = (*values)[2];
    const std::string& emoji = (*values)[3];
    const std::string name = CleanName((*values)[1]);
    if (name.empty() || std::ranges::find(kThemes, theme) == std::end(kThemes) ||
        emoji.size() > 64) {
      Push();
      return;
    }
    catalog_.Update(id, name, theme, emoji);
    Push();  // Restores the saved values if the update was rejected.
  }

  // [id, id]
  void HandleSwapSpaces(const base::ListValue& args) {
    if (auto values = Strings(args, 2)) catalog_.Swap((*values)[0], (*values)[1]);
    Push();
  }

  // [id]
  void HandleDeleteSpace(const base::ListValue& args) {
    if (auto values = Strings(args, 1)) {
      std::string replacement;
      for (const auto& value : catalog_.List()) {
        const auto* space = value.GetIfDict();
        const auto* id = space ? space->FindString("id") : nullptr;
        const auto* profile = space ? space->FindString("profile") : nullptr;
        if (id && *id != (*values)[0] && !catalog_.IsHidden(*id) && profile && FindProfile(*profile)) {
          replacement = *id;
          break;
        }
      }
      catalog_.Remove((*values)[0], replacement);
    }
    Push();
  }

  // [space id, profile id]
  void HandleSetSpaceProfile(const base::ListValue& args) {
    auto values = Strings(args, 2);
    if (!values || !catalog_.Find((*values)[0]) || !FindProfile((*values)[1])) {
      Push();
      return;
    }
    // Moving can close this page's own tab (it travels with its space), so
    // never run it inside this handler's message dispatch.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](std::string space, std::string profile) {
          SpaceCatalog(g_browser_process->local_state()).MoveToProfile(space, profile);
        }, (*values)[0], (*values)[1]));
  }

  // [name]
  void HandleCreateProfile(const base::ListValue& args) {
    auto values = Strings(args, 1);
    const std::string name = values ? CleanName((*values)[0]) : std::string();
    if (name.empty()) return;
    ProfileManager::CreateMultiProfileAsync(base::UTF8ToUTF16(name), /*icon_index=*/0,
        /*is_hidden=*/false, base::BindOnce([](std::string name, Profile* profile) {
          if (!profile) return;
          // Every profile has a space. The sidebar would add one too; both
          // check first, on the UI thread, so only one is created.
          SpaceCatalog catalog(g_browser_process->local_state());
          const std::string key = ProfileKey(profile->GetPath());
          if (catalog.FirstForProfile(key).empty()) catalog.Create(name, key, "gray", "");
        }, name));
  }

  // [profile id, name]
  void HandleRenameProfile(const base::ListValue& args) {
    auto values = Strings(args, 2);
    const std::string name = values ? CleanName((*values)[1]) : std::string();
    auto* entry = values ? FindProfile((*values)[0]) : nullptr;
    if (entry && !name.empty()) entry->SetLocalProfileName(base::UTF8ToUTF16(name), false);
    Push();
  }

#if BUILDFLAG(IS_MAC)
  // [profile id]
  void HandleDeleteProfile(const base::ListValue& args) {
    if (!Profile::FromWebUI(web_ui())->IsRegularProfile()) return;
    auto values = Strings(args, 1);
    auto* entry = values ? FindProfile((*values)[0]) : nullptr;
    if (!entry) return;
    // Deleting the page's own profile may close its tab during dispatch.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&webui::DeleteProfileAtPath, entry->GetPath(), ProfileMetrics::DELETE_PROFILE_SETTINGS));
  }
#endif

#if BUILDFLAG(IS_MAC) || BUILDFLAG(IS_LINUX)
  void HandleFactoryReset(const base::ListValue& args) {
    if (args.size() != 1 || !args[0].is_string()) return;
    AllowJavascript();
    // Shared across windows. Only one reset may be scheduled at a time.
    static bool pending = false;
    if (pending || !Profile::FromWebUI(web_ui())->IsRegularProfile()) {
      ResolveJavascriptCallback(args[0], base::Value(false));
      return;
    }
    // All paths come from the browser. The page only supplies its callback ID.
    auto* manager = g_browser_process->profile_manager();
    std::vector<base::FilePath> profiles;
    for (const auto* entry : storage_->GetAllProfilesAttributes())
      profiles.push_back(entry->GetPath());
    pending = true;
    BeginFactoryReset();
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
        {base::MayBlock(), base::TaskPriority::USER_BLOCKING, base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
        base::BindOnce(&ScheduleFactoryReset, manager->user_data_dir(), std::move(profiles)),
        base::BindOnce([](base::WeakPtr<SpacesHandler> handler, base::Value callback, bool ready) {
          pending = ready;
          if (handler && handler->IsJavascriptAllowed())
            handler->ResolveJavascriptCallback(callback, base::Value(ready));
          if (ready) {
            // The user has confirmed closing all windows and erasing their data.
            // A later tab or download prompt must not leave a reset armed.
            browser_shutdown::OnShutdownStarting(browser_shutdown::ShutdownType::kSilentExit);
            chrome::OnClosingAllBrowsers(true);
            chrome::CloseAllBrowsersAndQuit();
          }
        }, weak_ptr_factory_.GetWeakPtr(), args[0].Clone()));
  }
#endif

  SpaceCatalog catalog_;
  raw_ptr<ProfileAttributesStorage> storage_;
  PrefChangeRegistrar prefs_;
  base::ScopedObservation<ProfileAttributesStorage, ProfileAttributesStorageObserver> observation_{this};
  std::string last_state_;
  base::WeakPtrFactory<SpacesHandler> weak_ptr_factory_{this};
};

std::string_view RequestPath(const std::string& path) {
  std::string_view result(path);
  return result.substr(0, result.find_first_of("?#"));
}

bool ShouldHandle(const std::string& path) {
  const auto file = RequestPath(path);
  return file.empty() || file == "spaces.js" || file == "spaces.css";
}
}  // namespace

SpacesUI::SpacesUI(content::WebUI* web_ui) : content::WebUIController(web_ui) {
  Profile* profile = Profile::FromWebUI(web_ui);
  content::WebUIDataSource* source = content::WebUIDataSource::CreateAndAdd(profile, kSpacesHost);
  webui::SetJSModuleDefaults(source);
  webui::EnableTrustedTypesCSP(source);
  const bool refresh = features::IsWebuiRefresh2026Enabled();
  source->SetRequestFilter(base::BindRepeating(&ShouldHandle),
      base::BindRepeating([](bool refresh, const std::string& path,
                             content::WebUIDataSource::GotDataCallback callback) {
        const auto file = RequestPath(path);
        std::string body;
        if (file == "spaces.js") {
          body = kSpacesJs;
        } else if (file == "spaces.css") {
          body = kSpacesCss;
        } else {
          body = kSpacesHtml;
          base::ReplaceFirstSubstringAfterOffset(&body, 0, "$REFRESH",
                                                 refresh ? "webui-refresh-2026" : "");
        }
        std::move(callback).Run(base::MakeRefCounted<base::RefCountedString>(std::move(body)));
      }, refresh));
  content::URLDataSource::Add(profile, std::make_unique<ThemeSource>(profile));
  web_ui->AddMessageHandler(std::make_unique<SpacesHandler>());
}

SpacesUI::~SpacesUI() = default;
}  // namespace bark
