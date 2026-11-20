#include "bark/factory_reset.h"

#include <atomic>
#include <set>
#include <string>
#include <string_view>

#include "base/containers/fixed_flat_set.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/values.h"
#include "build/build_config.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/common/chrome_paths_internal.h"

#if BUILDFLAG(IS_MAC)
#include "bark/factory_reset_mac.h"
#endif

namespace bark {
namespace {
// Once a write has been dispatched, keep the singleton through shutdown even
// if the user quits while the write is pending. Only a committed write erases data.
bool retain_data_lock = false;  // UI thread only.
std::atomic_bool reset_committed = false;
constexpr char kMarker[] = "Bark Factory Reset";
constexpr char kProfiles[] = "bark.factory_reset.v1.profiles";

// A custom --user-data-dir can be a shared folder. Only remove Chromium's
// own top-level entries and registered profile directories there.
constexpr auto kBrowserFiles = base::MakeFixedFlatSet<std::string_view>({
    "AutofillStates", "Avatars", "BrowserMetrics", "BrowserMetrics-spare.pma",
    "CertificateRevocation", "ChromeFeatureState", "ClientSidePhishing",
    "Crash Reports", "Crashpad", "Crowd Deny", "DeferredBrowserMetrics",
    "DevToolsActivePort", "FileTypePolicies", "First Run", "FirstPartySetsPreloaded",
    "GCM Store", "GPUPersistentCache", "GraphiteDawnCache", "GrShaderCache",
    "Last Browser", "Last Version", "Local State", "MEIPreload",
    "NativeMessagingHosts", "OnDeviceHeadSuggestModel", "OpenCookieDatabase",
    "OptGuideOnDeviceModel", "OptGuidePredictionModels", "OptimizationGuideModels",
    "OptimizationGuideModelsManifest", "OriginTrials", "PKIMetadata",
    "PrivacySandboxAttestationsPreloaded", "ProbabilisticRevealTokenRegistry",
    "RecoveryImproved", "SSLErrorAssistant", "Safe Browsing", "SafetyTips",
    "ShaderCache", "Subresource Filter",
    "TrustTokenKeyCommitments", "Variations", "WidevineCdm", "ZxcvbnData",
    "component_crx_cache", "extensions_crx_cache", "first_party_sets.db",
    "first_party_sets.db-journal", "segmentation_platform",
});

bool IsSafeRoot(const base::FilePath& root) {
  if (!root.IsAbsolute() || root.ReferencesParent() || base::IsLink(root))
    return false;
  base::FilePath resolved;
  const auto home = base::MakeAbsoluteFilePath(base::GetHomeDir());
  return base::NormalizeFilePath(root, &resolved) && !home.empty() &&
         resolved != resolved.DirName() && resolved != home && !resolved.IsParent(home);
}

bool IsSingleComponent(const base::FilePath& path) {
  return !path.empty() && path == path.BaseName() && !path.IsAbsolute() &&
         !path.ReferencesParent() && path.value() != ".";
}

bool IsNumberedProfile(std::string_view name) {
  if (!name.starts_with(chrome::kMultiProfileDirPrefix)) return false;
  name.remove_prefix(std::string_view(chrome::kMultiProfileDirPrefix).size());
  return !name.empty() && name.find_first_not_of("0123456789") == name.npos;
}

bool ClearDirectory(const base::FilePath& root, bool dedicated,
                    const std::set<std::string>& profiles) {
  if (!IsSafeRoot(root)) return false;
  using E = base::FileEnumerator;
  E entries(root, false, E::FILES | E::DIRECTORIES | E::SHOW_SYM_LINKS, {},
            E::FolderSearchPolicy::ALL, E::ErrorPolicy::STOP_ENUMERATION);
  for (auto path = entries.Next(); !path.empty(); path = entries.Next()) {
    const auto name = path.BaseName().value();
    if (name == kMarker || name == chrome::kSingletonLockFilename ||
        name == chrome::kSingletonSocketFilename || name == chrome::kSingletonCookieFilename)
      continue;
    const bool profile_name = name == chrome::kInitialProfile || name == chrome::kGuestProfileDir ||
                              name == chrome::kSystemProfileDir || IsNumberedProfile(name);
    if (dedicated || profiles.contains(name) || kBrowserFiles.contains(name) ||
        (profile_name && !base::IsLink(path) && base::PathExists(path.Append("Preferences")))) {
      // Chromium's POSIX deletion unlinks symlinks without traversing them.
      if (!base::DeletePathRecursively(path)) return false;
    }
  }
  return entries.GetError() == base::File::FILE_OK;
}
}  // namespace

bool ScheduleFactoryReset(const base::FilePath& user_data,
                          const std::vector<base::FilePath>& profiles) {
  if (!IsSafeRoot(user_data) || !base::PathExists(user_data.Append(chrome::kLocalStateFilename)))
    return false;
  const auto marker = user_data.Append(kMarker);
  if (base::PathExists(marker) || base::IsLink(marker)) return false;
  base::ListValue names;
  for (const auto& profile : profiles) {
    if (profile.DirName() != user_data || !IsSingleComponent(profile.BaseName())) return false;
    names.Append(profile.BaseName().value());
  }
  base::DictValue request;
  request.Set(kProfiles, std::move(names));
  const auto json = base::WriteJson(request);
  if (!json || !base::ImportantFileWriter::WriteFileAtomically(marker, *json)) return false;
  reset_committed.store(true);
  return true;
}

void BeginFactoryReset() {
  retain_data_lock = true;
}

bool ShouldRetainDataLockForReset() {
  return retain_data_lock;
}

bool FinishFactoryResetOnExit(const base::FilePath& user_data) {
  return !reset_committed.load() || FinishPendingFactoryReset(user_data);
}

bool FinishPendingFactoryReset(const base::FilePath& user_data) {
  const auto marker = user_data.Append(kMarker);
  if (!base::PathExists(marker) || base::IsLink(marker) || base::DirectoryExists(marker)) return true;
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(marker, &contents, 1024 * 1024)) return false;
  const auto request = base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
  const auto* names = request ? request->FindList(kProfiles) : nullptr;
  if (!names) return true;  // An unrelated file is not a reset request.
  std::set<std::string> profiles;
  for (const auto& name : *names) {
    if (!name.is_string() || !IsSingleComponent(base::FilePath(name.GetString()))) return false;
    profiles.insert(name.GetString());
  }
  base::FilePath default_root;
  if (!chrome::GetDefaultUserDataDirectory(&default_root) || !IsSafeRoot(user_data)) return false;
  const bool dedicated = user_data == default_root;
  base::FilePath cache;
  chrome::GetUserCacheDirectory(user_data, &cache);
  if (cache != user_data && base::IsLink(cache)) {
    if (!base::DeleteFile(cache)) return false;
  } else if (cache != user_data && base::DirectoryExists(cache)) {
    if (!ClearDirectory(cache, dedicated, profiles)) return false;
  }
#if BUILDFLAG(IS_MAC)
  // Custom data directories share the installation's native defaults.
  if (dedicated && !ClearFactoryResetMacData()) return false;
#endif
  return ClearDirectory(user_data, dedicated, profiles) && base::DeleteFile(marker);
}
}  // namespace bark
