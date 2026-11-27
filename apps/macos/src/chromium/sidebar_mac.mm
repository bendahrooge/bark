#include "bark/mac/sidebar_mac.h"
#include "bark/browser_hooks.h"
#include "bark/mac/bark_importer.h"
#include "bark/lazy_tab.h"
#include "bark/native_ui_mac.h"
#include "bark/pinned_tab_close.h"
#include "bark/space_catalog.h"
#include "bark/space_tab_data.h"
#include "bark/mac/space_test_driver.h"
#include "bark/mac/updater_mac.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/auto_reset.h"
#include "base/base64.h"
#include "base/command_line.h"
#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_ptr_exclusion.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/no_destructor.h"
#include "base/uuid.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/stringprintf.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/bind_post_task.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/favicon/favicon_service_factory.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/infobars/confirm_infobar_creation_allowlist.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/common/chrome_switches.h"
#include "chrome/common/pref_names.h"
#include "chrome/browser/permissions/permission_actions_history_factory.h"
#include "chrome/browser/permissions/permission_decision_auto_blocker_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_attributes_storage_observer.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/sessions/session_service.h"
#include "chrome/browser/sessions/session_service_factory.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/themes/theme_service_factory.h"
#include "chrome/browser/themes/theme_service_observer.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/chrome_pages.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/browser/ui/bubble_anchor_util.h"
#include "chrome/browser/ui/extensions/extensions_container.h"
#include "chrome/browser/ui/fullscreen_util_mac.h"
#include "chrome/browser/ui/webui/profile_helper.h"
#include "chrome/browser/ui/page_info/page_info_dialog.h"
#include "chrome/browser/ui/startup/default_browser_prompt/default_browser_infobar_delegate.h"
#include "chrome/browser/ui/startup/default_browser_prompt/default_browser_prompt_manager.h"
#include "chrome/browser/ui/recently_audible_helper.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/split_tab_metrics.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/thumbnails/thumbnail_image.h"
#include "chrome/browser/ui/thumbnails/thumbnail_tab_helper.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_frame_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "chrome/browser/ui/views/frame/contents_container_view.h"
#include "chrome/browser/ui/views/frame/contents_web_view.h"
#include "chrome/browser/ui/views/extensions/extensions_toolbar_desktop.h"
#include "chrome/browser/ui/views/infobars/infobar_container_view.h"
#include "base/i18n/case_conversion.h"
#include "base/strings/string_split.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/browser/content_settings_utils.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/download/content/public/all_download_item_notifier.h"
#include "components/download/public/common/download_item.h"
#include "components/favicon/core/favicon_service.h"
#include "components/history/core/browser/history_service.h"
#include "content/public/browser/download_manager.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/confirm_infobar_delegate.h"
#include "components/infobars/core/infobar.h"
#include "chrome/browser/ui/views/infobars/confirm_infobar.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "components/omnibox/browser/location_bar_model.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "components/permissions/features.h"
#include "components/permissions/permission_actions_history.h"
#include "components/permissions/permission_decision_auto_blocker.h"
#include "components/permissions/permission_uma_util.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/split_tabs/split_tab_id.h"
#include "components/split_tabs/split_tab_visual_data.h"
#include "components/tabs/public/split_tab_data.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/elide_url.h"
#include "components/url_formatter/url_fixer.h"
#include "extensions/browser/extension_registry.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/favicon_status.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "services/media_session/public/cpp/media_metadata.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "services/network/public/cpp/is_potentially_trustworthy.h"
#include "third_party/blink/public/common/features.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/accelerators/global_accelerator_listener/global_accelerator_listener.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/size.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/base/window_open_disposition.h"
#include "ui/base/base_window.h"
#include "ui/compositor/compositor.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/views/controls/button/label_button.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/view_utils.h"
#include "ui/views/widget/widget.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"

extern "C" {
void* BarkSwiftSidebarCreate(void*, void (*)(void*, const char*));
void BarkSwiftSidebarUpdate(void*, const char*);
void BarkSwiftSidebarFocusAddress(void*);
void BarkSwiftSidebarComposeAddress(void*);
void BarkSwiftSidebarDismissAddress(void*);
bool BarkSwiftSidebarAddressVisible(void*);
void BarkSwiftSidebarOpenSuggestion(void*, const char*);
void BarkSwiftSidebarSelectSpace(void*, const char*);
void BarkSwiftSidebarShowPreferences(void*);
void BarkSwiftSidebarDestroy(void*);
void* BarkSwiftSidebarHeaderCreate(void*);
void BarkSwiftSidebarHeaderDestroy(void*);
void* BarkSwiftSidebarResizeCreate(void*);
void BarkSwiftSidebarResizeDestroy(void*);
void* BarkSwiftSidebarBackdropCreate(void*);
void BarkSwiftSidebarBackdropDestroy(void*);
void BarkSwiftSidebarBackdropSetCanvasSize(void*, double width, double height);
void* BarkSwiftPageFrameCreate(void*);
void BarkSwiftPageFrameUpdate(void*, const char*);
void BarkSwiftPageFrameDestroy(void*);
void BarkSwiftSidebarSuggestions(void*, const char*);
void BarkSwiftSidebarSwitcher(void*, const char*);
void* BarkSwiftPopupAttach(void*, void*, void*, const char*, void*, void (*)(void*, const char*));
void BarkSwiftPopupBeginEntrance(void*);
void BarkSwiftPopupPerformControl(void*, const char*);
void BarkSwiftPopupSetCanSplit(void*, bool);
void BarkSwiftPopupSetSpaces(void*, const char*);
void BarkSwiftPopupUpdateSite(void*, const char*);
double BarkSwiftPopupAnchorX(void*, bool extensions);
void BarkSwiftPopupEditAddress(void*, const char*, bool when_key);
bool BarkSwiftPopupAddressVisible(void*);
void BarkSwiftPopupCopyURL(void*, const char*);
void BarkSwiftUseCopyPasteboardForTesting(const char*);
void* BarkSwiftPopupCover(void*, void*);
void BarkSwiftPopupRemoveCover(void*);
void BarkSwiftPopupDetach(void*);
}

// AppKit owns the menu item, which retains this delegate. The callbacks resolve
// the current browser at use time rather than retaining a closed window.
using BarkExtensionsMenuPopulate = void (*)(NSMenu*);
using BarkExtensionsMenuInvoke = void (*)(NSMenuItem*);
@interface BarkExtensionsMenuDelegate : NSObject <NSMenuDelegate>
@property(nonatomic) BarkExtensionsMenuPopulate populate;
@property(nonatomic) BarkExtensionsMenuInvoke invoke;
- (void)invokeItem:(NSMenuItem*)item;
@end

@implementation BarkExtensionsMenuDelegate
@synthesize populate = _populate;
@synthesize invoke = _invoke;
- (void)menuNeedsUpdate:(NSMenu*)menu {
  if (self.populate) self.populate(menu);
}
- (void)invokeItem:(NSMenuItem*)item {
  if (self.invoke) self.invoke(item);
}
@end

// A quiet reminder at the page edge. It never intercepts page clicks.
@interface BarkSidebarEdgeView : NSView
@end
@implementation BarkSidebarEdgeView
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.28] setFill];
  const CGFloat height = std::min<CGFloat>(72, self.bounds.size.height);
  [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2, (self.bounds.size.height - height) / 2, 2, height)
                                  xRadius:1 yRadius:1] fill];
}
@end

namespace bark {
namespace {
DEFINE_UI_CLASS_PROPERTY_KEY(bool, kBarkPeek, false)
DEFINE_UI_CLASS_PROPERTY_KEY(views::View*, kLittleSiteAnchor, nullptr)
DEFINE_UI_CLASS_PROPERTY_KEY(views::View*, kLittleExtensionsAnchor, nullptr)
constexpr int kLittleHeaderHeight = 46;
constexpr NSString* kSidebarWidth = @"BarkChromium.SidebarWidth";
constexpr NSString* kSidebarCollapsed = @"BarkChromium.SidebarCollapsed";
constexpr char kSavedSessionTitle[] = "bark.saved_session_title";
constexpr char kCheckedPinHistory[] = "bark.checked_pin_history";
struct SavedSessionTitle : base::SupportsUserData::Data {
  int navigation_id = 0;
  std::u16string title;
};
struct WindowGroup {
  std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  bool closing = false;
  bool restoring = false;
  // Set once the user explicitly selects a space in this window. A pending
  // session-restore presentation must not override that choice.
  bool user_presented = false;
  // True while a space switch cross-fades between this group's windows.
  int transitions = 0;
  // A new gesture can end on the outgoing profile's window before or just
  // after the incoming window takes over the same screen position.
  struct SwipeHandoff {
    int source_window;
    std::string landing_space;
    std::string next_space;
    bool tracking = false;
  };
  std::optional<SwipeHandoff> swipe_handoff;
};

// A profile window that a space switch is about to open. It starts invisible
// so the switch can fade it in over the current window instead of Chromium's
// default "new window" presentation.
struct PendingSpacePresentation {
  base::FilePath profile;
};
std::optional<PendingSpacePresentation>& PendingPresentation() {
  static base::NoDestructor<std::optional<PendingSpacePresentation>> pending;
  return *pending;
}
constexpr double kSpaceFadeSeconds = 0.18;

struct AddressDestination {
  GURL url;
  bool is_search = false;
  // The default search provider's display name (e.g. "Google") for searches.
  std::u16string engine_name;
};

AddressDestination ResolveAddress(const std::string& input, Profile* profile) {
  if (input.empty()) return {GURL("about:blank")};
  GURL fixed = url_formatter::FixupURL(input, std::string());
  if (fixed.is_valid() &&
      (input.find(":") != std::string::npos ||
       input.find(".") != std::string::npos || input == "localhost")) {
    return {fixed};
  }
  if (auto* service = TemplateURLServiceFactory::GetForProfile(profile)) {
    if (const auto* engine = service->GetDefaultSearchProvider()) {
      const GURL search(engine->url_ref().ReplaceSearchTerms(
          TemplateURLRef::SearchTermsArgs(base::UTF8ToUTF16(input)), service->search_terms_data()));
      if (search.is_valid()) return {search, true, engine->short_name()};
    }
  }
  // A policy may disable search entirely. Do not bypass that choice with a
  // hard-coded provider; a normal URL can still be entered.
  return {GURL(), true};
}

// Feature preferences shared by the Library menu and Settings.
constexpr NSString* kArchiveAfterHours = @"BarkChromium.ArchiveAfterHours";
constexpr NSString* kPeekDisabled = @"BarkChromium.PeekDisabled";
constexpr NSString* kLittleWindowDisabled = @"BarkChromium.LittleWindowDisabled";
constexpr NSString* kGlobalLittleShortcut = @"BarkChromium.GlobalLittleShortcut";
// Unpinned tabs not shown for this long move to their space's archive.
// Bark archives tabs after 12 hours by default. Zero disables automatic archiving.
int ArchiveAfterHours() {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  if (![defaults objectForKey:kArchiveAfterHours]) return 12;
  return static_cast<int>(std::clamp<NSInteger>([defaults integerForKey:kArchiveAfterHours], 0, 24 * 365));
}
bool PeekEnabled() { return ![NSUserDefaults.standardUserDefaults boolForKey:kPeekDisabled]; }

bool GlobalLittleShortcutEnabled() { return [NSUserDefaults.standardUserDefaults boolForKey:kGlobalLittleShortcut]; }

base::DictValue ReadTabMeta(content::WebContents* contents) {
  auto meta = base::JSONReader::ReadDict(GetTabMeta(contents), base::JSON_PARSE_RFC);
  return meta ? std::move(*meta) : base::DictValue();
}
double Now() { return base::Time::Now().InSecondsFSinceUnixEpoch(); }

// The page a tab shows, ignoring the fragment.
GURL PageURL(content::WebContents* contents) {
  const GURL& committed = contents->GetLastCommittedURL();
  GURL url = committed.is_valid() && !committed.IsAboutBlank() ? committed : contents->GetVisibleURL();
  GURL::Replacements clear;
  clear.ClearRef();
  return url.is_valid() ? url.ReplaceComponents(clear) : url;
}
// Only constructed by the explicit disposable-profile native test driver.
class BarkNoticeTestDelegate : public ConfirmInfoBarDelegate {
 public:
  BarkNoticeTestDelegate(bool locked, base::RepeatingCallback<void(std::string)> action)
      : locked_(locked), action_(std::move(action)) {}
  InfoBarIdentifier GetIdentifier() const override { return TEST_INFOBAR; }
  InfobarPriority GetPriority() const override { return InfobarPriority::kDefault; }
  std::u16string GetMessageText() const override { return u"A site needs your attention. Review this browser notice."; }
  int GetButtons() const override { return BUTTON_OK | BUTTON_CANCEL | BUTTON_EXTRA; }
  std::u16string GetButtonLabel(InfoBarButton button) const override {
    return button == BUTTON_OK ? u"Continue" : button == BUTTON_CANCEL ? u"Keep browsing" : u"Unavailable action";
  }
  bool GetButtonEnabled(InfoBarButton button) const override { return button != BUTTON_EXTRA; }
  bool IsCloseable() const override { return !locked_; }
  bool Accept() override { action_.Run("accept"); return true; }
  bool Cancel() override { action_.Run("cancel"); return true; }
  bool ExtraButtonPressed() override { action_.Run("extra"); return true; }
  std::u16string GetLinkText() const override { return u"Learn more"; }
  bool LinkClicked(WindowOpenDisposition) override { action_.Run("link"); return false; }
  void InfoBarDismissed() override { action_.Run("dismiss"); }
 private:
  bool locked_;
  base::RepeatingCallback<void(std::string)> action_;
};

bool IsBlankPage(const GURL& url) {
  return !url.is_valid() || url.IsAboutBlank() || (url.SchemeIs("chrome") && url.host() == "newtab");
}

// Chromium caches its 1x PNG bytes. Cache the 2x encoding as well, since a
// sidebar snapshot reads every tab even when only one tab has changed.
struct SidebarFavicon : base::SupportsUserData::Data {
  explicit SidebarFavicon(const gfx::Image& image) : source(image) {
    const auto& rep = image.ToImageSkia()->GetRepresentation(2.0f);
    if (!rep.is_null() && rep.scale() == 2.0f)
      png = gfx::PNGCodec::EncodeBGRASkBitmap(rep.GetBitmap(), /*discard_transparency=*/false);
  }
  gfx::Image source;
  std::optional<std::vector<uint8_t>> png;
};

std::string FaviconPNG(content::NavigationEntry* entry, size_t max_bytes) {
  if (!entry) return {};
  const auto& icon = entry->GetFavicon();
  if (!icon.valid || icon.image.IsEmpty()) return {};
  static constexpr char kSidebarFavicon[] = "bark.sidebar_favicon";
  auto* cached = static_cast<SidebarFavicon*>(entry->GetUserData(kSidebarFavicon));
  if (!cached || cached->source != icon.image) {
    auto replacement = std::make_unique<SidebarFavicon>(icon.image);
    cached = replacement.get();
    entry->SetUserData(kSidebarFavicon, std::move(replacement));
  }
  if (cached->png && cached->png->size() <= max_bytes) return base::Base64Encode(*cached->png);
  auto png = icon.image.As1xPNGBytes();
  return png && png->size() <= max_bytes ? base::Base64Encode(*png) : std::string();
}

// Encodes a favicon from the history database for the address bar, preferring
// the 2x representation so it stays sharp on Retina displays.
std::string SuggestionFaviconPNG(const gfx::Image& image, size_t max_bytes) {
  if (image.IsEmpty()) return {};
  const auto& rep = image.ToImageSkia()->GetRepresentation(2.0f);
  if (!rep.is_null() && rep.scale() == 2.0f) {
    if (auto png = gfx::PNGCodec::EncodeBGRASkBitmap(rep.GetBitmap(), /*discard_transparency=*/false);
        png && png->size() <= max_bytes)
      return base::Base64Encode(*png);
  }
  auto png = image.As1xPNGBytes();
  return png && png->size() <= max_bytes ? base::Base64Encode(*png) : std::string();
}

const base::DictValue* CachedPinPage(const base::DictValue& meta, const GURL& url) {
  for (const char* key : {"pinPage", "visitedPage"}) {
    const auto* page = meta.FindDict(key);
    const auto* spec = page ? page->FindString("url") : nullptr;
    if (spec && url.EqualsIgnoringRef(GURL(*spec))) return page;
  }
  return nullptr;
}

// Navigate shows a new popup before returning, even with kNoAction. Keep
// that first show transparent until Swift installs Peek at its starting size.
class ScopedPeekCreation : public BrowserCollectionObserver {
 public:
  explicit ScopedPeekCreation(Profile* profile) {
    observation_.Observe(ProfileBrowserCollection::GetForProfile(profile));
  }
  ~ScopedPeekCreation() override {
    if (widget_) widget_->SetOpacity(1.f);
  }
  void OnBrowserCreated(BrowserWindowInterface* browser) override {
    if (browser->GetType() != BrowserWindowInterface::TYPE_POPUP) return;
    auto* view = BrowserView::GetBrowserViewForBrowser(browser);
    if (!view || !view->GetWidget()) return;
    observation_.Reset();
    widget_ = view->GetWidget()->GetWeakPtr();
    widget_->SetVisibilityChangedAnimationsEnabled(false);
    widget_->SetOpacity(0.f);
  }

 private:
  base::ScopedObservation<ProfileBrowserCollection, BrowserCollectionObserver> observation_{this};
  base::WeakPtr<views::Widget> widget_;
};
}  // namespace

bool LittleWindowEnabled() { return ![NSUserDefaults.standardUserDefaults boolForKey:kLittleWindowDisabled]; }

class SidebarMac::Impl : public TabStripModelObserver,
                         public ProfileAttributesStorageObserver,
                         public ThemeServiceObserver,
                         public download::AllDownloadItemNotifier::Observer,
                         public AutocompleteController::Observer,
                         public infobars::InfoBarManager::Observer {
 public:
  explicit Impl(BrowserView* view)
      : view_(view), tabs_(view->browser()->GetTabStripModel()),
        profiles_(&g_browser_process->profile_manager()->GetProfileAttributesStorage()),
        catalog_(g_browser_process->local_state()) {
    Instances().push_back(this);
    PinnedTabCloser() = &HandlePinnedClose;
    NewTabComposer() = &ComposeNewTab;
    PreferencesPresenter() = &ShowNativePreferences;
    NavigationThrottles() = &AddPeekThrottle;
    NewContentsPeek() = &PeekNewContents;
    ExternalLink() = &OpenExternalLink;
    ExternalTabDestination() = &DismissAddressForExternalTab;
    InstallExtensionsMenu();
    if (!IsPrivate()) {
      SetSpaceProfileMover(&MoveFromSettings);
      EnsureProfileSpaces();
      active_space_ = catalog_.FirstForProfile(ProfileKey());
      space_observer_.Init(g_browser_process->local_state());
      space_observer_.Add(kSpacesPref, base::BindRepeating(&Impl::QueueSnapshot, weak_factory_.GetWeakPtr()));
      close_subscription_ = view_->browser()->RegisterBrowserDidClose(
          base::BindRepeating(&Impl::CloseOtherHosts, weak_factory_.GetWeakPtr()));
      archive_timer_.Start(FROM_HERE, base::Minutes(1),
                           base::BindRepeating(&Impl::AutoArchive, base::Unretained(this)));
      DefaultAutoPictureInPicture();
    }
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:kSidebarWidth];
    width_ = saved ? std::clamp<int>(saved, 200, 400) : 260;
    collapsed_ = [[NSUserDefaults standardUserDefaults] boolForKey:kSidebarCollapsed];
    sidebar_progress_ = collapsed_ ? 0 : 1;
    // Native Chromium bubbles need Views anchors in the same widget. These
    // noninteractive views track the corresponding Swift controls.
    site_anchor_ = view_->AddChildView(std::make_unique<views::View>());
    extensions_anchor_ = view_->AddChildView(std::make_unique<views::View>());
    site_anchor_->SetCanProcessEventsWithinSubtree(false);
    extensions_anchor_->SetCanProcessEventsWithinSubtree(false);
    swift_ = BarkSwiftSidebarCreate(this, &ReceiveCommand);
    page_frame_swift_ = BarkSwiftPageFrameCreate(swift_);
    page_frame_host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    page_frame_host_->SetCanProcessEventsWithinSubtree(false);
    page_frame_host_->Attach(gfx::NativeView((__bridge NSView*)page_frame_swift_));
    backdrop_swift_ = BarkSwiftSidebarBackdropCreate(swift_);
    backdrop_host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    backdrop_host_->SetCanProcessEventsWithinSubtree(false);
    backdrop_host_->Attach(gfx::NativeView((__bridge NSView*)backdrop_swift_));
    host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    host_->Attach(gfx::NativeView((__bridge NSView*)swift_));
    header_swift_ = BarkSwiftSidebarHeaderCreate(swift_);
    header_host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    header_host_->Attach(gfx::NativeView((__bridge NSView*)header_swift_));
    resize_swift_ = BarkSwiftSidebarResizeCreate(swift_);
    resize_host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    resize_host_->Attach(gfx::NativeView((__bridge NSView*)resize_swift_));
    edge_hint_ = [[BarkSidebarEdgeView alloc] initWithFrame:NSZeroRect];
    edge_host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    edge_host_->SetCanProcessEventsWithinSubtree(false);
    edge_host_->Attach(gfx::NativeView(edge_hint_));
    tabs_->AddObserver(this);
    profiles_->AddObserver(this);
    // The color mode can also change in chrome://settings.
    theme_observation_.Observe(ThemeServiceFactory::GetForProfile(view_->GetProfile()));
    if (auto* downloads = view_->GetProfile()->GetDownloadManager())
      download_notifier_ = std::make_unique<download::AllDownloadItemNotifier>(downloads, this);
    AdoptPendingPresentation();
    AdoptOwnerlessLittleWindows();
    SyncGlobalLittleShortcut();
    StartSpaceTestDriver(base::BindRepeating(&Impl::TestRequest));
    QueueSnapshot();
  }

  ~Impl() override {
    if (group_->swipe_handoff &&
        (group_->swipe_handoff->source_window == view_->browser()->GetSessionID().id() ||
         (revealing_ && group_->swipe_handoff->landing_space == active_space_)))
      group_->swipe_handoff.reset();
    std::erase(Instances(), this);
    ClearPromotionCover();
    // A Little window belongs to the person browsing it, independently of
    // whether its original sidebar window is still open.
    for (auto it = popups_.begin(); it != popups_.end();) {
      if ((*it)->kind != "little") { ++it; continue; }
      (*it)->owner = nullptr;
      OwnerlessLittleWindows().push_back(std::move(*it));
      it = popups_.erase(it);
    }
    for (auto* host : Instances()) host->AdoptOwnerlessLittleWindows();
    SyncGlobalLittleShortcut();
    for (auto& popup : popups_) {
      if (popup->swift) BarkSwiftPopupDetach(popup->swift);
      popup->swift = nullptr;
    }
    ClosePopups("peek");
    popups_.clear();
    notice_observation_.Reset();
    if (autocomplete_) autocomplete_->RemoveObserver(this);
    if (revealing_) {
      // Never leave an outgoing window transparent.
      for (auto& host : reveal_outgoing_)
        if (host) if (auto* widget = host->view_->GetWidget()) widget->SetOpacity(1.f);
      group_->transitions = std::max(0, group_->transitions - 1);
    }
    reveal_weak_factory_.InvalidateWeakPtrs();
    weak_factory_.InvalidateWeakPtrs();
    if (tabs_) tabs_->RemoveObserver(this);
    profiles_->RemoveObserver(this);
    sidebar_motion_timer_.Stop();
    RestoreTrafficLights();
    edge_host_->Detach();
    view_->RemoveChildViewT(edge_host_.ExtractAsDangling());
    resize_host_->Detach();
    view_->RemoveChildViewT(resize_host_.ExtractAsDangling());
    BarkSwiftSidebarResizeDestroy(resize_swift_);
    header_host_->Detach();
    view_->RemoveChildViewT(header_host_.ExtractAsDangling());
    BarkSwiftSidebarHeaderDestroy(header_swift_);
    backdrop_host_->Detach();
    view_->RemoveChildViewT(backdrop_host_.ExtractAsDangling());
    BarkSwiftSidebarBackdropDestroy(backdrop_swift_);
    page_frame_host_->Detach();
    view_->RemoveChildViewT(page_frame_host_.ExtractAsDangling());
    BarkSwiftPageFrameDestroy(page_frame_swift_);
    host_->Detach();
    view_->RemoveChildViewT(host_.ExtractAsDangling());
    BarkSwiftSidebarDestroy(swift_);
    view_->RemoveChildViewT(site_anchor_.ExtractAsDangling());
    view_->RemoveChildViewT(extensions_anchor_.ExtractAsDangling());
  }

  static constexpr int kFloatingInset = 8;
  // Keep in sync with SidebarBackdropView.shadowMargin.
  static constexpr int kShadowMargin = 24;

  bool CanShow() const {
    return !fullscreen_utils::IsInContentFullscreen(view_->browser()) &&
           !(view_->IsFullscreen() &&
             base::CommandLine::ForCurrentProcess()->HasSwitch(switches::kKioskMode));
  }

  // Spring progress can exceed one: the panel gently overshoots its resting
  // position, while opacity stays clamped independently.
  int SlideOffset(int sidebar_width) const {
    if (!collapsed_) return 0;
    return -static_cast<int>(std::lround((1 - sidebar_progress_) * (sidebar_width + 16)));
  }

  int width() const {
    return !collapsed_ && CanShow() ? width_ : 0;
  }

  void Layout() {
    const bool can_show = CanShow();
    // Chromium reserves the gutter and rounds the native page surfaces. This
    // input-transparent host paints one continuous theme behind the docked
    // sidebar and around the page, including the space between split panes.
    page_frame_host_->SetVisible(can_show);
    if (can_show) {
      page_frame_host_->SetBounds(0, 0, view_->width(), view_->height());
      auto rect_value = [this](views::View* source) {
        const gfx::Rect rect = views::View::ConvertRectToTarget(
            source, view_, source->GetLocalBounds());
        base::DictValue value;
        value.Set("x", rect.x()); value.Set("y", rect.y());
        value.Set("width", rect.width()); value.Set("height", rect.height());
        return value;
      };
      base::DictValue geometry;
      geometry.Set("bounds", rect_value(view_->contents_container()));
      base::ListValue panes;
      for (ContentsContainerView* pane : view_->GetContentsContainerViews()) {
        if (pane->GetVisible() && !pane->bounds().IsEmpty()) panes.Append(rect_value(pane));
      }
      geometry.Set("panes", std::move(panes));
      if (auto json = base::WriteJson(geometry)) BarkSwiftPageFrameUpdate(page_frame_swift_, json->c_str());
    }
    const int sidebar_width = width_;
    const bool shown = can_show && (!collapsed_ || revealed_ || sidebar_progress_ > 0);
    host_->SetVisible(shown);
    // Keep the native hosts alive until the fade finishes, then remove them
    // from hit testing. Window controls fade with the sidebar.
    const auto params = view_->browser_widget()->GetFrameView()->GetBrowserLayoutParams();
    const int top = std::max(38, static_cast<int>(std::max(
        params.leading_exclusion.ContentWithPadding().height(),
        params.trailing_exclusion.ContentWithPadding().height())));
    const int inset = collapsed_ ? kFloatingInset : 0;
    const int shadow = collapsed_ ? kShadowMargin : 0;
    const int panel_x = inset + SlideOffset(sidebar_width);
    const int panel_height = std::max(0, view_->height() - inset * 2);
    if (shown && collapsed_)
      BarkSwiftSidebarBackdropSetCanvasSize(backdrop_swift_, view_->width(), view_->height());
    // Only the floating panel needs a separate backdrop. Docked chrome shares
    // the page frame's window-wide surface so gradients never restart here.
    backdrop_host_->SetVisible(shown && collapsed_);
    backdrop_host_->SetBounds(panel_x - shadow, inset - shadow,
                              sidebar_width + shadow * 2, panel_height + shadow * 2);
    host_->SetBounds(panel_x, top + inset, sidebar_width, std::max(0, panel_height - top));
    header_host_->SetVisible(shown);
    // Fullscreen hides the caption buttons, so the header no longer needs to
    // clear the space they normally occupy.
    const int header_leading = view_->IsFullscreen() ? 10 : 84;
    header_host_->SetBounds(header_leading + panel_x, inset + std::max(0, (top - 28) / 2),
                           std::max(28, sidebar_width - header_leading - (collapsed_ ? 8 : 1)), 28);
    // Keep the generous resize target on the actual boundary. Reserving it
    // inside the Swift tab list creates a visible gutter beside every row.
    resize_host_->SetVisible(shown);
    resize_host_->SetBounds(panel_x + sidebar_width - 1, top + inset,
                            12, std::max(0, panel_height - top));
    const double progress = std::clamp(sidebar_progress_, 0.0, 1.0);
    const double content_opacity = collapsed_ ? std::min(1.0, progress * 2.5) : progress;
    ((__bridge NSView*)swift_).alphaValue = content_opacity;
    ((__bridge NSView*)header_swift_).alphaValue = content_opacity;
    ((__bridge NSView*)backdrop_swift_).alphaValue = content_opacity;
    ((__bridge NSView*)resize_swift_).alphaValue = content_opacity;
    edge_host_->SetBounds(0, top, 7, std::max(0, view_->height() - top));
    edge_host_->SetVisible(can_show && collapsed_ && progress < 1);
    edge_hint_.alphaValue = 1 - progress;
    if (view_->IsFullscreen()) {
      RestoreTrafficLights();  // Fullscreen's caption controls belong to AppKit.
    } else {
      NSWindow* window = view_->GetNativeWindow().GetNativeNSWindow();
      for (NSWindowButton type : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
        NSButton* button = [window standardWindowButton:type];
        auto& geometry = traffic_light_frames_[type];
        // AppKit can reposition the buttons on window resize. Only undo our
        // offset when it is still the one we applied on the previous frame.
        if (!geometry.initialized || !NSEqualRects(button.frame, geometry.applied))
          geometry.original = button.frame;
        NSRect frame = geometry.original;
        frame.origin.x += panel_x;
        frame.origin.y += button.superview.isFlipped ? inset : -inset;
        button.frame = frame;
        geometry.applied = frame;
        geometry.initialized = true;
        button.hidden = !shown;
        button.alphaValue = content_opacity;
      }
      traffic_lights_managed_ = true;
    }
    const bool expanded = !collapsed_ || revealed_;
    site_anchor_->SetBounds(expanded ? sidebar_width - (collapsed_ ? 39 : 32) + panel_x : 84,
                            expanded ? top + inset + 9 : 5, 24, 28);
    // The address bar has no extensions button; extension popups open from
    // the menu bar and hang beneath the site controls button instead.
    extensions_anchor_->SetBoundsRect(site_anchor_->bounds());
    site_anchor_->SetVisible(can_show);
    extensions_anchor_->SetVisible(can_show);
  }

  views::View* bubble_anchor(bool extensions) const {
    return extensions ? extensions_anchor_.get() : site_anchor_.get();
  }

  void FocusAddress() {
    if (!tabs_ || tabs_->closing_all()) return;
    Snapshot();
    BarkSwiftSidebarFocusAddress(swift_);
  }

  static bool ComposeNewTab(BrowserWindowInterface* browser) {
    for (auto* host : Instances()) {
      if (host->view_->browser() != browser || !host->swift_ || !host->tabs_ ||
          host->tabs_->closing_all() || host->group_->closing) continue;
      host->Snapshot();
      BarkSwiftSidebarComposeAddress(host->swift_);
      return true;
    }
    return false;
  }

  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange& change,
                             const TabStripSelectionChange& selection) override {
    if (change.type() == TabStripModelChange::kReplaced && !IsPrivate()) {
      const auto* replace = change.GetReplace();
      if (replace->tab->IsPinned()) {
        // Chromium retains the tab slot on discard but gives the replacement
        // contents a new session ID. Carry the pin's sidebar and session data.
        SetTabSpace(replace->new_contents, GetTabSpace(replace->old_contents));
        SetTabMeta(replace->new_contents, GetTabMeta(replace->old_contents));
        PersistTab(replace->new_contents);
      }
    }
    if (promotion_cover_ && selection.active_tab_changed() &&
        selection.new_contents.get() != covered_contents_.get()) ClearPromotionCover();
    if (selection.active_tab_changed() && !tabs_->closing_all()) {
      just_closed_pin_.reset();
      // A tab counts as seen until the moment another replaces it.
      if (auto* old = selection.old_contents.get(); old && tabs_->GetIndexOfWebContents(old) != TabStripModel::kNoTab)
        TouchTab(old);
      if (auto* contents = selection.new_contents.get()) {
        TouchTab(contents);
        const int id = sessions::SessionTabHelper::IdForTab(contents).id();
        // Each space reopens on the tab last used in it.
        if (const std::string space = GetTabSpace(contents); space != kFavoritesSpace && SpaceBelongsHere(space))
          selected_tabs_[space] = id;
        std::erase(recent_tabs_, id);
        recent_tabs_.insert(recent_tabs_.begin(), id);
        if (recent_tabs_.size() > 200) recent_tabs_.pop_back();
      }
    }
    QueueGroupSnapshot();
  }
  void OnTabChangedAt(tabs::TabInterface* tab, TabChangeType) override {
    if (tab->IsPinned()) RememberPinnedPage(tab->GetContents(), true);
    PersistTitle(tab->GetContents());
    QueueGroupSnapshot();
  }
  void OnTabPinnedStateChanged(tabs::TabInterface* tab, int) override {
    // A pin remembers the page it was pinned on; unpinning forgets it and
    // takes the tab out of its folder.
    auto* contents = tab->GetContents();
    if (!tab->IsPinned()) {
      EditTabMeta(contents, [](base::DictValue& meta) {
        const bool url = meta.Remove("pinnedURL");
        const bool folder = meta.Remove("folder");
        const bool home = meta.Remove("pinPage");
        const bool visited = meta.Remove("visitedPage");
        return url || folder || home || visited;
      });
    } else {
      RememberPinnedPage(contents, true);
    }
    QueueGroupSnapshot();
  }
  void OnSplitTabChanged(const SplitTabChange&) override { QueueGroupSnapshot(); }
  void OnTabStripModelDestroyed(TabStripModel*) override { tabs_ = nullptr; }
  void OnProfileAdded(const base::FilePath&) override { QueueSnapshot(); }
  void OnProfileWasRemoved(const base::FilePath&, const std::u16string&) override { QueueSnapshot(); }
  void OnProfileNameChanged(const base::FilePath&, const std::u16string&) override { QueueSnapshot(); }
  void OnProfileIsOmittedChanged(const base::FilePath&) override { QueueSnapshot(); }
  void OnThemeChanged() override {
    view_->InvalidateLayout();
    QueueSnapshot();
  }

  // Download progress for the sidebar. Updates arrive for every chunk, so the
  // sidebar refreshes at most twice a second while downloading.
  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem*) override { QueueDownloadSnapshot(); }
  void OnDownloadUpdated(content::DownloadManager*, download::DownloadItem* item) override {
    QueueDownloadSnapshot();
    // Hide the "finished" state again once it is no longer recent.
    if (item->GetState() == download::DownloadItem::COMPLETE)
      download_expiry_.Start(FROM_HERE, kRecentDownload + base::Seconds(1),
                             base::BindOnce(&Impl::QueueSnapshot, weak_factory_.GetWeakPtr()));
  }
  void OnDownloadRemoved(content::DownloadManager*, download::DownloadItem*) override { QueueDownloadSnapshot(); }

 private:
  friend class SidebarMac;
  void RestoreTrafficLights() {
    if (!traffic_lights_managed_) return;
    NSWindow* window = view_->GetNativeWindow().GetNativeNSWindow();
    for (NSWindowButton type : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
      NSButton* button = [window standardWindowButton:type];
      auto found = traffic_light_frames_.find(type);
      if (found != traffic_light_frames_.end() && NSEqualRects(button.frame, found->second.applied))
        button.frame = found->second.original;
      button.hidden = NO;
      button.alphaValue = 1;
    }
    traffic_light_frames_.clear();
    traffic_lights_managed_ = false;
  }
  void SetSidebarPresentation(bool animate) {
    sidebar_motion_timer_.Stop();
    sidebar_target_ = !collapsed_ || revealed_ ? 1 : 0;
    if (!animate || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion ||
        !CanShow() || (sidebar_progress_ == sidebar_target_ && sidebar_velocity_ == 0)) {
      sidebar_progress_ = sidebar_target_;
      sidebar_velocity_ = 0;
    } else {
      // Keep velocity when the pointer reverses direction mid-animation.
      sidebar_motion_start_ = sidebar_motion_tick_ = base::TimeTicks::Now();
      sidebar_motion_timer_.Start(FROM_HERE, base::Milliseconds(8), this, &Impl::SidebarMotionStep);
    }
    view_->InvalidateLayout();
  }
  void SidebarMotionStep() {
    const auto now = base::TimeTicks::Now();
    const double dt = (now - sidebar_motion_tick_).InSecondsF();
    sidebar_motion_tick_ = now;
    const double displacement = sidebar_progress_ - sidebar_target_;
    if (sidebar_target_ == 1) {
      // An underdamped spring reaches the panel's resting place in ~100 ms,
      // overshoots by about 4%, then settles. Solve analytically so dropped
      // frames do not change its speed or destabilize it.
      constexpr double frequency = 32;
      constexpr double damping = 0.72;
      const double decay = damping * frequency;
      const double oscillation = frequency * std::sqrt(1 - damping * damping);
      const double b = (sidebar_velocity_ + decay * displacement) / oscillation;
      const double envelope = std::exp(-decay * dt);
      const double cosine = std::cos(oscillation * dt);
      const double sine = std::sin(oscillation * dt);
      sidebar_progress_ = sidebar_target_ + envelope * (displacement * cosine + b * sine);
      sidebar_velocity_ = envelope * ((b * oscillation - decay * displacement) * cosine -
                                      (displacement * oscillation + decay * b) * sine);
    } else {
      // Critically damped dismissal leaves promptly without bouncing back
      // into view, including when it interrupts the entrance spring.
      constexpr double frequency = 55;
      const double b = sidebar_velocity_ + frequency * displacement;
      const double envelope = std::exp(-frequency * dt);
      sidebar_progress_ = sidebar_target_ + (displacement + b * dt) * envelope;
      sidebar_velocity_ = (sidebar_velocity_ - frequency * b * dt) * envelope;
    }
    if ((std::abs(sidebar_progress_ - sidebar_target_) < 0.002 && std::abs(sidebar_velocity_) < 0.02) ||
        (now - sidebar_motion_start_).InSecondsF() >= 0.45) {
      sidebar_progress_ = sidebar_target_;
      sidebar_velocity_ = 0;
      sidebar_motion_timer_.Stop();
    }
    Layout();
  }
  static std::vector<Impl*>& Instances() {
    static base::NoDestructor<std::vector<Impl*>> instances;
    return *instances;
  }
  static Impl* ActiveMenuHost() {
    for (int i = 0; i < 2; ++i) {
      NSWindow* window = i == 0 ? NSApp.keyWindow : NSApp.mainWindow;
      if (!window) continue;
      for (auto* host : Instances()) {
        // A host is registered while its Browser is still being constructed,
        // before the Browser has a window. A Little window can be key then.
        auto* browser_window = host->view_->browser()->GetWindow();
        if (host->tabs_ && !host->tabs_->closing_all() && !host->view_->browser()->IsDeleteScheduled() &&
            browser_window && browser_window->IsVisible() &&
            host->view_->GetNativeWindow().GetNativeNSWindow() == window) return host;
      }
    }
    return nullptr;
  }
  static NSMenu* InstallExtensionsMenu() {
    NSMenu* main = NSApp.mainMenu;
    if (!main) return nil;
    for (NSMenuItem* item in main.itemArray)
      if ([item.identifier isEqualToString:@"BarkExtensionsMenu"]) return item.submenu;
    auto* delegate = [[BarkExtensionsMenuDelegate alloc] init];
    delegate.populate = &PopulateExtensionsMenu;
    delegate.invoke = &InvokeExtensionsMenu;
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Extensions"];
    menu.autoenablesItems = NO;
    menu.delegate = delegate;
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Extensions" action:nil keyEquivalent:@""];
    item.identifier = @"BarkExtensionsMenu";
    item.representedObject = delegate;
    item.submenu = menu;
    NSInteger index = NSApp.windowsMenu ? [main indexOfItemWithSubmenu:NSApp.windowsMenu] : -1;
    [main insertItem:item atIndex:index >= 0 ? index : std::max<NSInteger>(0, main.numberOfItems - 1)];
    PopulateExtensionsMenu(menu);
    return menu;
  }
  static void PopulateExtensionsMenu(NSMenu* menu) {
    [menu removeAllItems];
    auto* host = ActiveMenuHost();
    auto add = [&](NSString* title, NSString* action, bool enabled, NSImage* image = nil) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(invokeItem:) keyEquivalent:@""];
      item.target = menu.delegate;
      item.enabled = enabled;
      item.image = image;
      item.representedObject = @{@"action": action,
          @"window": @(host ? host->view_->browser()->GetSessionID().id() : -1)};
      [menu addItem:item];
    };
    std::vector<ToolbarActionViewModel*> actions;
    if (host) {
      auto* container = ExtensionsContainer::From(*host->view_->browser());
      auto* model = ToolbarActionsModel::Get(host->view_->GetProfile());
      if (container && model) for (const auto& id : model->action_ids())
        if (auto* action = container->GetActionForId(id)) actions.push_back(action);
    }
    std::sort(actions.begin(), actions.end(), [](auto* a, auto* b) {
      return [base::SysUTF16ToNSString(a->GetActionName())
          localizedStandardCompare:base::SysUTF16ToNSString(b->GetActionName())] == NSOrderedAscending;
    });
    for (auto* action : actions) {
      auto* active = host->tabs_->GetActiveWebContents();
      // The same icon the toolbar shows, sized to a menu item's image slot.
      NSImage* image = nil;
      const auto icon = action->GetIcon(active, gfx::Size(16, 16));
      if (!icon.IsEmpty()) {
        image = gfx::Image(icon.Rasterize(host->view_->GetColorProvider())).AsNSImage();
        image.size = NSMakeSize(16, 16);
      }
      add(base::SysUTF16ToNSString(action->GetActionName()), base::SysUTF8ToNSString(action->GetId()),
          action->IsEnabled(active), image);
    }
    if (actions.empty()) add(host ? @"No enabled extensions" : @"Open a browser window to use extensions", @"", false);
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Manage Extensions…", @"bark.manageExtensions", host != nullptr);
  }
  static void InvokeExtensionsMenu(NSMenuItem* item) {
    auto* host = ActiveMenuHost();
    NSDictionary* value = item.representedObject;
    if (!host || !item.enabled || [value[@"window"] intValue] != host->view_->browser()->GetSessionID().id()) return;
    // Let AppKit finish closing the menu before Chromium presents a popup.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Impl::ActivateExtensionMenuItem, host->weak_factory_.GetWeakPtr(),
                       base::SysNSStringToUTF8(value[@"action"])));
  }
  void ActivateExtensionMenuItem(const std::string& id) {
    if (ActiveMenuHost() != this) return;
    if (id == "bark.manageExtensions") {
      NavigateTo(GURL("chrome://extensions/"), true);
      return;
    }
    if (auto* container = ExtensionsContainer::From(*view_->browser())) {
      auto* action = container->GetActionForId(id);
      if (action && action->IsEnabled(tabs_->GetActiveWebContents()))
        action->ExecuteUserAction(ToolbarActionViewModel::InvocationSource::kMenuEntry);
    }
  }

  void ObserveNotices(content::WebContents* active) {
    auto* manager = active ? infobars::ContentInfoBarManager::FromWebContents(active) : nullptr;
    if (notice_observation_.GetSource() == manager) return;
    notice_observation_.Reset();
    notice_ids_.clear();
    if (manager) notice_observation_.Observe(manager);
  }

  void OnInfoBarAdded(infobars::InfoBar*) override { QueueSnapshot(); }
  void OnInfoBarRemoved(infobars::InfoBar* notice, bool) override {
    notice_ids_.erase(notice);
    QueueSnapshot();
  }
  void OnInfoBarReplaced(infobars::InfoBar* previous, infobars::InfoBar*) override {
    notice_ids_.erase(previous);
    QueueSnapshot();
  }
  void OnManagerWillBeDestroyed(infobars::InfoBarManager*) override {
    notice_observation_.Reset();
    notice_ids_.clear();
    QueueSnapshot();
  }

  static bool IsUsefulNotice(infobars::InfoBar* notice) {
    if (!notice || !notice->delegate()->AsConfirmInfoBarDelegate()) return false;
    const auto id = notice->GetIdentifier();
    return id != infobars::InfoBarDelegate::DEFAULT_BROWSER_INFOBAR_DELEGATE &&
           id != infobars::InfoBarDelegate::PIN_INFOBAR_DELEGATE &&
           id != infobars::InfoBarDelegate::PDF_INFOBAR_DELEGATE &&
           notice->delegate()->GetPriority() != infobars::InfoBarDelegate::InfobarPriority::kLow;
  }

  base::ListValue NoticesState(content::WebContents* active) {
    ObserveNotices(active);
    base::ListValue notices;
    auto* manager = notice_observation_.GetSource();
    if (!active || !manager) return notices;
    for (const auto& notice_entry : manager->infobars()) {
      auto* notice = notice_entry.get();
      if (!IsUsefulNotice(notice)) continue;
      auto* delegate = notice->delegate()->AsConfirmInfoBarDelegate();
      std::u16string message;
      const auto format = delegate->GetMessageTextTemplate();
      const auto substitutions = delegate->GetMessageSubstitutions();
      if (format.empty()) message = delegate->GetMessageText();
      else {
        std::vector<std::u16string> values;
        for (const auto& substitution : substitutions) values.push_back(substitution.text);
        message = base::ReplaceStringPlaceholders(format, values, nullptr);
      }
      if (message.empty()) continue;
      auto [entry, added] = notice_ids_.try_emplace(notice, std::string());
      if (added) entry->second = base::NumberToString(++notice_sequence_);
      base::DictValue item;
      item.Set("id", entry->second);
      item.Set("tabId", sessions::SessionTabHelper::IdForTab(active).id());
      item.Set("url", PageURL(active).spec());
      item.Set("message", base::UTF16ToUTF8(message));
      item.Set("critical", delegate->GetPriority() == infobars::InfoBarDelegate::InfobarPriority::kCriticalSecurity);
      item.Set("closeable", delegate->IsCloseable());
      base::ListValue actions;
      auto append = [&](const std::string& id, const std::u16string& label, bool enabled) {
        if (label.empty()) return;
        base::DictValue action;
        action.Set("id", id); action.Set("title", base::UTF16ToUTF8(label)); action.Set("enabled", enabled);
        actions.Append(std::move(action));
      };
      for (auto button : {ConfirmInfoBarDelegate::BUTTON_OK, ConfirmInfoBarDelegate::BUTTON_CANCEL,
                          ConfirmInfoBarDelegate::BUTTON_EXTRA}) {
        if (delegate->GetButtons() & button)
          append(button == ConfirmInfoBarDelegate::BUTTON_OK ? "accept" :
                 button == ConfirmInfoBarDelegate::BUTTON_CANCEL ? "cancel" : "extra",
                 delegate->GetButtonLabel(button), delegate->GetButtonEnabled(button));
      }
      append("link", delegate->GetLinkText(), true);
      for (size_t i = 0; i < substitutions.size(); ++i)
        if (substitutions[i].is_link)
          append("inline:" + base::NumberToString(i), substitutions[i].text, true);
      item.Set("actions", std::move(actions));
      notices.Append(std::move(item));
    }
    return notices;
  }

  void PerformNoticeAction(const base::DictValue& message, content::WebContents* active, int index) {
    const auto* metadata = message.FindDict("metadata");
    const auto* expected_url = metadata ? metadata->FindString("url") : nullptr;
    const auto* id = metadata ? metadata->FindString("notice") : nullptr;
    const auto* action = message.FindString("text");
    if (!active || index != tabs_->active_index() || !expected_url || *expected_url != PageURL(active).spec() ||
        !id || !action) return;
    auto* manager = infobars::ContentInfoBarManager::FromWebContents(active);
    if (!manager || notice_observation_.GetSource() != manager) return;
    infobars::InfoBar* notice = nullptr;
    for (const auto& notice_entry : manager->infobars()) {
      auto* candidate = notice_entry.get();
      auto found = notice_ids_.find(candidate);
      if (found != notice_ids_.end() && found->second == *id) { notice = candidate; break; }
    }
    if (!IsUsefulNotice(notice)) return;
    auto* delegate = notice->delegate()->AsConfirmInfoBarDelegate();
    const auto weak_notice = notice->AsWeakPtr();
    const auto weak_self = weak_factory_.GetWeakPtr();
    bool close = false;
    if (*action == "dismiss" && delegate->IsCloseable()) {
      delegate->InfoBarDismissed();
      close = true;
    } else if (*action == "link" && !delegate->GetLinkText().empty()) {
      close = delegate->LinkClicked(WindowOpenDisposition::kNewForegroundTab);
    } else if (action->starts_with("inline:")) {
      size_t substitution_index = 0;
      const auto substitutions = delegate->GetMessageSubstitutions();
      if (!base::StringToSizeT(action->substr(7), &substitution_index) || substitution_index >= substitutions.size() || !substitutions[substitution_index].is_link) return;
      close = delegate->InlineSubstitutionLinkClicked(substitution_index, WindowOpenDisposition::kNewForegroundTab);
    } else {
      const auto button = *action == "accept" ? ConfirmInfoBarDelegate::BUTTON_OK :
                          *action == "cancel" ? ConfirmInfoBarDelegate::BUTTON_CANCEL :
                          *action == "extra" ? ConfirmInfoBarDelegate::BUTTON_EXTRA : ConfirmInfoBarDelegate::BUTTON_NONE;
      if (button == ConfirmInfoBarDelegate::BUTTON_NONE || !(delegate->GetButtons() & button) || !delegate->GetButtonEnabled(button)) return;
      close = button == ConfirmInfoBarDelegate::BUTTON_OK ? delegate->Accept() :
              button == ConfirmInfoBarDelegate::BUTTON_CANCEL ? delegate->Cancel() : delegate->ExtraButtonPressed();
    }
    // A delegate may synchronously navigate, replace itself, or close its window.
    if (close && weak_notice) weak_notice->RemoveSelf();
    if (weak_self) weak_self->QueueSnapshot();
  }

  static std::optional<ContentSettingsType> SitePermissionType(const std::string& id) {
    if (id == "clipboard") return ContentSettingsType::CLIPBOARD_READ_WRITE;
    if (id == "camera") return ContentSettingsType::MEDIASTREAM_CAMERA;
    if (id == "microphone") return ContentSettingsType::MEDIASTREAM_MIC;
    if (id == "autoPictureInPicture") return ContentSettingsType::AUTO_PICTURE_IN_PICTURE;
    return std::nullopt;
  }

  // A managed setting must not acquire a hidden user exception that would take
  // effect later if the policy or extension disappeared.
  static std::string SitePermissionRestriction(HostContentSettingsMap* settings,
      const GURL& url, ContentSettingsType type, const content_settings::SettingInfo& info) {
    if (info.source == content_settings::SettingSource::kPolicy ||
        info.source == content_settings::SettingSource::kSupervised)
      return "Managed by your organization";
    if (info.source == content_settings::SettingSource::kExtension)
      return "Controlled by an extension";
    if (info.source != content_settings::SettingSource::kUser &&
        info.source != content_settings::SettingSource::kNone)
      return "Managed by your browser";
    if (settings->IsRestrictedToSecureOrigins(type) && !network::IsUrlPotentiallyTrustworthy(url))
      return "Requires a secure connection";
    if (!settings->CanSetNarrowestContentSetting(url, url, type))
      return "Unavailable on this page";
    return {};
  }

  void SetSitePermission(content::WebContents* active, const base::DictValue& message) {
    const auto* metadata = message.FindDict("metadata");
    const auto* id = metadata ? metadata->FindString("permission") : nullptr;
    const auto* value = message.FindString("text");
    const auto type = id ? SitePermissionType(*id) : std::nullopt;
    auto* settings = ContentSettings();
    if (!active || !type || !value || !settings) return;
    const GURL url = active->GetLastCommittedURL();
    if (!url.SchemeIsHTTPOrHTTPS() || PageURL(active) != url ||
        active->GetPrimaryMainFrame()->GetLastCommittedOrigin().opaque()) return;
    ContentSetting setting;
    if (!content_settings::ContentSettingFromString(*value, &setting)) return;
    const auto* registered = content_settings::ContentSettingsRegistry::GetInstance()->Get(*type);
    if (!registered || (setting != CONTENT_SETTING_DEFAULT && !registered->IsSettingValid(setting))) return;
    content_settings::SettingInfo info;
    settings->GetContentSetting(url, url, *type, &info);
    if (!SitePermissionRestriction(settings, url, *type, info).empty()) return;

    // Follow Chromium's own site-settings path for embargo, heuristic grants,
    // revocation reporting, and last-visit tracking. This changes only the
    // current profile's origin-specific exception, never its global default.
    auto* profile = view_->GetProfile();
    const GURL origin = active->GetPrimaryMainFrame()->GetLastCommittedOrigin().GetURL();
    permissions::PermissionUmaUtil::ScopedRevocationReporter revocation(
        profile, origin, origin, *type, permissions::PermissionSourceUI::SITE_SETTINGS);
    if (setting != CONTENT_SETTING_BLOCK)
      PermissionDecisionAutoBlockerFactory::GetForProfile(profile)->RemoveEmbargoAndResetCounts(origin, *type);
    if (setting != CONTENT_SETTING_ALLOW &&
        base::FeatureList::IsEnabled(permissions::features::kPermissionHeuristicAutoGrant))
      PermissionActionsHistoryFactory::GetForProfile(profile)->ResetHeuristicData(origin, *type);
    content_settings::ContentSettingConstraints constraints;
    if (base::FeatureList::IsEnabled(permissions::features::kSafetyHubUnusedPermissionRevocationForAllSurfaces) &&
        content_settings::CanBeAutoRevokedAsUnusedPermission(*type, setting))
      constraints.set_track_last_visit_for_autoexpiration(true);
    settings->SetContentSettingDefaultScope(origin, origin, *type, setting, constraints);
    // Every open window on this profile should reflect the saved value.
    for (auto* host : Instances())
      if (host->view_->GetProfile() == profile) host->QueueSnapshot();
  }

  // Read the same profile-scoped actions used by Chromium's Extensions menu.
  // Only serialize their icons while the Swift site-controls popover is open.
  base::DictValue SiteControlsState(content::WebContents* active) {
    base::DictValue result;
    const GURL url = PageURL(active);
    result.Set("tabId", sessions::SessionTabHelper::IdForTab(active).id());
    result.Set("url", url.spec());
    const bool web_page = url.SchemeIsHTTPOrHTTPS() && url == active->GetLastCommittedURL();
    result.Set("canManagePermissions", web_page);
    result.Set("canInspect", chrome::IsCommandEnabled(view_->browser(), IDC_DEV_TOOLS));
    base::ListValue extensions;
    std::vector<ToolbarActionViewModel*> actions;
    auto* container = ExtensionsContainer::From(*view_->browser());
    auto* model = ToolbarActionsModel::Get(view_->GetProfile());
    if (container && model) for (const auto& id : model->action_ids())
      if (auto* action = container->GetActionForId(id)) actions.push_back(action);
    std::sort(actions.begin(), actions.end(), [](auto* a, auto* b) {
      return [base::SysUTF16ToNSString(a->GetActionName())
          localizedStandardCompare:base::SysUTF16ToNSString(b->GetActionName())] == NSOrderedAscending;
    });
    for (auto* action : actions) {
      base::DictValue item;
      item.Set("id", action->GetId());
      item.Set("name", base::UTF16ToUTF8(action->GetActionName()));
      item.Set("enabled", action->IsEnabled(active));
      const auto icon = action->GetIcon(active, gfx::Size(24, 24));
      if (!icon.IsEmpty()) {
        auto png = gfx::Image(icon.Rasterize(view_->GetColorProvider())).As1xPNGBytes();
        if (png && png->size() <= 262144) item.Set("icon", base::Base64Encode(*png));
      }
      extensions.Append(std::move(item));
    }
    result.Set("extensions", std::move(extensions));
    base::ListValue permissions;
    if (auto* settings = ContentSettings(); settings && web_page) {
      for (const auto& [id, type] : std::initializer_list<std::pair<const char*, ContentSettingsType>>{
          {"clipboard", ContentSettingsType::CLIPBOARD_READ_WRITE},
          {"camera", ContentSettingsType::MEDIASTREAM_CAMERA},
          {"microphone", ContentSettingsType::MEDIASTREAM_MIC},
          {"autoPictureInPicture", ContentSettingsType::AUTO_PICTURE_IN_PICTURE}}) {
        content_settings::SettingInfo info;
        auto setting = settings->GetContentSetting(url, url, type, &info);
        const auto* registered = content_settings::ContentSettingsRegistry::GetInstance()->Get(type);
        const std::string restriction = SitePermissionRestriction(settings, url, type, info);
        const bool insecure = settings->IsRestrictedToSecureOrigins(type) && !network::IsUrlPotentiallyTrustworthy(url);
        const bool embargoed = setting == CONTENT_SETTING_ASK &&
            PermissionDecisionAutoBlockerFactory::GetForProfile(view_->GetProfile())->IsEmbargoed(url, type);
        if (insecure || embargoed) setting = CONTENT_SETTING_BLOCK;
        base::DictValue permission;
        permission.Set("id", id);
        permission.Set("setting", setting == CONTENT_SETTING_ALLOW ? "allow" :
            setting == CONTENT_SETTING_BLOCK ? "block" : setting == CONTENT_SETTING_ASK ? "ask" : "default");
        permission.Set("editable", restriction.empty() && registered);
        permission.Set("isDefault", info.primary_pattern == ContentSettingsPattern::Wildcard() &&
            info.secondary_pattern == ContentSettingsPattern::Wildcard());
        if (!restriction.empty()) permission.Set("detail", restriction);
        else if (embargoed) permission.Set("detail", "Blocked automatically");
        base::ListValue options;
        if (registered) {
          options.Append("default");
          for (const auto& [name, value] : std::initializer_list<std::pair<const char*, ContentSetting>>{
              {"ask", CONTENT_SETTING_ASK}, {"allow", CONTENT_SETTING_ALLOW}, {"block", CONTENT_SETTING_BLOCK}})
            if (registered->IsSettingValid(value)) options.Append(name);
        }
        permission.Set("options", std::move(options));
        permissions.Append(std::move(permission));
      }
    }
    result.Set("permissions", std::move(permissions));
    return result;
  }
  void PostTestPointer(double x, double y) {
    NSWindow* window = view_->GetNativeWindow().GetNativeNSWindow();
    NSEvent* event = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:NSMakePoint(x, y)
        modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
        context:nil eventNumber:0 clickCount:0 pressure:0];
    [NSApp postEvent:event atStart:NO];
  }
  static NSView* FindNativeViewForTesting(NSView* root, NSString* identifier) {
    if ([root.identifier isEqualToString:identifier]) return root;
    for (NSView* child in root.subviews) {
      if (NSView* match = FindNativeViewForTesting(child, identifier)) return match;
    }
    return nil;
  }

  static views::LabelButton* FindPopupButtonForTesting(views::View* view,
                                                       std::u16string_view text) {
    if (!view || !view->GetVisible()) return nullptr;
    if (auto* button = views::AsViewClass<views::LabelButton>(view);
        button && button->GetEnabled() && button->GetText() == text) return button;
    for (views::View* child : view->children())
      if (auto* match = FindPopupButtonForTesting(child, text)) return match;
    return nullptr;
  }

  static base::DictValue TestRequest(base::DictValue request) {
    base::DictValue result;
    if (auto* action = request.FindString("action"); action && *action != "snapshot") {
      // A surviving Little window has no sidebar window ID to address.
      if (!request.FindInt("windowId") && *action == "testPopupControl") {
        if (const auto* command = request.FindString("text")) {
          auto& windows = OwnerlessLittleWindows();
          if (!windows.empty() && windows.front()->swift)
            BarkSwiftPopupPerformControl(windows.front()->swift, command->c_str());
        }
      }
      for (auto* host : Instances()) {
        if (host->view_->browser()->GetSessionID().id() != request.FindInt("windowId").value_or(-1)) continue;
        if (*action == "testCloseWindow") chrome::CloseWindow(host->view_->browser());
        else if (*action == "testCloseTab") chrome::CloseTab(host->view_->browser());
        else if (*action == "testDetachDuringSessionRebuild") {
          auto* session = SessionServiceFactory::GetForProfileIfExisting(host->view_->GetProfile());
          if (session && session->is_saving_enabled()) {
            host->DetachTabToWindow(host->FindTab(request.FindInt("id").value_or(-1)), std::nullopt,
                base::BindOnce(&SessionServiceBase::ResetFromCurrentBrowsers, base::Unretained(session)));
          }
        }
        else if (*action == "testNewTab") {
          // Exercise the same native command as Cmd+T, including repeated presses.
          for (int i = 0; i < std::clamp(request.FindInt("count").value_or(1), 1, 20); ++i)
            chrome::ExecuteCommand(host->view_->browser(), IDC_NEW_TAB);
        }
        else if (*action == "testFocusAddress")
          chrome::ExecuteCommand(host->view_->browser(), IDC_FOCUS_LOCATION);
        else if (*action == "testRestoreLocationFocus")
          host->view_->SetFocusToLocationBar(false);
        else if (*action == "testOpenAddressSuggestion") {
          // Exercise the same panel dismissal and model route as clicking a
          // suggestion, including the focus handoff required by extension popups.
          if (const auto* suggestion = request.FindDict("suggestion")) {
            host->Snapshot();
            if (auto json = base::WriteJson(*suggestion))
              BarkSwiftSidebarOpenSuggestion(host->swift_, json->c_str());
          }
        }
        else if (*action == "testDefaultBrowserPrompt") {
          auto* manager = DefaultBrowserPromptManager::GetInstance();
          result.Set("defaultPromptShown", manager->MaybeShowPrompt());
          result.Set("defaultPromptSurfaceCreated", manager->GetPromptSurfaceManager() != nullptr);
        }
        else if (*action == "testNotificationBanner") {
          if (auto* contents = host->tabs_->GetActiveWebContents()) {
            auto* manager = infobars::ContentInfoBarManager::FromWebContents(contents);
            if (const auto* mode = request.FindString("text"); mode && *mode == "clear")
              manager->RemoveAllInfoBars(false);
            else
              DefaultBrowserInfoBarDelegate::Create(manager, host->view_->GetProfile(), false);
          }
        }
        else if (*action == "testBrowserNotice") {
          if (auto* contents = host->tabs_->GetActiveWebContents()) {
            if (auto* manager = infobars::ContentInfoBarManager::FromWebContents(contents)) {
              host->test_notice_action_.clear();
              manager->RemoveAllInfoBars(false);
              const auto* mode = request.FindString("text");
              if (!mode || *mode != "clear") {
                manager->AddInfoBar(ConfirmInfoBar::Create(
                    ConfirmInfoBarCreationAllowlist::GetPassKeyForTesting(),
                    std::make_unique<BarkNoticeTestDelegate>(
                        mode && *mode == "locked", base::BindRepeating(
                            [](base::WeakPtr<Impl> self, std::string action) {
                              if (self) self->test_notice_action_ = std::move(action);
                            }, host->weak_factory_.GetWeakPtr()))));
              }
            }
          }
        }
        else if (*action == "testAgeTab") {
          // Pretends a tab was last shown `hours` ago.
          const int index = host->FindTab(request.FindInt("id").value_or(-1));
          if (host->tabs_->ContainsIndex(index))
            host->TouchTab(host->tabs_->GetWebContentsAt(index), Now() - request.FindDouble("hours").value_or(0) * 3600);
        }
        else if (*action == "testReorderTab") {
          // A native/extension reorder outside Bark's organization command
          // stack must survive undoing an unrelated sidebar rename.
          const int from = host->FindTab(request.FindInt("id").value_or(-1));
          const int to = request.FindInt("index").value_or(-1);
          if (host->tabs_->ContainsIndex(from) && host->tabs_->ContainsIndex(to))
            host->tabs_->MoveWebContentsAt(from, to, false);
        }
        else if (*action == "testAutoArchive") host->AutoArchive();
        else if (*action == "testLittleShortcutRegistration") {
          // Exercise macOS registration without touching the real shortcut or defaults.
          const ui::Accelerator key(ui::VKEY_F19, ui::EF_CONTROL_DOWN | ui::EF_ALT_DOWN |
                                                     ui::EF_SHIFT_DOWN | ui::EF_COMMAND_DOWN);
          GlobalLittleShortcut other(key), lookup(key);
          other.Update(true, false);
          result.Set("reserved", !other.unavailable());
          lookup.Update(true, false);
          result.Set("conflict", lookup.unavailable());
          other.Update(false, false);
          lookup.Update(true, true);
          result.Set("retrySucceeded", !lookup.unavailable());
          lookup.Update(false, false);
          other.Update(true, false);
          result.Set("released", !other.unavailable());
          other.Update(false, false);
        }
        else if (*action == "testExternalLinks") {
          NSMutableArray<NSURL*>* urls = [NSMutableArray array];
          if (const auto* list = request.FindList("urls")) {
            for (const auto& value : *list) {
              if (!value.is_string()) continue;
              NSURL* url = [NSURL URLWithString:base::SysUTF8ToNSString(value.GetString())];
              if (url) [urls addObject:url];
            }
          }
          // Exercise both routing preferences without writing to the user's defaults.
          NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
          NSDictionary* arguments = [defaults volatileDomainForName:NSArgumentDomain];
          const auto little = request.FindBool("littleWindow");
          if (little) {
            NSMutableDictionary* overrides = [arguments mutableCopy];
            overrides[kLittleWindowDisabled] = @(!*little);
            [defaults setVolatileDomain:overrides forName:NSArgumentDomain];
          }
          [NSApp.delegate application:NSApp openURLs:urls];
          if (little) [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
        }
        else if (*action == "testPopupCommand" || *action == "testPopupControl") {
          const std::string* kind = request.FindString("kind");
          const std::string* command = request.FindString("text");
          for (const auto& popup : host->popups_) {
            if (!kind || !command || popup->kind != *kind) continue;
            if (*action == "testPopupCommand") {
              host->PopupCommand(popup.get(), *command);
            } else if (popup->swift) {
              const int count = std::clamp(request.FindInt("count").value_or(1), 1, 10);
              for (int n = 0; n < count; ++n) BarkSwiftPopupPerformControl(popup->swift, command->c_str());
            }
            break;
          }
        }
        else if (*action == "testLittleHeaderImage") {
          for (const auto& popup : host->popups_) {
            if (popup->kind != "little" || !popup->swift) continue;
            NSWindow* window = popup->browser->GetWindow()->GetNativeWindow().GetNativeNSWindow();
            if (auto number = request.FindInt("windowNumber"); number && window.windowNumber != *number) continue;
            NSView* header = FindNativeViewForTesting(window.contentView, @"BarkLittleHeader");
            if (!header || header.hidden) continue;
            // Draw the window's own view hierarchy so AppKit includes its
            // standard window buttons in their real positions above the header.
            NSView* frame = window.contentView;
            while (frame.superview) frame = frame.superview;
            [frame layoutSubtreeIfNeeded];
            NSView* address = FindNativeViewForTesting(header, @"BarkLittleAddress");
            if (address && !address.hidden) {
              const NSPoint center = NSMakePoint(NSMidX(address.bounds), NSMidY(address.bounds));
              NSView* hit = [frame hitTest:[address convertPoint:center toView:frame.superview]];
              result.Set("addressHit", static_cast<bool>(hit == address || [hit isDescendantOf:address]));
            }
            NSRect rect = [frame convertRect:header.bounds fromView:header];
            NSBitmapImageRep* bitmap = [frame bitmapImageRepForCachingDisplayInRect:rect];
            if (!bitmap || NSIsEmptyRect(rect)) break;
            [frame cacheDisplayInRect:rect toBitmapImageRep:bitmap];
            NSData* image = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (image.length) {
              result.Set("headerPNG", base::SysNSStringToUTF8([image base64EncodedStringWithOptions:0]));
              result.Set("headerWidth", NSWidth(rect));
              result.Set("headerHeight", NSHeight(rect));
            }
            break;
          }
        }
        else if (*action == "testLittleExtensionMenuItem") {
          const auto* text = request.FindString("text");
          for (const auto& popup : host->popups_) {
            if (!text || popup->kind != "little") continue;
            auto* view = BrowserView::GetBrowserViewForBrowser(popup->browser);
            if (!view || !view->GetWidget()) continue;
            for (views::Widget* widget : views::Widget::GetAllOwnedWidgets(view->GetWidget()->GetNativeView())) {
              if (!widget->IsVisible()) continue;
              if (auto* button = FindPopupButtonForTesting(widget->GetContentsView(), base::UTF8ToUTF16(*text))) {
                button->AcceleratorPressed(ui::Accelerator(ui::VKEY_RETURN, ui::EF_NONE));
                result.Set("pressed", true);
                break;
              }
            }
          }
        }
        else if (*action == "testActivateWindow") host->view_->browser()->GetWindow()->Activate();
        else if (*action == "testClickZoomButton") {
          NSWindow* window = host->view_->GetNativeWindow().GetNativeNSWindow();
          [[window standardWindowButton:NSWindowZoomButton] performClick:nil];
        }
        else if (*action == "testUsePrivateCopyPasteboard") {
          const std::string name = "BarkUITest.CopyLink." + base::Uuid::GenerateRandomV4().AsLowercaseString();
          BarkSwiftUseCopyPasteboardForTesting(name.c_str());
          result.Set("copyPasteboardName", name);
        }
        else if (*action == "testSidebarPointer") {
          host->PostTestPointer(request.FindDouble("x").value_or(3), request.FindDouble("y").value_or(300));
          if (auto leave = request.FindInt("leaveAfter")) {
            base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
                base::BindOnce(&Impl::PostTestPointer, host->weak_factory_.GetWeakPtr(),
                               host->width_ + 100.0, 300.0),
                base::Milliseconds(std::clamp(*leave, 1, 1000)));
          }
        }
        else if (*action == "testExtensionsMenu") {
          NSMenu* menu = InstallExtensionsMenu();
          [menu.delegate menuNeedsUpdate:menu];
          if (const auto* id = request.FindString("text")) {
            for (NSInteger i = 0; i < menu.numberOfItems; ++i) {
              NSMenuItem* item = [menu itemAtIndex:i];
              if ([item.representedObject isKindOfClass:NSDictionary.class] &&
                  [item.representedObject[@"action"] isEqualToString:base::SysUTF8ToNSString(*id)] && item.enabled) {
                [menu performActionForItemAtIndex:i];
                break;
              }
            }
          }
        }
        else if (auto json = base::WriteJson(request)) host->Command(*json);
        break;
      }
    }
    base::ListValue windows;
    for (auto* host : Instances()) {
      if (!host->tabs_ || host->tabs_->closing_all() || host->view_->browser()->IsDeleteScheduled()) continue;
      auto state = host->MakeSnapshot();
      if (const auto* action = request.FindString("action"); action && *action == "testCommandSuggestions")
        state.Set("commandSuggestions", host->CommandSuggestions(request.FindString("text") ? *request.FindString("text") : ""));
      if (const auto* action = request.FindString("action"); action && *action == "testOpenTabSuggestions") {
        const auto* query = request.FindString("text");
        state.Set("openTabSuggestions", host->MatchOpenTabs(query ? *query : ""));
      }
      state.Set("windowId", host->view_->browser()->GetSessionID().id());
      state.Set("lastNoticeAction", host->test_notice_action_);
      state.Set("windowGroup", host->group_->id);
      state.Set("visible", host->view_->browser()->GetWindow()->IsVisible());
      state.Set("addressPanelVisible", BarkSwiftSidebarAddressVisible(host->swift_));
      base::DictValue presentation;
      presentation.Set("sidebarVisible", host->host_->GetVisible());
      presentation.Set("headerVisible", host->header_host_->GetVisible());
      presentation.Set("resizeVisible", host->resize_host_->GetVisible());
      presentation.Set("resizeX", host->resize_host_->x());
      presentation.Set("resizeWidth", host->resize_host_->width());
      presentation.Set("backdropVisible", host->backdrop_host_->GetVisible());
      presentation.Set("backdropX", host->backdrop_host_->x());
      presentation.Set("backdropY", host->backdrop_host_->y());
      presentation.Set("backdropHeight", host->backdrop_host_->height());
      presentation.Set("sidebarHeight", host->host_->height());
      presentation.Set("sidebarY", host->host_->y());
      presentation.Set("panelInset", host->collapsed_ ? kFloatingInset : 0);
      presentation.Set("shadowMargin", host->collapsed_ ? kShadowMargin : 0);
      presentation.Set("progress", host->sidebar_progress_);
      presentation.Set("backdropOpacity", static_cast<double>(((__bridge NSView*)host->backdrop_swift_).alphaValue));
      presentation.Set("edgeVisible", host->edge_host_->GetVisible());
      presentation.Set("pageFrameVisible", host->page_frame_host_->GetVisible());
      const auto page_area = host->view_->contents_container()->GetBoundsInScreen();
      base::DictValue page_area_value;
      page_area_value.Set("x", page_area.x()); page_area_value.Set("y", page_area.y());
      page_area_value.Set("width", page_area.width()); page_area_value.Set("height", page_area.height());
      presentation.Set("pageAreaBounds", std::move(page_area_value));
      presentation.Set("opacity", static_cast<double>(((__bridge NSView*)host->swift_).alphaValue));
      presentation.Set("headerOpacity", static_cast<double>(((__bridge NSView*)host->header_swift_).alphaValue));
      presentation.Set("edgeOpacity", static_cast<double>(host->edge_hint_.alphaValue));
      presentation.Set("animating", host->sidebar_motion_timer_.IsRunning());
      presentation.Set("sidebarX", host->host_->x());
      presentation.Set("reduceMotion", static_cast<bool>(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion));
      NSWindow* native_window = host->view_->GetNativeWindow().GetNativeNSWindow();
      presentation.Set("keyWindow", static_cast<bool>(native_window.isKeyWindow));
      presentation.Set("windowFullscreen", (native_window.styleMask & NSWindowStyleMaskFullScreen) != 0);
      auto* tab_strip = host->view_->horizontal_tab_strip_region_view_for_testing();
      presentation.Set("chromiumTabStripVisible", tab_strip && !tab_strip->GetVisibleBounds().IsEmpty());
      presentation.Set("chromiumToolbarVisible", host->view_->IsToolbarVisible());
      if (auto* banners = host->view_->infobar_container()) {
        presentation.Set("notificationBannerPresent", !banners->IsEmpty());
        presentation.Set("notificationBannerVisible", banners->GetVisible());
        presentation.Set("notificationBannerHeight", banners->height());
      }
      base::ListValue lights;
      for (NSWindowButton type : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
        NSButton* button = [native_window standardWindowButton:type];
        base::DictValue light;
        light.Set("hidden", static_cast<bool>(button.hidden));
        light.Set("opacity", static_cast<double>(button.alphaValue));
        light.Set("x", static_cast<double>(button.frame.origin.x));
        light.Set("y", static_cast<double>(button.frame.origin.y));
        lights.Append(std::move(light));
      }
      presentation.Set("trafficLights", std::move(lights));
      state.Set("sidebarPresentation", std::move(presentation));
      if (auto* session = SessionServiceFactory::GetForProfileIfExisting(host->view_->GetProfile()))
        state.Set("sessionSaving", session->is_saving_enabled());
      auto bounds = host->view_->browser()->GetWindow()->GetBounds();
      base::DictValue rectangle;
      rectangle.Set("x", bounds.x()); rectangle.Set("y", bounds.y());
      rectangle.Set("width", bounds.width()); rectangle.Set("height", bounds.height());
      state.Set("bounds", std::move(rectangle));
      base::ListValue all_tabs;
      for (int i = 0; i < host->tabs_->count(); ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        base::DictValue tab;
        tab.Set("id", sessions::SessionTabHelper::IdForTab(contents).id());
        tab.Set("space", GetTabSpace(contents));
        tab.Set("url", contents->GetVisibleURL().spec());
        tab.Set("pinned", host->tabs_->IsTabPinned(i));
        tab.Set("needsReload", contents->GetController().NeedsReload());
        tab.Set("discarded", contents->WasDiscarded());
        tab.Set("hasLiveRenderer", contents->GetPrimaryMainFrame()->IsRenderFrameLive());
        tab.Set("visible", contents->GetVisibility() == content::Visibility::VISIBLE);
        if (auto meta = ReadTabMeta(contents); !meta.empty()) tab.Set("meta", std::move(meta));
        const auto page_bounds = contents->GetContainerBounds();
        base::DictValue content_bounds;
        content_bounds.Set("x", page_bounds.x()); content_bounds.Set("y", page_bounds.y());
        content_bounds.Set("width", page_bounds.width()); content_bounds.Set("height", page_bounds.height());
        tab.Set("contentBounds", std::move(content_bounds));
        if (auto* pane = host->view_->GetContentsContainerViewFor(contents)) {
          const auto corners = pane->contents_view()->holder()->GetNativeViewCornerRadii();
          tab.Set("nativeCornerRadius", static_cast<double>(corners.upper_left()));
        }
        if (auto split = host->tabs_->GetSplitForTab(i)) {
          const auto layout = host->tabs_->GetSplitData(*split)->visual_data()->split_layout();
          tab.Set("splitLayout", layout == split_tabs::SplitTabLayout::kStacked ? "stacked" : "sideBySide");
        }
        if (auto* helper = sessions::SessionTabHelper::FromWebContents(contents))
          tab.Set("sessionWindow", helper->window_id().id());
        all_tabs.Append(std::move(tab));
      }
      state.Set("allTabs", std::move(all_tabs));
      state.Set("switcher", host->SwitcherTabs());
      base::ListValue popups;
      for (auto& popup : host->popups_) {
        base::DictValue value;
        value.Set("kind", popup->kind);
        NSWindow* popup_window = popup->browser->GetWindow()->GetNativeWindow().GetNativeNSWindow();
        value.Set("keyWindow", static_cast<bool>(popup_window.isKeyWindow));
        value.Set("hasControls", popup->swift != nullptr);
        value.Set("addressEditor", popup->swift && BarkSwiftPopupAddressVisible(popup->swift));
        auto* popup_view = BrowserView::GetBrowserViewForBrowser(popup->browser);
        value.Set("chromiumToolbarVisible", popup_view && popup_view->IsToolbarVisible());
        if (popup->kind == "little") {
          value.Set("defaultSpace", popup->space);
          value.Set("windowNumber", static_cast<int>(popup_window.windowNumber));
          auto* address = base::apple::ObjCCast<NSButton>(
              FindNativeViewForTesting(popup_window.contentView, @"BarkLittleAddress"));
          if (address) value.Set("site", base::SysNSStringToUTF8(address.title));
        }
        value.Set("canSplit", host->CanSplitPopup(popup.get()));
        if (auto* model = popup->browser->GetTabStripModel(); model && !model->empty()) {
          auto* page = model->GetWebContentsAt(0);
          value.Set("url", page->GetVisibleURL().spec());
          const auto page_bounds = page->GetContainerBounds();
          base::DictValue content_bounds;
          content_bounds.Set("x", page_bounds.x()); content_bounds.Set("y", page_bounds.y());
          content_bounds.Set("width", page_bounds.width()); content_bounds.Set("height", page_bounds.height());
          value.Set("contentBounds", std::move(content_bounds));
        }
        const auto popup_bounds = popup->browser->GetWindow()->GetBounds();
        base::DictValue frame;
        frame.Set("x", popup_bounds.x()); frame.Set("y", popup_bounds.y());
        frame.Set("width", popup_bounds.width()); frame.Set("height", popup_bounds.height());
        value.Set("bounds", std::move(frame));
        popups.Append(std::move(value));
      }
      state.Set("popups", std::move(popups));
      if (!host->IsPrivate()) {
        if (auto* settings = host->ContentSettings())
          state.Set("autoPictureInPictureDefault",
                    settings->GetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE) ==
                        CONTENT_SETTING_ALLOW ? "allow" : "other");
        state.Set("autoPictureInPictureFeature", base::FeatureList::IsEnabled(
            blink::features::kBrowserInitiatedAutomaticPictureInPicture));
      }
      windows.Append(std::move(state));
    }
    result.Set("windows", std::move(windows));
    if (const auto* action = request.FindString("action"); action && *action == "testExtensionsMenu") {
      NSMenu* menu = InstallExtensionsMenu();
      base::DictValue state;
      state.Set("title", base::SysNSStringToUTF8(menu.title));
      base::ListValue items;
      for (NSMenuItem* item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        base::DictValue value;
        value.Set("title", base::SysNSStringToUTF8(item.title));
        value.Set("enabled", static_cast<bool>(item.enabled));
        value.Set("action", base::SysNSStringToUTF8(item.representedObject[@"action"]));
        items.Append(std::move(value));
      }
      state.Set("items", std::move(items));
      result.Set("extensionsMenu", std::move(state));
    }
    return result;
  }
  bool IsPrivate() const { return view_->GetProfile()->IsOffTheRecord(); }
  // chrome://spaces moves a space through the window the user is looking at,
  // so the space's tabs there reopen in the new profile.
  static bool MoveFromSettings(const std::string& space, const std::string& profile) {
    Impl* chosen = nullptr;
    int best = -1;
    for (auto* host : Instances()) {
      if (host->IsPrivate() || !host->tabs_ || host->tabs_->closing_all() ||
          host->view_->browser()->IsDeleteScheduled() || host->ProfilePath(profile).empty()) continue;
      auto* widget = host->view_->GetWidget();
      const int rank = widget && widget->IsActive() ? 2 : host->view_->browser()->GetWindow()->IsVisible() ? 1 : 0;
      if (rank > best) { best = rank; chosen = host; }
    }
    if (!chosen) return false;
    chosen->MoveSpaceToProfile(space, profile);
    return true;
  }
  std::string ProfileKey() const { return view_->GetProfile()->GetPath().BaseName().AsUTF8Unsafe(); }
  base::FilePath ProfilePath(const std::string& key) const {
    for (auto* entry : profiles_->GetAllProfilesAttributes()) {
      if (!entry->IsOmitted() && entry->GetPath().BaseName().AsUTF8Unsafe() == key) return entry->GetPath();
    }
    return {};
  }
  bool SpaceBelongsHere(const std::string& id) const {
    auto* space = catalog_.Find(id);
    return space && space->FindString("profile") && *space->FindString("profile") == ProfileKey();
  }
  std::string VisibleSpaceExcept(const std::string& excluded) const {
    for (const auto& value : catalog_.List()) {
      const auto* space = value.GetIfDict();
      const auto* id = space ? space->FindString("id") : nullptr;
      const auto* profile = space ? space->FindString("profile") : nullptr;
      if (id && *id != excluded && !catalog_.IsHidden(*id) && profile && !ProfilePath(*profile).empty()) return *id;
    }
    return {};
  }
  void EnsureProfileSpaces() {
    if (IsPrivate() || IsBarkImportInProgress()) return;
    EnsureProfileSpaces(catalog_, *profiles_);
  }
  static void EnsureProfileSpaces(SpaceCatalog& catalog, ProfileAttributesStorage& profiles) {
    for (auto* entry : profiles.GetAllProfilesAttributesSortedForDisplay()) {
      std::string key = entry->GetPath().BaseName().AsUTF8Unsafe();
      if (entry->IsOmitted() || !catalog.FirstForProfile(key).empty()) continue;
      NSString* prefix = base::SysUTF8ToNSString("BarkChromium." + entry->GetPath().AsUTF8Unsafe());
      NSString* theme = [[NSUserDefaults standardUserDefaults] stringForKey:[prefix stringByAppendingString:@".theme"]];
      NSString* emoji = [[NSUserDefaults standardUserDefaults] stringForKey:[prefix stringByAppendingString:@".emoji"]];
      std::string name = base::UTF16ToUTF8(entry->GetName());
      if (name == "Your Chromium" || name == "Your Bark") name = "Personal";
      // No icon by default; the sidebar draws a dot for a space without one.
      NSString* default_icon = key == "Default" && name == "Personal" ? @"👤" : @"";
      catalog.Create(name, key, base::SysNSStringToUTF8(theme ?: @"gray"), base::SysNSStringToUTF8(emoji ?: default_icon));
    }
    catalog.MigratePersonalIcon();
  }
  void AssignTab(content::WebContents* contents, const std::string& space) {
    if (IsPrivate() || !SpaceBelongsHere(space)) return;
    SetTabSpace(contents, space);
    PersistTab(contents);
  }
  void PersistTab(content::WebContents* contents) {
    SetTabWindowGroup(contents, group_->id);
    if (auto* session = SessionServiceFactory::GetForProfile(view_->GetProfile())) {
      auto* helper = sessions::SessionTabHelper::FromWebContents(contents);
      if (helper) {
        session->AddTabExtraData(view_->browser()->GetSessionID(), helper->session_id(), kTabSpaceKey, GetTabSpace(contents));
        session->AddTabExtraData(view_->browser()->GetSessionID(), helper->session_id(), kTabWindowGroupKey, group_->id);
        const std::string meta = GetTabMeta(contents);
        if (!meta.empty())
          session->AddTabExtraData(view_->browser()->GetSessionID(), helper->session_id(), kTabMetaKey, meta);
      }
    }
  }

  // MARK: Tab metadata

  // Applies `edit` to a tab's Bark metadata; saves it if `edit` returns true.
  // Private tabs keep none.
  bool EditTabMeta(content::WebContents* contents, base::FunctionRef<bool(base::DictValue&)> edit) {
    if (!contents || IsPrivate() || GetTabSpace(contents).empty()) return false;
    auto meta = ReadTabMeta(contents);
    if (!edit(meta)) return false;
    auto json = base::WriteJson(meta);
    if (!json || json->size() > kMaxTabMetaBytes) return false;
    SetTabMeta(contents, meta.empty() ? std::string() : *json);
    if (auto* session = SessionServiceFactory::GetForProfileIfExisting(view_->GetProfile())) {
      if (auto* helper = sessions::SessionTabHelper::FromWebContents(contents))
        session->AddTabExtraData(view_->browser()->GetSessionID(), helper->session_id(), kTabMetaKey,
                                 meta.empty() ? std::string() : *json);
    }
    return true;
  }
  void TouchTab(content::WebContents* contents, double when = Now()) {
    EditTabMeta(contents, [when](base::DictValue& meta) {
      // Seconds are enough; skip writes for repeated activations.
      if (const auto seen = meta.FindDouble("lastActive"); seen && std::abs(*seen - when) < 1) return false;
      meta.Set("lastActive", std::floor(when));
      return true;
    });
  }
  // Pins made before Bark remembered URLs, or pinned on a blank page, take
  // the first real page they show.
  void RememberPinnedPage(content::WebContents* contents, bool refresh) {
    const GURL url = PageURL(contents);
    if (IsBlankPage(url)) return;
    EditTabMeta(contents, [&](base::DictValue& meta) {
      const bool new_pin = !meta.FindString("pinnedURL");
      if (new_pin) meta.Set("pinnedURL", url.spec());
      if (!new_pin && !refresh && CachedPinPage(meta, url)) return false;
      auto* entry = contents->GetController().GetLastCommittedEntry();
      if (!entry || entry->GetPageType() == content::PAGE_TYPE_ERROR ||
          !entry->GetVirtualURL().EqualsIgnoringRef(url))
        return new_pin;

      // Keep the home page when a pin navigates away. Closing the session
      // returns to it, even when its navigation entry has lost its favicon.
      const bool home = url.EqualsIgnoringRef(GURL(*meta.FindString("pinnedURL")));
      const char* key = home ? "pinPage" : "visitedPage";
      const auto* saved = CachedPinPage(meta, url);
      base::DictValue page = saved ? saved->Clone() : base::DictValue();
      // A restored entry can receive older, URL-wide data from history.
      // Only a live page replaces what this particular pin last displayed.
      const bool dormant = IsDormantPin(contents);
      if (!entry->GetTitle().empty() && (!dormant || !page.contains("title"))) {
        const auto title = base::UTF16ToUTF8(entry->GetTitle());
        page.Set("title", base::TruncateUTF8ToByteSize(title, 4096));
      }
      if (!dormant || !page.contains("favicon")) {
        auto icon = FaviconPNG(entry, 4096);
        if (!icon.empty()) page.Set("favicon", std::move(icon));
      }
      if (page.empty()) return new_pin;
      page.Set("url", url.spec());
      const bool cleared = home && meta.Remove("visitedPage");
      const auto* previous = meta.FindDict(key);
      if (previous && *previous == page) return new_pin || cleared;
      meta.Set(key, std::move(page));
      return true;
    });
  }
  // A history result may arrive after a pin has opened, moved, or been removed.
  static content::NavigationEntry* DormantEntryForURL(content::WebContents* contents,
                                                       const GURL& url) {
    if (!contents || !IsDormantPin(contents)) return nullptr;
    auto* tab = tabs::TabInterface::MaybeGetFromContents(contents);
    if (!tab || !tab->IsPinned()) return nullptr;
    auto* entry = contents->GetController().GetLastCommittedEntry();
    return entry && entry->GetVirtualURL() == url ? entry : nullptr;
  }

  // Older profiles saved only the URL. Look up missing fields in this
  // profile's local history once, without starting a navigation.
  void BackfillPinnedPage(content::WebContents* contents) {
    if (contents->GetUserData(kCheckedPinHistory) || !IsDormantPin(contents)) return;
    auto* entry = contents->GetController().GetLastCommittedEntry();
    if (!entry || IsBlankPage(entry->GetVirtualURL())) return;
    contents->SetUserData(kCheckedPinHistory, std::make_unique<base::SupportsUserData::Data>());
    const GURL url = entry->GetVirtualURL();
    const auto meta = ReadTabMeta(contents);
    const auto* page = CachedPinPage(meta, url);
    auto* profile = view_->GetProfile();
    if (entry->GetTitle().empty() && !(page && page->FindString("title"))) {
      if (auto* service = HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::IMPLICIT_ACCESS)) {
        service->QueryURL(url, base::BindOnce([](base::WeakPtr<content::WebContents> tab,
            const GURL& url, history::QueryURLResult result) {
          auto* entry = DormantEntryForURL(tab.get(), url);
          if (entry && entry->GetTitle().empty() && result.success && !result.row.title().empty())
            tab->UpdateTitleForEntry(entry, result.row.title());
        }, contents->GetWeakPtr(), url), &pin_history_tasks_);
      }
    }
    if (!entry->GetFavicon().valid && !(page && page->FindString("favicon"))) {
      if (auto* favicons = FaviconServiceFactory::GetForProfile(profile, ServiceAccessType::IMPLICIT_ACCESS)) {
        favicons->GetFaviconImageForPageURL(url, base::BindOnce([](base::WeakPtr<content::WebContents> tab,
            const GURL& url, const favicon_base::FaviconImageResult& result) {
          auto* entry = DormantEntryForURL(tab.get(), url);
          if (!entry || entry->GetFavicon().valid || result.image.IsEmpty()) return;
          auto& icon = entry->GetFavicon();
          icon.valid = true;
          icon.url = result.icon_url;
          icon.image = result.image;
          tab->NotifyNavigationStateChanged(content::INVALIDATE_TYPE_TAB);
        }, contents->GetWeakPtr(), url), &pin_history_tasks_);
      }
    }
  }

  // A pinned tab that navigated away from the page it was pinned on.
  static bool Drifted(content::WebContents* contents, const base::DictValue& meta) {
    const auto* pinned = meta.FindString("pinnedURL");
    if (!pinned) return false;
    GURL saved(*pinned);
    GURL::Replacements clear;
    clear.ClearRef();
    const GURL current = PageURL(contents);
    return saved.is_valid() && !IsBlankPage(current) && saved.ReplaceComponents(clear) != current;
  }
  base::ListValue Folders(const std::string& space) const {
    const auto* entry = catalog_.Find(space);
    const auto* folders = entry ? entry->FindList("folders") : nullptr;
    return folders ? folders->Clone() : base::ListValue();
  }
  bool HasFolder(const std::string& space, const std::string& folder) const {
    for (const auto& value : Folders(space))
      if (value.is_dict() && value.GetDict().FindString("id") && *value.GetDict().FindString("id") == folder) return true;
    return false;
  }
  // Edits the active space's folder list in place.
  void EditFolders(base::FunctionRef<void(base::ListValue&)> edit) {
    if (IsPrivate()) return;
    auto folders = Folders(active_space_);
    edit(folders);
    catalog_.SetField(active_space_, "folders",
                      folders.empty() ? base::Value() : base::Value(std::move(folders)));
  }
  // Puts a tab in a folder of the active space (pinning it), or takes it
  // out of its folder when `folder` is empty.
  void MoveTabToFolder(int index, const std::string& folder) {
    if (IsPrivate() || !tabs_->ContainsIndex(index)) return;
    auto* contents = tabs_->GetWebContentsAt(index);
    if (!folder.empty() && !HasFolder(active_space_, folder)) return;
    if (IsFavorite(contents)) AssignTab(contents, active_space_);
    if (!InActiveSpace(index)) return;
    if (!folder.empty() && !tabs_->IsTabPinned(index)) {
      index = tabs_->SetTabPinned(index, true);
      contents = tabs_->GetWebContentsAt(index);
    }
    EditTabMeta(contents, [&](base::DictValue& meta) {
      if (folder.empty()) return meta.Remove("folder");
      meta.Set("folder", folder);
      return true;
    });
  }

  // Organization history only stores tab identity and sidebar metadata. Page
  // URLs, history, loading state, selection and closed WebContents are never
  // restored by Undo.
  struct OrganizationUndo {
    std::string space;
    std::string label;
    int target;
    bool target_moved;
    base::DictValue before;
    base::DictValue after;
  };

  base::DictValue TabOrganization(content::WebContents* contents, int index) const {
    base::DictValue result;
    result.Set("id", sessions::SessionTabHelper::IdForTab(contents).id());
    result.Set("space", GetTabSpace(contents));
    result.Set("pinned", tabs_->IsTabPinned(index));
    const auto meta = ReadTabMeta(contents);
    for (const char* key : {"title", "folder", "pinnedURL"})
      if (const auto* value = meta.Find(key)) result.Set(key, value->Clone());
    return result;
  }

  base::DictValue OrganizationState() const {
    base::DictValue state;
    base::ListValue tabs;
    for (int i = 0; i < tabs_->count(); ++i) tabs.Append(TabOrganization(tabs_->GetWebContentsAt(i), i));
    state.Set("tabs", std::move(tabs));
    state.Set("folders", Folders(active_space_));
    const auto* space = catalog_.Find(active_space_);
    state.Set("pinsCollapsed", space && space->FindBool("pinsCollapsed").value_or(false));
    return state;
  }

  static const base::DictValue* OrganizedTab(const base::DictValue& state, int id) {
    const auto* tabs = state.FindList("tabs");
    if (tabs) for (const auto& value : *tabs)
      if (value.GetDict().FindInt("id") == id) return &value.GetDict();
    return nullptr;
  }

  static std::string OrganizationLabel(const std::string& action) {
    if (action == "pin") return "Pin Change";
    if (action == "moveTab" || action == "moveTabToSpace" || action == "moveToFolder") return "Move Tab";
    if (action == "renameTab") return "Rename Tab";
    if (action == "setPinURL") return "Change Pinned Page";
    if (action == "newFolder") return "New Folder";
    if (action == "renameFolder") return "Rename Folder";
    if (action == "deleteFolder") return "Delete Folder";
    if (action == "moveFolder") return "Move Folder";
    if (action == "toggleFolder" || action == "togglePinnedSection") return "Collapse Change";
    return {};
  }

  void RememberOrganization(std::string space, std::string label, int target, base::DictValue before) {
    if (IsPrivate() || space != active_space_ || !tabs_ || tabs_->closing_all() || group_->closing) return;
    auto after = OrganizationState();
    if (before == after) return;
    if (organization_undo_.size() >= 32) organization_undo_.erase(organization_undo_.begin());
    const auto target_position = [target](const base::DictValue& state) {
      const auto& ordered = *state.FindList("tabs");
      for (size_t i = 0; i < ordered.size(); ++i)
        if (ordered[i].GetDict().FindInt("id") == target) return i;
      return ordered.size();
    };
    const bool target_moved = target >= 0 && target_position(before) != target_position(after);
    organization_undo_.push_back({std::move(space), std::move(label), target, target_moved,
                                  std::move(before), std::move(after)});
    QueueSnapshot();
  }

  void UndoOrganization() {
    if (IsPrivate() || organization_undo_.empty() || organization_undo_.back().space != active_space_) return;
    auto undo = std::move(organization_undo_.back());
    organization_undo_.pop_back();
    const auto current = OrganizationState();
    // Preserve folder edits made in another window after this operation.
    bool folders_restored = *undo.before.Find("folders") == *undo.after.Find("folders");
    if (current.Find("folders") && undo.after.Find("folders") &&
        *current.Find("folders") == *undo.after.Find("folders")) {
      const auto* folders = undo.before.FindList("folders");
      catalog_.SetField(active_space_, "folders", folders && !folders->empty()
          ? base::Value(folders->Clone()) : base::Value());
      folders_restored = true;
    }
    if (*current.Find("pinsCollapsed") == *undo.after.Find("pinsCollapsed"))
      catalog_.SetField(active_space_, "pinsCollapsed", undo.before.Find("pinsCollapsed")->Clone());
    const auto* old_tabs = undo.before.FindList("tabs");
    if (!old_tabs) return;
    for (const auto& value : *old_tabs) {
      const auto& before = value.GetDict();
      const int id = before.FindInt("id").value_or(-1);
      const auto* after = OrganizedTab(undo.after, id);
      if (!after || before == *after) continue;
      int index = FindTab(id);
      if (!tabs_->ContainsIndex(index)) continue;  // Closed or detached: never resurrect.
      auto* contents = tabs_->GetWebContentsAt(index);
      if (TabOrganization(contents, index) != *after) continue;
      const auto* space = before.FindString("space");
      if (!space || (*space != kFavoritesSpace && !SpaceBelongsHere(*space))) continue;
      SetTabSpace(contents, *space);
      const bool pinned = before.FindBool("pinned").value_or(false);
      if (tabs_->IsTabPinned(index) != pinned) index = tabs_->SetTabPinned(index, pinned);
      EditTabMeta(contents, [&](base::DictValue& meta) {
        for (const char* key : {"title", "folder", "pinnedURL"}) {
          const auto* saved = before.Find(key);
          if (std::string_view(key) == "folder" && saved &&
              (!folders_restored || !saved->is_string() || !HasFolder(*space, saved->GetString()))) continue;
          if (saved) meta.Set(key, saved->Clone());
          else meta.Remove(key);
        }
        return true;
      });
      PersistTab(contents);
    }
    // Restore the moved tab's relative position using surviving neighbors.
    // Newly opened tabs keep their mutual order; unrelated split pairs stay intact.
    int target = FindTab(undo.target);
    const auto* saved = OrganizedTab(undo.before, undo.target);
    if (undo.target_moved && saved && tabs_->ContainsIndex(target) && !tabs_->GetSplitForTab(target)) {
      auto* contents = tabs_->GetWebContentsAt(target);
      if (TabOrganization(contents, target) == *saved) {
        bool passed = false;
        int preceding = -1, following = -1;
        for (const auto& value : *old_tabs) {
          const auto& candidate = value.GetDict();
          const int id = candidate.FindInt("id").value_or(-1);
          if (id == undo.target) { passed = true; continue; }
          const int index = FindTab(id);
          if (!tabs_->ContainsIndex(index) || tabs_->GetSplitForTab(index) ||
              GetTabSpace(tabs_->GetWebContentsAt(index)) != GetTabSpace(contents) ||
              tabs_->IsTabPinned(index) != tabs_->IsTabPinned(target)) continue;
          if (passed) { following = index; break; }
          preceding = index;
        }
        const int destination = following >= 0 ? following - (target < following ? 1 : 0)
            : preceding >= 0 ? preceding + (target > preceding ? 1 : 0) : target;
        if (destination != target) tabs_->MoveWebContentsAt(target, destination, false);
      }
    }
    QueueGroupSnapshot();
  }

  // MARK: Automatic archiving

  // Closes unpinned tabs not shown for the chosen time into their space's
  // archive. The tab on screen, its split partner and tabs playing sound
  // stay open.
  void AutoArchive() {
    if (IsPrivate() || !tabs_ || tabs_->closing_all() || group_->closing || group_->restoring) return;
    const int hours = ArchiveAfterHours();
    if (hours <= 0) return;
    const double now = Now();
    const int active = tabs_->active_index();
    const auto active_split = tabs_->ContainsIndex(active) ? tabs_->GetSplitForTab(active) : std::nullopt;
    std::map<std::string, base::ListValue> archived;
    std::vector<base::WeakPtr<content::WebContents>> closing;
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      if (i == active || tabs_->IsTabPinned(i) || IsFavorite(contents)) continue;
      if (active_split && tabs_->GetSplitForTab(i) == active_split) continue;
      const std::string space = GetTabSpace(contents);
      if (!SpaceBelongsHere(space)) continue;
      if (auto* audio = RecentlyAudibleHelper::FromWebContents(contents); audio && audio->WasRecentlyAudible()) continue;
      const auto seen = ReadTabMeta(contents).FindDouble("lastActive");
      if (!seen) {  // Restored from before Bark kept the time: start counting now.
        TouchTab(contents, now);
        continue;
      }
      if (now - *seen < hours * 3600.0) continue;
      const GURL url = PageURL(contents);
      if (!IsBlankPage(url)) {
        base::DictValue tab;
        tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
        tab.Set("url", url.spec());
        archived[space].Append(std::move(tab));
      }
      closing.push_back(contents->GetWeakPtr());
    }
    if (closing.empty()) return;
    for (auto& [space, tabs] : archived) catalog_.Archive(space, std::move(tabs));
    for (auto& contents : closing) {
      const int index = contents ? tabs_->GetIndexOfWebContents(contents.get()) : TabStripModel::kNoTab;
      if (index != TabStripModel::kNoTab) tabs_->CloseWebContentsAt(index, TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    }
    QueueGroupSnapshot();
  }

  // MARK: Recent tabs (Control-Tab)

  // This space's tabs and the Favorites, most recently shown first, with the
  // page thumbnails Chromium keeps for tab hover cards.
  base::ListValue SwitcherTabs() {
    std::vector<int> order = recent_tabs_;
    for (int i = 0; i < tabs_->count(); ++i) {
      const int id = sessions::SessionTabHelper::IdForTab(tabs_->GetWebContentsAt(i)).id();
      if (std::ranges::find(order, id) == order.end()) order.push_back(id);
    }
    base::ListValue items;
    for (int id : order) {
      const int i = FindTab(id);
      if (!tabs_->ContainsIndex(i)) continue;
      auto* contents = tabs_->GetWebContentsAt(i);
      if ((!InActiveSpace(i) && !IsFavorite(contents)) || IsBlankPlaceholder(i)) continue;
      auto tab = TabValue(i, tabs_->active_index() == i);
      if (auto* interface = tabs::TabInterface::MaybeGetFromContents(contents)) {
        if (auto* helper = ThumbnailTabHelper::From(interface)) {
          if (auto thumbnail = helper->thumbnail(); thumbnail && thumbnail->has_data()) {
            const auto data = thumbnail->data();
            if (data && data->data.size() <= 512 * 1024) tab.Set("thumbnail", base::Base64Encode(data->data));
          }
        }
      }
      items.Append(std::move(tab));
      if (items.size() >= 12) break;
    }
    return items;
  }
  void SendSwitcher() {
    base::DictValue state;
    state.Set("tabs", SwitcherTabs());
    if (auto json = base::WriteJson(state)) BarkSwiftSidebarSwitcher(swift_, json->c_str());
  }

  // MARK: Media

  // The tab playing (or paused in) media that is not on screen, for the
  // sidebar's player. A playing tab wins over a paused one.
  base::DictValue MediaState() {
    const int active = tabs_->active_index();
    const auto active_split = tabs_->ContainsIndex(active) ? tabs_->GetSplitForTab(active) : std::nullopt;
    int best = -1;
    bool best_playing = false;
    for (int i = 0; i < tabs_->count(); ++i) {
      if (i == active || (active_split && tabs_->GetSplitForTab(i) == active_split)) continue;
      auto* contents = tabs_->GetWebContentsAt(i);
      auto* session = content::MediaSession::GetIfExists(contents);
      if (!session) continue;
      const auto info = session->GetMediaSessionInfoSync();
      if (!info || !info->is_controllable) continue;
      const bool playing = info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying;
      const bool paused = info->state == media_session::mojom::MediaSessionInfo::SessionState::kSuspended;
      if (!playing && !paused) continue;
      const int id = sessions::SessionTabHelper::IdForTab(contents).id();
      if (best < 0 || (playing && !best_playing) || (playing == best_playing && id == media_tab_)) {
        best = i;
        best_playing = playing;
      }
    }
    base::DictValue media;
    if (best < 0) { media_tab_ = -1; return media; }
    auto* contents = tabs_->GetWebContentsAt(best);
    media_tab_ = sessions::SessionTabHelper::IdForTab(contents).id();
    media = TabValue(best, false);
    media.Set("playing", best_playing);
    if (auto* session = content::MediaSession::GetIfExists(contents)) {
      const auto& metadata = session->GetMediaSessionMetadata();
      if (!metadata.title.empty()) media.Set("mediaTitle", base::UTF16ToUTF8(metadata.title));
      if (!metadata.artist.empty()) media.Set("artist", base::UTF16ToUTF8(metadata.artist));
    }
    media.Set("space", GetTabSpace(contents));
    return media;
  }
  void ToggleMedia(int index) {
    if (!tabs_->ContainsIndex(index)) return;
    auto* session = content::MediaSession::GetIfExists(tabs_->GetWebContentsAt(index));
    if (!session) return;
    const auto info = session->GetMediaSessionInfoSync();
    if (info && info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying)
      session->Suspend(content::MediaSession::SuspendType::kUI);
    else
      session->Resume(content::MediaSession::SuspendType::kUI);
    // Playback state settles after the page answers.
    for (int delay : {250, 1200})
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
          base::BindOnce(&Impl::QueueSnapshot, weak_factory_.GetWeakPtr()), base::Milliseconds(delay));
  }

  // MARK: Picture in picture

  HostContentSettingsMap* ContentSettings() const {
    return HostContentSettingsMapFactory::GetForProfile(view_->GetProfile());
  }
  // Bark allows automatic picture-in-picture by default, once per profile, so
  // a later choice in Chromium's site settings is kept.
  void DefaultAutoPictureInPicture() {
    NSString* key = [@"BarkChromium.AutoPiPDefaulted." stringByAppendingString:
        base::SysUTF8ToNSString(view_->GetProfile()->GetPath().AsUTF8Unsafe())];
    if ([NSUserDefaults.standardUserDefaults boolForKey:key]) return;
    if (auto* settings = ContentSettings())
      settings->SetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE, CONTENT_SETTING_ALLOW);
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:key];
  }
  bool AutoPictureInPictureAllowed() const {
    auto* settings = ContentSettings();
    return settings && settings->GetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE) ==
        CONTENT_SETTING_ALLOW;
  }

  // MARK: Peek and Little windows

  // A Chromium popup window with Bark's controls on it: Peek shows a link
  // from a pinned tab over this window; a Little window shows a link from
  // another app. Either can become a tab in this window's active space.
  struct Popup : public content::WebContentsObserver {
    explicit Popup(content::WebContents* little_page) : WebContentsObserver(little_page) {}
    std::string kind;
    std::string space;
    base::WeakPtr<content::WebContents> opener;
    GURL opener_url;
    raw_ptr<BrowserWindowInterface> browser = nullptr;
    RAW_PTR_EXCLUSION void* swift = nullptr;
    bool can_split = false;
    bool capturing = false;
    base::CallbackListSubscription closed;
    raw_ptr<Impl> owner = nullptr;
    std::string destinations_json;
    base::WeakPtrFactory<Popup> commands{this};
    base::WeakPtrFactory<Popup> entrance_callbacks{this};

    base::DictValue SiteState() const {
      base::DictValue state;
      auto* location = browser ? LocationBarModel::From(browser.get()) : nullptr;
      const GURL url = location ? location->GetURL() : GURL();
      std::u16string site;
      if (url.is_valid() && !IsBlankPage(url)) {
        // Use Chromium's security formatter for IDNs, ports and credentials.
        // Never render unbounded data or script contents as a site identity.
        site = url.IsStandard() ? url_formatter::FormatUrlForSecurityDisplay(
            url, url_formatter::SchemeDisplay::OMIT_HTTP_AND_HTTPS)
                                : base::UTF8ToUTF16(std::string(url.scheme()) + ":");
      }
      state.Set("site", base::UTF16ToUTF8(site));
      const auto security = location ? location->GetSecurityLevel() : security_state::NONE;
      state.Set("security", security == security_state::DANGEROUS ? "dangerous" :
          security == security_state::WARNING ? "warning" :
          security == security_state::SECURE ? "secure" : "neutral");
      state.Set("securityDescription", location ? base::UTF16ToUTF8(location->GetSecureAccessibilityText()) : "");
      state.Set("canShowSiteInfo", !site.empty());
      return state;
    }

    void UpdateSite() {
      if (swift && browser && !browser->IsDeleteScheduled()) {
        if (auto json = base::WriteJson(SiteState())) BarkSwiftPopupUpdateSite(swift, json->c_str());
      }
    }
    void DidFinishNavigation(content::NavigationHandle* handle) override {
      if (handle->IsInPrimaryMainFrame()) UpdateSite();
    }
    void DidChangeVisibleSecurityState() override { UpdateSite(); }
    void DidStopLoading() override { UpdateSite(); }

    void BeginEntrance() {
      entrance_callbacks.InvalidateWeakPtrs();
      if (swift) BarkSwiftPopupBeginEntrance(swift);
    }

    void AwaitFirstWindowFrame() {
      auto ready = entrance_callbacks.GetWeakPtr();
      // An occluded window may not receive presentation feedback. Showing
      // the card never waits for a network response or for the page to paint.
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
          base::BindOnce(&Popup::BeginEntrance, ready), base::Milliseconds(120));
      auto* view = BrowserView::GetBrowserViewForBrowser(browser);
      auto* widget = view ? view->GetWidget() : nullptr;
      if (auto* compositor = widget ? widget->GetCompositor() : nullptr) {
        compositor->RequestSuccessfulPresentationTimeForNextFrame(base::BindOnce(
            [](base::WeakPtr<Popup> popup, const viz::FrameTimingDetails&) {
              if (popup) popup->BeginEntrance();
            }, ready));
        compositor->ScheduleFullRedraw();
      }
    }
  };

  // Chromium's native bubbles anchor to these noninteractive Views. Ask the
  // AppKit header for its actual button position when a bubble is positioned,
  // including after resizing the window or renaming its Space.
  class LittleWindowAnchor : public views::View {
    METADATA_HEADER(LittleWindowAnchor, views::View)

   public:
    LittleWindowAnchor(base::WeakPtr<Popup> popup, bool extensions)
        : popup_(std::move(popup)), extensions_(extensions) {
      SetCanProcessEventsWithinSubtree(false);
      SetBounds(0, 0, 1, kLittleHeaderHeight);
    }
    gfx::Rect GetAnchorBoundsInScreen() const override {
      auto bounds = views::View::GetAnchorBoundsInScreen();
      if (popup_ && popup_->swift) bounds.Offset(
          static_cast<int>(std::round(BarkSwiftPopupAnchorX(popup_->swift, extensions_))), 0);
      return bounds;
    }

   private:
    const base::WeakPtr<Popup> popup_;
    const bool extensions_;
  };

  static std::vector<std::unique_ptr<Popup>>& OwnerlessLittleWindows() {
    static base::NoDestructor<std::vector<std::unique_ptr<Popup>>> windows;
    return *windows;
  }

  // True while Bark opens its own Peek or Little window, which attaches its
  // controls once Navigate returns.
  static bool& CreatingPopup() {
    static bool creating = false;
    return creating;
  }

  static bool HasPopup(BrowserWindowInterface* browser) {
    const auto matches = [browser](const auto& popup) { return popup->browser == browser; };
    for (auto* host : Instances()) {
      if (std::ranges::any_of(host->popups_, matches)) return true;
    }
    return std::ranges::any_of(OwnerlessLittleWindows(), matches);
  }

  // A popup opened by a page, an extension or session restore gets the same
  // header as a Little window. It keeps its opener and its requested bounds.
  static void AttachLittleWindow(BrowserWindowInterface* browser, content::WebContents* page) {
    if (CreatingPopup() || HasPopup(browser)) return;
    Impl* owner = nullptr;
    if (auto* opener = page->GetFirstWebContentsInLiveOriginalOpenerChain()) {
      for (auto* host : Instances()) {
        if (!host->IsPrivate() && host->tabs_ && !host->tabs_->closing_all() && !host->group_->closing &&
            host->view_->GetProfile() == browser->GetProfile() &&
            host->tabs_->GetIndexOfWebContents(opener) != TabStripModel::kNoTab) {
          owner = host;
          break;
        }
      }
    }
    std::string space;
    const auto meta = ReadTabMeta(page);
    if (const auto* saved = meta.FindString("littleWindowSpace")) {
      space = *saved;
    } else if (owner) {
      space = owner->active_space_;
    } else {
      SpaceCatalog catalog(g_browser_process->local_state());
      space = catalog.FirstForProfile(browser->GetProfile()->GetPath().BaseName().AsUTF8Unsafe());
    }
    AttachPopup(owner, browser, page, std::move(space), {});
    if (owner) owner->QueueSnapshot();
    else for (auto* host : Instances()) host->AdoptOwnerlessLittleWindows();
  }

  void AdoptOwnerlessLittleWindows() {
    if (IsPrivate() || !tabs_ || tabs_->closing_all() || group_->closing ||
        view_->browser()->IsDeleteScheduled()) return;
    auto& windows = OwnerlessLittleWindows();
    for (auto it = windows.begin(); it != windows.end();) {
      if ((*it)->browser->GetProfile() != view_->GetProfile()) { ++it; continue; }
      (*it)->owner = this;
      popups_.push_back(std::move(*it));
      it = windows.erase(it);
      QueueSnapshot();
    }
  }

  static base::DictValue LittleDestinations(Profile* profile, const std::string& active_space) {
    base::ListValue spaces;
    std::string default_space;
    SpaceCatalog catalog(g_browser_process->local_state());
    const auto profile_key = profile->GetPath().BaseName().AsUTF8Unsafe();
    for (const auto& value : catalog.List()) {
      const auto& entry = value.GetDict();
      const auto* id = entry.FindString("id");
      const auto* name = entry.FindString("name");
      const auto* owner = entry.FindString("profile");
      if (!id || !name || !owner || *owner != profile_key || entry.FindBool("hidden").value_or(false)) continue;
      if (default_space.empty() || *id == active_space) default_space = *id;
      base::DictValue space;
      space.Set("id", *id);
      space.Set("name", *name);
      if (const auto* emoji = entry.FindString("emoji")) space.Set("emoji", *emoji);
      if (const auto* theme = entry.FindString("theme")) space.Set("theme", *theme);
      if (const auto* canvas = entry.FindDict("gradientCanvas")) space.Set("gradientCanvas", canvas->Clone());
      spaces.Append(std::move(space));
    }
    base::DictValue destinations;
    destinations.Set("activeSpace", default_space);
    destinations.Set("spaces", std::move(spaces));
    return destinations;
  }

  // Opens cross-site links clicked in pinned tabs and Favorites in Peek.
  class PeekThrottle : public content::NavigationThrottle {
   public:
    using NavigationThrottle::NavigationThrottle;
    ThrottleCheckResult WillStartRequest() override {
      return ShouldPeek(navigation_handle()) ? CANCEL_AND_IGNORE : PROCEED;
    }
    const char* GetNameForLogging() override { return "BarkPeekThrottle"; }
  };
  static void AddPeekThrottle(content::NavigationThrottleRegistry& registry) {
    auto& handle = registry.GetNavigationHandle();
    if (!handle.IsInPrimaryMainFrame() || handle.IsSameDocument() || !handle.IsRendererInitiated()) return;
    registry.AddThrottle(std::make_unique<PeekThrottle>(registry));
  }

  static bool ShouldPeek(content::NavigationHandle* handle) {
    if (!PeekEnabled() || !handle->HasUserGesture() || handle->IsPost() ||
        !ui::PageTransitionCoreTypeIs(handle->GetPageTransition(), ui::PAGE_TRANSITION_LINK)) return false;
    const GURL& url = handle->GetURL();
    auto* contents = handle->GetWebContents();
    if (!url.SchemeIsHTTPOrHTTPS() || !contents) return false;
    for (auto* host : Instances()) {
      if (host->IsPrivate() || !host->tabs_ || host->tabs_->closing_all()) continue;
      const int index = host->tabs_->GetIndexOfWebContents(contents);
      if (index == TabStripModel::kNoTab) continue;
      // Pinned tabs and Favorites stay on their own site.
      if (!host->tabs_->IsTabPinned(index)) return false;
      const GURL& current = contents->GetLastCommittedURL();
      if (!current.SchemeIsHTTPOrHTTPS() ||
          net::registry_controlled_domains::SameDomainOrHost(
              current, url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)) return false;
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce(&Impl::OpenPeek, host->weak_factory_.GetWeakPtr(), url, contents->GetWeakPtr()));
      return true;
    }
    return false;
  }

  // Chromium has already created this destination and checked its popup policy.
  // A modified anchor click takes the OpenURLFromTab path instead. Explicit
  // windows, popups, background tabs, and split requests retain their disposition.
  static bool PeekNewContents(NavigateParams& params) {
    if (!PeekEnabled() || !params.original_user_gesture || !params.source_contents ||
        !params.contents_to_insert || !params.url.SchemeIsHTTPOrHTTPS() ||
        params.disposition != WindowOpenDisposition::kNewForegroundTab ||
        params.contents_to_insert->GetOriginalWindowOpenDisposition() != WindowOpenDisposition::kNewForegroundTab ||
        params.window_features.is_popup || params.window_features.is_split) return false;
    for (auto* host : Instances()) {
      if (host->view_->browser() != params.browser || host->IsPrivate() ||
          !host->tabs_ || host->tabs_->closing_all() || host->group_->closing) continue;
      auto* source = params.source_contents.get();
      if (host->tabs_->GetActiveWebContents() != source || source->IsFullscreen() ||
          (!host->tabs_->IsTabPinned(host->tabs_->active_index()) && !host->IsFavorite(source))) return false;
      NavigatePopup(host, params, host->active_space_, source->GetWeakPtr());
      return true;
    }
    return false;
  }

  // External links and the global shortcut follow the last browsing window,
  // including a Little window whose original sidebar is hidden or closed.
  static std::pair<Impl*, Popup*> LittleWindowContext() {
    std::pair<Impl*, Popup*> context{};
    GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
      if (browser->IsDeleteScheduled() || browser->GetProfile()->IsOffTheRecord() ||
          !browser->GetTabStripModel() || browser->GetTabStripModel()->closing_all()) return true;
      const auto matches = [browser](const auto& popup) {
        return popup->kind == "little" && popup->browser == browser;
      };
      for (auto* host : Instances()) {
        if (host->group_->closing) continue;
        if (host->view_->browser() == browser && !host->concealed_ &&
            (browser->GetWindow()->IsVisible() || browser->GetWindow()->IsMinimized() || NSApp.hidden)) {
          context.first = host;
          return false;
        }
        auto it = std::ranges::find_if(host->popups_, matches);
        if (it != host->popups_.end()) { context = {host, it->get()}; return false; }
      }
      for (const auto& popup : OwnerlessLittleWindows()) {
        if (matches(popup)) { context.second = popup.get(); return false; }
      }
      return true;
    }, BrowserCollection::Order::kActivation);
    return context;
  }

  gfx::Rect PeekBounds() const {
    // Centered over the page, leaving its edges visible around it.
    gfx::Rect page = view_->browser()->GetWindow()->GetBounds();
    page.Inset(gfx::Insets::TLBR(0, width(), 0, 0));
    const int w = std::min(1180, static_cast<int>(page.width() * 0.86));
    const int h = static_cast<int>(page.height() * 0.88);
    return gfx::Rect(page.x() + (page.width() - w) / 2, page.y() + (page.height() - h) / 2, w, h);
  }

  static gfx::Rect LittleBounds() {
    // External links are often clicked on a different display from Bark.
    NSScreen* screen = NSScreen.mainScreen;
    const NSPoint pointer = NSEvent.mouseLocation;
    for (NSScreen* candidate in NSScreen.screens) {
      if (NSPointInRect(pointer, candidate.frame)) {
        screen = candidate;
        break;
      }
    }
    const NSRect visible = screen.visibleFrame;
    const NSRect full = NSScreen.screens.firstObject.frame;
    const int w = std::min(960, static_cast<int>(visible.size.width * 0.7));
    const int h = std::min(720, static_cast<int>(visible.size.height * 0.75));
    // Views uses a top-left origin on the primary screen.
    const int x = static_cast<int>(NSMidX(visible) - w / 2.0);
    const int y = static_cast<int>(NSMaxY(full) - NSMaxY(visible) + (visible.size.height - h) / 2.0);
    return gfx::Rect(x, y, w, h);
  }

  void OpenPeek(const GURL& url, base::WeakPtr<content::WebContents> opener) {
    // The link request is posted. Do not open a preview over a different tab
    // if its source was closed or the user switched pages before it runs.
    if (IsPrivate() || !tabs_ || tabs_->closing_all() || group_->closing ||
        !opener || tabs_->GetActiveWebContents() != opener.get()) return;
    NavigateParams params(view_->browser(), url, ui::PAGE_TRANSITION_LINK);
    params.user_gesture = true;
    NavigatePopup(this, params, active_space_, opener);
  }

  static Popup* OpenStandaloneLittle(Profile* profile, const GURL& url, const std::string& space) {
    if (GetBrowserWindowCreationStatusForProfile(*profile) != BrowserWindowInterface::CreationStatus::kOk)
      return nullptr;
    BrowserWindowCreateParams create(BrowserWindowInterface::TYPE_POPUP, profile, true);
    create.initial_bounds = LittleBounds();
    // A lookup while the main browser is closed must not replace its saved session.
    create.omit_from_session_restore = true;
    create.should_trigger_session_restore = false;
    auto* browser = CreateBrowserWindow(std::move(create));
    if (!browser) return nullptr;
    NavigateParams params(browser, url, ui::PAGE_TRANSITION_LINK);
    params.disposition = WindowOpenDisposition::kNewForegroundTab;
    params.user_gesture = true;
    {
      base::AutoReset<bool> creating(&CreatingPopup(), true);
      Navigate(&params);
    }
    auto* page = params.navigated_or_inserted_contents.get();
    if (!page) {
      browser->GetWindow()->Close();
      return nullptr;
    }
    auto* popup = AttachPopup(nullptr, browser, page, space, {});
    browser->GetWindow()->Show();
    ActivateLittleWindow(browser, page);
    return popup;
  }

  static Popup* OpenLittleWindow(const GURL& url, Impl* host, Popup* source = nullptr) {
    if (host && host->group_->closing) return nullptr;
    auto* browser = host ? host->view_->browser() : source ? source->browser.get() : nullptr;
    if (!browser || browser->IsDeleteScheduled() || browser->GetProfile()->IsOffTheRecord() ||
        !browser->GetTabStripModel() || browser->GetTabStripModel()->closing_all()) return nullptr;
    if (!host) return OpenStandaloneLittle(browser->GetProfile(), url, source->space);
    NavigateParams params(browser, url, ui::PAGE_TRANSITION_LINK);
    params.user_gesture = true;
    return NavigatePopup(host, params, host->active_space_, {});
  }

  static void OpenFreshLittleWindow(Impl* host, Popup* source = nullptr) {
    if (auto* popup = OpenLittleWindow(GURL("about:blank"), host, source); popup && popup->swift)
      BarkSwiftPopupEditAddress(popup->swift, "", true);
  }

  // Register only the requested combination. macOS dispatches this key even
  // when another application is frontmost.
  class GlobalLittleShortcut : public ui::GlobalAcceleratorListener::Observer {
   public:
    explicit GlobalLittleShortcut(const ui::Accelerator& key) : key_(key) {}
    static GlobalLittleShortcut& Get() {
      static base::NoDestructor<GlobalLittleShortcut> shortcut(
          ui::Accelerator(ui::VKEY_N, ui::EF_COMMAND_DOWN | ui::EF_ALT_DOWN));
      return *shortcut;
    }

    bool unavailable() const { return state_ == State::kUnavailable; }

    void Update(bool enable, bool retry) {
      if (enable && state_ == State::kRegistered) return;
      if (enable && unavailable() && !retry) return;
      if (!enable && state_ == State::kDisabled) return;
      auto* listener = ui::GlobalAcceleratorListener::GetInstance();
      if (enable) {
        state_ = listener && listener->RegisterAccelerator(key_, this)
                     ? State::kRegistered : State::kUnavailable;
      } else {
        if (state_ == State::kRegistered) listener->UnregisterAccelerator(key_, this);
        state_ = State::kDisabled;
      }
    }

    void OnKeyPressed(const ui::Accelerator&) override {
      if (NSApp.active) {
        auto* front = GlobalBrowserCollection::GetInstance()->GetLastActiveBrowser();
        if (front && front->GetProfile()->IsOffTheRecord()) return;
      }
      auto [host, popup] = LittleWindowContext();
      OpenFreshLittleWindow(host, popup);
    }

    // The macOS listener delivers registered hotkeys through OnKeyPressed.
    void ExecuteCommand(const std::string&, const std::string&) override {}

   private:
    enum class State { kDisabled, kRegistered, kUnavailable };
    State state_ = State::kDisabled;
    const ui::Accelerator key_;
  };

  static void SyncGlobalLittleShortcut(bool retry = false) {
    const bool enabled = GlobalLittleShortcutEnabled() &&
        (!OwnerlessLittleWindows().empty() || std::ranges::any_of(Instances(), [](Impl* host) {
          return !host->IsPrivate() && !host->group_->closing;
        }));
    GlobalLittleShortcut::Get().Update(enabled, retry);
  }

  static void ActivateLittleWindow(BrowserWindowInterface* browser, content::WebContents* page) {
    auto* window = browser->GetWindow();
    if (window->IsMinimized()) window->Restore();
    // Bring the lookup to the user's current macOS Space, including a
    // fullscreen app, without bringing its main Bark window along.
    if (auto* view = BrowserView::GetBrowserViewForBrowser(browser); view && view->GetWidget()) {
      view->GetWidget()->SetCanAppearInExistingFullscreenSpaces(true);
      view->GetWidget()->MoveToActiveFullscreenSpace();
    }
    window->Activate();
    page->Focus();
  }

  static Popup* NavigatePopup(Impl* host, NavigateParams& params, std::string space,
                              base::WeakPtr<content::WebContents> opener) {
    const bool peek = !!opener;
    std::optional<ScopedPeekCreation> entering;
    if (peek) {
      host->ClosePopups("peek");
      entering.emplace(host->view_->GetProfile());
    } else {
      // Do not switch desktops before ActivateLittleWindow can place the popup.
      params.window_action = NavigateParams::WindowAction::kShowWindowInactive;
    }
    params.disposition = WindowOpenDisposition::kNewPopup;
    params.window_features.bounds = peek ? host->PeekBounds() : LittleBounds();
    params.window_features.has_x = params.window_features.has_y = true;
    params.window_features.has_width = params.window_features.has_height = true;
    auto owner = host ? host->weak_factory_.GetWeakPtr() : base::WeakPtr<Impl>();
    auto source = params.browser->GetWeakPtr();
    {
      base::AutoReset<bool> creating(&CreatingPopup(), true);
      Navigate(&params);
    }
    auto* contents = params.navigated_or_inserted_contents.get();
    auto* tab = contents ? tabs::TabInterface::MaybeGetFromContents(contents) : nullptr;
    BrowserWindowInterface* browser = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!browser || source.get() == browser || (peek && (!owner || !opener))) return nullptr;
    Popup* record = AttachPopup(owner.get(), browser, contents, std::move(space), opener);
    auto live = record->commands.GetWeakPtr();
    if (peek) {
      if (record->swift) record->AwaitFirstWindowFrame();
      browser->GetWindow()->Activate();
    } else {
      SetLittleSessionSpace(browser, contents, &record->space);
      ActivateLittleWindow(browser, contents);
    }
    return live.get();
  }

  // The session already serializes Bark's tab metadata with the page history.
  // Label only Little windows so ordinary Chromium popups remain independent.
  static void SetLittleSessionSpace(BrowserWindowInterface* browser, content::WebContents* page,
                                    const std::string* space) {
    auto meta = ReadTabMeta(page);
    if (space) meta.Set("littleWindowSpace", *space);
    else meta.Remove("littleWindowSpace");
    auto json = base::WriteJson(meta);
    if (!json) return;
    if (meta.empty()) json->clear();
    SetTabMeta(page, *json);
    if (auto* session = SessionServiceFactory::GetForProfile(browser->GetProfile())) {
      auto tab_id = sessions::SessionTabHelper::IdForTab(page);
      if (tab_id.is_valid()) session->AddTabExtraData(browser->GetSessionID(), tab_id, kTabMetaKey, *json);
    }
  }

  static Popup* AttachPopup(Impl* owner, BrowserWindowInterface* browser, content::WebContents* contents,
                            std::string space, base::WeakPtr<content::WebContents> opener) {
    const bool peek = !!opener;
    auto popup = std::make_unique<Popup>(peek ? nullptr : contents);
    popup->kind = peek ? "peek" : "little";
    popup->space = std::move(space);
    popup->opener = opener;
    if (opener) popup->opener_url = PageURL(opener.get());
    popup->browser = browser;
    popup->owner = owner;
    Popup* record = popup.get();
    popup->closed = browser->RegisterBrowserDidClose(base::BindRepeating(
        [](Popup* record, BrowserWindowInterface*) { ForgetPopup(record); }, record));
    base::DictValue config = peek ? base::DictValue() : LittleDestinations(browser->GetProfile(), record->space);
    if (!peek) config.Merge(record->SiteState());
    config.Set("kind", record->kind);
    if (peek) {
      if (auto* surface = contents->GetRenderWidgetHostView()) {
        if (auto color = surface->GetBackgroundColor(); color && SkColorGetA(*color) == 255)
          config.Set("backgroundColor", base::StringPrintf("#%06X", *color & 0x00ffffffu));
      }
    }
    record->can_split = peek && owner->CanSplitPopup(record);
    config.Set("canSplit", record->can_split);
    NSWindow* window = browser->GetWindow()->GetNativeWindow().GetNativeNSWindow();
    NSWindow* owner_window = owner ? owner->view_->GetNativeWindow().GetNativeNSWindow() : nil;
    NSView* viewport = opener ? opener->GetNativeView().GetNativeNSView() : nil;
    if (auto json = base::WriteJson(config)) {
      // The popup's default AppKit frame needs its height before the full-size
      // content style is applied and AppKit first lays out its caption buttons.
      if (!peek) objc_setAssociatedObject(window, sel_registerName("barkLittleHeaderHeight"),
                                          @(kLittleHeaderHeight), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      popup->swift = BarkSwiftPopupAttach((__bridge void*)window, (__bridge void*)owner_window, (__bridge void*)viewport,
                                          json->c_str(), record, &ReceivePopupCommand);
      if (!peek && !popup->swift)
        objc_setAssociatedObject(window, sel_registerName("barkLittleHeaderHeight"), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (popup->swift) {
      auto* view = BrowserView::GetBrowserViewForBrowser(browser);
      if (peek) {
        view->SetProperty(kBarkPeek, true);
      } else {
        for (bool extensions : {false, true}) {
          views::View* anchor = view->AddChildView(std::make_unique<LittleWindowAnchor>(
              record->commands.GetWeakPtr(), extensions));
          view->SetProperty(extensions ? kLittleExtensionsAnchor : kLittleSiteAnchor, anchor);
        }
      }
      view->InvalidateLayout();
      if (peek) view->GetWidget()->LayoutRootViewIfNecessary();
    }
    (owner ? owner->popups_ : OwnerlessLittleWindows()).push_back(std::move(popup));
    return record;
  }

  static void ReceivePopupCommand(void* context, const char* json) {
    auto* record = static_cast<Popup*>(context);
    if (!json || !record) return;
    // Dismissal and tab promotion can destroy the UI that sent this action.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Popup> popup, std::string command) {
          if (popup) PopupCommand(popup.get(), command);
        }, record->commands.GetWeakPtr(), std::string(json)));
  }

  static void PopupCommand(Popup* record, const std::string& command) {
    if (!record || !record->browser || record->browser->IsDeleteScheduled()) return;
    auto* browser = record->browser.get();
    auto* model = browser->GetTabStripModel();
    if (!model || model->closing_all()) return;
    auto* page = model->GetActiveWebContents();
    if (command == "close") {
      browser->GetWindow()->Close();
    } else if (command == "copyURL" && record->swift) {
      if (page && !IsBlankPage(page->GetVisibleURL())) {
        BarkSwiftPopupCopyURL(record->swift, page->GetVisibleURL().spec().c_str());
      }
    } else if (record->kind == "little" && command == "focusPage" && page) {
      page->Focus();
    } else if (record->kind == "little" && command == "newLittleWindow") {
      OpenFreshLittleWindow(record->owner, record);
    } else if (record->kind == "little" && command == "siteInfo" && page) {
      ShowPageInfoDialog(page, {}, bubble_anchor_util::Anchor::kLocationBar);
    } else if (record->kind == "little" && command == "extensions" && page) {
      auto* actions = ToolbarActionsModel::Get(browser->GetProfile());
      if (!actions || actions->action_ids().empty()) {
        chrome::ShowExtensions(browser);
        return;
      }
      auto* container = ExtensionsContainer::From(*browser);
      if (!container) {
        // A Chromium popup normally has only a location bar. Give its menu
        // a toolbar model bound to this window so actions see the Little tab.
        auto* view = BrowserView::GetBrowserViewForBrowser(browser);
        if (!view) return;
        auto* host = view->AddChildView(std::make_unique<views::View>());
        host->SetVisible(false);
        host->AddChildView(std::make_unique<ExtensionsToolbarDesktop>(
            browser, ExtensionsToolbarDesktop::DisplayMode::kAutoHide));
        container = ExtensionsContainer::From(*browser);
      }
      if (container) container->ToggleExtensionsMenu();
    } else if (record->kind == "little" && command == "editAddress" && page && record->swift) {
      const GURL url = page->GetVisibleURL();
      BarkSwiftPopupEditAddress(record->swift, IsBlankPage(url) ? "" : url.spec().c_str(), false);
    } else if (record->kind == "little" && command.starts_with("navigate:") && page) {
      const auto input = base::TrimWhitespaceASCII(std::string_view(command).substr(9), base::TRIM_ALL);
      if (input.empty()) return;
      const GURL url = ResolveAddress(std::string(input), browser->GetProfile()).url;
      if (!url.is_valid()) return;
      NavigateParams params(browser, url, ui::PAGE_TRANSITION_TYPED);
      params.disposition = WindowOpenDisposition::kCurrentTab;
      Navigate(&params);
    } else if (record->kind == "little" && (command == "expand" || command.starts_with("expand:"))) {
      const auto space = command == "expand" ? (record->owner ? record->owner->active_space_ : record->space)
                                             : command.substr(7);
      SpaceCatalog catalog(g_browser_process->local_state());
      const auto* entry = catalog.Find(space);
      const auto* profile = entry ? entry->FindString("profile") : nullptr;
      if (!profile || *profile != browser->GetProfile()->GetPath().BaseName().AsUTF8Unsafe() ||
          entry->FindBool("hidden").value_or(false)) {
        // The picker can outlive a Space that was moved or deleted.
        auto json = base::WriteJson(LittleDestinations(browser->GetProfile(), record->space));
        if (record->swift && json) BarkSwiftPopupSetSpaces(record->swift, json->c_str());
        return;
      }
      // Opening a normal window is deferred until promotion if the user
      // closed the last one while reading. Its sidebar adopts this popup.
      // This window may be the first since launch, when a link opened Bark
      // straight into a Little window. Let it restore the saved session so
      // the promoted page joins the user's tabs instead of replacing them.
      if (!record->owner) {
        BrowserWindowCreateParams params(browser->GetProfile(), true);
        if (!CreateBrowserWindow(std::move(params))) return;
      }
      if (auto* owner = record->owner.get()) {
        auto* destination = owner->view_->browser();
        auto moved = page ? page->GetWeakPtr() : base::WeakPtr<content::WebContents>();
        owner->MovePopupToTab(record, false, space);
        // A standalone Little window is left out of the session, so the page
        // arrives without saved history. Record it, or a restart drops the tab.
        auto* session = SessionServiceFactory::GetForProfileIfExisting(destination->GetProfile());
        if (session && moved &&
            destination->GetTabStripModel()->GetIndexOfWebContents(moved.get()) != TabStripModel::kNoTab) {
          session->TrackWindowAfterTabMove(destination);
          session->TabRestored(moved.get(), false);
        }
      }
    } else if (auto* host = record->owner.get()) {
      if (command == "expand" && record->swift) host->CapturePeekForPromotion(record);
      else if (command == "expand") host->MovePopupToTab(record);
      else if (command == "split" && host->CanSplitPopup(record)) host->MovePopupToTab(record, true);
    }
  }

  bool CanSplitPopup(const Popup* record) const {
    if (!record || record->owner != this || record->kind != "peek" || !record->opener ||
        !record->browser || record->browser->IsDeleteScheduled() ||
        record->browser->GetProfile() != view_->GetProfile() ||
        !tabs_ || tabs_->closing_all() || group_->closing || IsPrivate() ||
        active_space_ != record->space || tabs_->GetActiveWebContents() != record->opener.get() ||
        PageURL(record->opener.get()) != record->opener_url) return false;
    const int opener_index = tabs_->GetIndexOfWebContents(record->opener.get());
    return tabs_->ContainsIndex(opener_index) && InActiveSpace(opener_index) && !IsFavorite(record->opener.get());
  }

  void CapturePeekForPromotion(Popup* record) {
    if (record->capturing) return;
    auto* model = record->browser->GetTabStripModel();
    auto* page = model ? model->GetActiveWebContents() : nullptr;
    auto* surface = page ? page->GetRenderWidgetHostView() : nullptr;
    auto* owner_page = tabs_ ? tabs_->GetActiveWebContents() : nullptr;
    if (!surface || !owner_page || !surface->IsSurfaceAvailableForCopy()) {
      MovePopupToTab(record);
      return;
    }
    record->capturing = true;
    auto finish = base::BindRepeating(&Impl::OnPeekCaptured, weak_factory_.GetWeakPtr(),
        record->browser->GetWeakPtr(), page->GetWeakPtr(), owner_page->GetWeakPtr());
    // A stalled capture must not keep the final-sized Peek open indefinitely.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(finish, content::CopyFromSurfaceResult(
            base::unexpected(content::CopyFromSurfaceError::kTimeout))), base::Milliseconds(300));
    surface->CopyFromSurface(gfx::Rect(), gfx::Size(), base::Milliseconds(180),
        base::BindPostTaskToCurrentDefault(
            base::OnceCallback<void(const content::CopyFromSurfaceResult&)>(finish)));
  }

  void OnPeekCaptured(base::WeakPtr<BrowserWindowInterface> browser,
                      base::WeakPtr<content::WebContents> page,
                      base::WeakPtr<content::WebContents> owner_page,
                      const content::CopyFromSurfaceResult& capture) {
    if (!browser || browser->IsDeleteScheduled() || !tabs_ || tabs_->closing_all() || group_->closing) return;
    for (auto& popup : popups_) {
      if (popup->browser != browser.get() || !popup->capturing) continue;
      popup->capturing = false;
      auto* source_tabs = browser->GetTabStripModel();
      if (!page || !owner_page || tabs_->GetActiveWebContents() != owner_page.get() ||
          !source_tabs || source_tabs->GetActiveWebContents() != page.get()) {
        browser->GetWindow()->Close();
        return;
      }
      ClearPromotionCover();
      if (popup->swift && capture.has_value() && !capture->bitmap.drawsNothing()) {
        NSImage* image = gfx::Image::CreateFrom1xBitmap(capture->bitmap).AsNSImage();
        if (image) promotion_cover_ = BarkSwiftPopupCover(popup->swift, (__bridge void*)image);
        if (promotion_cover_) {
          covered_contents_ = page;
          // Hidden windows or a crashed renderer may never present a frame.
          base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
              base::BindOnce(&Impl::ClearPromotionCover, promotion_weak_factory_.GetWeakPtr()), base::Seconds(1));
        }
      }
      MovePopupToTab(popup.get());
      return;
    }
  }

  void ClearPromotionCover() {
    promotion_weak_factory_.InvalidateWeakPtrs();
    covered_contents_.reset();
    if (promotion_cover_) BarkSwiftPopupRemoveCover(std::exchange(promotion_cover_, nullptr));
  }

  void OnPromotedFrameSubmitted(bool success) {
    auto* widget = view_->GetWidget();
    auto* compositor = widget ? widget->GetCompositor() : nullptr;
    if (!success || !compositor) {
      ClearPromotionCover();
      return;
    }
    // The renderer has submitted a frame in the new viewport. Wait for the
    // destination window to display it before removing the last popup frame.
    compositor->RequestSuccessfulPresentationTimeForNextFrame(base::BindOnce(
        [](base::WeakPtr<Impl> self, const viz::FrameTimingDetails&) {
          if (self) self->ClearPromotionCover();
        }, promotion_weak_factory_.GetWeakPtr()));
    compositor->ScheduleFullRedraw();
  }

  // Moves the popup's page into this window's active space as a tab.
  // Splitting retains the live page and its history; it never navigates a copy.
  void MovePopupToTab(Popup* record, bool split = false, std::string destination = {}) {
    if (!tabs_ || tabs_->closing_all() || group_->closing ||
        !record || record->owner != this || (split && !CanSplitPopup(record))) return;
    auto* source = record->browser.get();
    if (!source || source == view_->browser() || source->IsDeleteScheduled() || source->GetProfile() != view_->GetProfile() ||
        !source->GetTabStripModel() || source->GetTabStripModel()->empty() ||
        source->GetTabStripModel()->closing_all()) return;
    const int source_index = source->GetTabStripModel()->active_index();
    if (!source->GetTabStripModel()->ContainsIndex(source_index)) return;
    auto contents = source->GetTabStripModel()->GetWebContentsAt(source_index)->GetWeakPtr();
    auto opener = record->opener;
    if (record->kind == "peek" && record->swift) {
      BarkSwiftPopupDetach(record->swift);
      record->swift = nullptr;
    }
    chrome::MoveTabsToExistingWindow(source, view_->browser(), {source_index});
    if (!contents || tabs_->closing_all() || group_->closing) return;
    const int index = tabs_->GetIndexOfWebContents(contents.get());
    if (index == TabStripModel::kNoTab) return;
    if (!destination.empty()) SetLittleSessionSpace(view_->browser(), contents.get(), nullptr);
    AssignTab(contents.get(), destination.empty() ? active_space_ : destination);
    if (!destination.empty()) {
      selected_tabs_[destination] = sessions::SessionTabHelper::IdForTab(contents.get()).id();
      if (destination != active_space_) SelectLocalSpace(destination);
      // A profile switch can have hidden the popup's original sidebar.
      for (auto* host : Instances()) {
        if (host != this && host->group_ == group_ && host->view_->browser()->GetWindow()->IsVisible()) {
          host->PresentSpace(destination, view_->browser());
          break;
        }
      }
      view_->browser()->GetWindow()->Show();
    }
    if (split && opener) {
      const int opener_index = tabs_->GetIndexOfWebContents(opener.get());
      if (tabs_->ContainsIndex(opener_index)) {
        tabs_->ActivateTabAt(opener_index);
        SplitWithActive(tabs_->GetIndexOfWebContents(contents.get()),
                        split_tabs::SplitTabLayout::kSideBySide, false);
      }
    }
    // Making a split can reorder its members, so resolve the moved tab again.
    const int moved_index = tabs_->GetIndexOfWebContents(contents.get());
    if (!tabs_->ContainsIndex(moved_index)) return;
    tabs_->ActivateTabAt(moved_index);
    view_->browser()->GetWindow()->Activate();
    contents->Focus();
    if (promotion_cover_ && covered_contents_.get() == contents.get()) {
      contents->GetPrimaryMainFrame()->InsertVisualStateCallback(base::BindOnce(
          &Impl::OnPromotedFrameSubmitted, promotion_weak_factory_.GetWeakPtr()));
    }
    QueueGroupSnapshot();
  }

  static void ForgetPopup(Popup* record) {
    auto& windows = record->owner ? record->owner->popups_ : OwnerlessLittleWindows();
    for (auto it = windows.begin(); it != windows.end(); ++it) {
      if (it->get() != record) continue;
      if ((*it)->swift) BarkSwiftPopupDetach((*it)->swift);
      (*it)->swift = nullptr;
      record->commands.InvalidateWeakPtrs();
      record->owner = nullptr;
      record->browser = nullptr;
      // The close notification is running; release the subscription later.
      base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, std::move(*it));
      windows.erase(it);
      SyncGlobalLittleShortcut();
      return;
    }
  }

  void ClosePopups(const std::string& kind) {
    std::vector<base::WeakPtr<BrowserWindowInterface>> windows;
    for (auto& popup : popups_)
      if (popup->kind == kind && popup->browser) windows.push_back(popup->browser->GetWeakPtr());
    for (auto& window : windows)
      if (window && !window->IsDeleteScheduled()) window->GetWindow()->Close();
  }

  static void DismissAddressForExternalTab(BrowserWindowInterface* browser) {
    for (auto* host : Instances()) {
      if (host->view_->browser() == browser && host->swift_) {
        BarkSwiftSidebarDismissAddress(host->swift_);
        return;
      }
    }
  }

  static bool ActivateMatchingLittle(const std::vector<std::unique_ptr<Popup>>& popups,
                                     Profile* profile, const GURL& url) {
    for (const auto& popup : popups) {
      auto* browser = popup->browser.get();
      if (popup->kind != "little" || !browser || browser->IsDeleteScheduled() ||
          browser->GetProfile() != profile) continue;
      auto* model = browser->GetTabStripModel();
      auto* page = model && !model->closing_all() ? model->GetActiveWebContents() : nullptr;
      // Use the live URL, including its fragment. Returning to a link after
      // it navigated away must leave that window's current page intact.
      if (page && page->GetVisibleURL() == url) {
        ActivateLittleWindow(browser, page);
        return true;
      }
    }
    return false;
  }

  static bool OpenExternalLink(const GURL& url) {
    if (!LittleWindowEnabled() || !url.SchemeIsHTTPOrHTTPS()) return false;
    auto [host, popup] = LittleWindowContext();
    if (!host && !popup) return false;
    auto* profile = host ? host->view_->GetProfile() : popup->browser->GetProfile();
    if (host) BarkSwiftSidebarDismissAddress(host->swift_);
    for (auto* candidate : Instances()) {
      if (!candidate->group_->closing && candidate->view_->GetProfile() == profile &&
          ActivateMatchingLittle(candidate->popups_, profile, url)) return true;
    }
    return ActivateMatchingLittle(OwnerlessLittleWindows(), profile, url) || OpenLittleWindow(url, host, popup);
  }
  void PersistTitle(content::WebContents* contents) {
    if (IsPrivate()) return;
    auto& controller = contents->GetController();
    auto* entry = controller.GetLastCommittedEntry();
    if (!entry || entry->GetTitle().empty()) return;
    auto* saved = static_cast<SavedSessionTitle*>(contents->GetUserData(kSavedSessionTitle));
    if (saved && saved->navigation_id == entry->GetUniqueID() && saved->title == entry->GetTitle()) return;
    auto* session = SessionServiceFactory::GetForProfileIfExisting(view_->GetProfile());
    if (!session) return;
    // Page titles can arrive after the navigation was saved. Dormant pins must
    // retain that title without loading the page again to recover it.
    session->UpdateTabNavigation(view_->browser()->GetSessionID(), sessions::SessionTabHelper::IdForTab(contents),
        sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(controller.GetLastCommittedEntryIndex(), entry));
    auto title = std::make_unique<SavedSessionTitle>();
    title->navigation_id = entry->GetUniqueID();
    title->title = entry->GetTitle();
    contents->SetUserData(kSavedSessionTitle, std::move(title));
  }
  void RememberActiveSpace() {
    if (IsPrivate() || group_->closing || group_->restoring || active_space_.empty() ||
        catalog_.IsHidden(active_space_) ||
        !view_->browser()->GetWindow()->IsVisible()) return;
    auto* prefs = g_browser_process->local_state();
    const auto& saved = prefs->GetDict(kWindowGroupsPref);
    if (auto* id = saved.FindString(group_->id); id && *id == active_space_) return;
    auto updated = saved.Clone();
    if (updated.size() >= 256 && !updated.contains(group_->id)) updated.Remove(updated.begin()->first);
    updated.Set(group_->id, active_space_);
    prefs->SetDict(kWindowGroupsPref, std::move(updated));
  }
  void MatchWindowFrame(Impl* source) {
    view_->browser()->GetWindow()->SetBounds(source->view_->browser()->GetWindow()->GetBounds());
    // AppKit can constrain a newly shown window to the screen's work area.
    // Keep the user's dragged origin, including partially offscreen windows.
    NSWindow* from = source->view_->GetNativeWindow().GetNativeNSWindow();
    NSWindow* to = view_->GetNativeWindow().GetNativeNSWindow();
    if (from && to) [to setFrameOrigin:from.frame.origin];
  }
  // Space switches swap between per-profile windows stacked on the same frame.
  // The incoming window is ordered directly beneath the outgoing one, which
  // stays on screen until the incoming window has drawn its tab; then the
  // outgoing window fades out. So no unrendered content is ever visible and
  // the switch reads as one window changing.
  // Below full opacity a window cannot occlude the one under it (see
  // WebContentsOcclusionCheckerMac), so Chromium renders the incoming tab
  // while it is still covered. Opacity goes through Widget::SetOpacity
  // because Chromium's window bridge owns alphaValue until a newly shown
  // window's first frame arrives.
  static constexpr float kCoverOpacity = 0.999f;
  void AdoptPendingPresentation() {
    auto& pending = PendingPresentation();
    if (IsPrivate() || !pending || pending->profile != view_->GetProfile()->GetPath()) return;
    pending.reset();
    Conceal();
    // Never leave a window invisible if the switch fails to present it.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Impl::RestoreOpacityIfStalled, weak_factory_.GetWeakPtr()),
        base::Seconds(3));
  }
  // A newly opened profile window starts invisible until it is revealed.
  void Conceal() {
    if (concealed_) return;
    concealed_ = true;
    if (auto* widget = view_->GetWidget()) {
      widget->SetVisibilityChangedAnimationsEnabled(false);
      widget->SetOpacity(0.f);
    }
  }
  void Unconceal() {
    if (!concealed_) return;
    concealed_ = false;
    if (auto* widget = view_->GetWidget()) {
      widget->SetOpacity(1.f);
      widget->SetVisibilityChangedAnimationsEnabled(true);
    }
  }
  void RestoreOpacityIfStalled() {
    if (!revealing_) Unconceal();
  }
  // Shows this window beneath `outgoing` and fades them out once this
  // window's tab has drawn, but not before `not_before` (the end of the
  // sidebar's swipe animation).
  void BeginReveal(std::vector<base::WeakPtr<Impl>> outgoing, base::TimeTicks not_before) {
    reveal_outgoing_ = std::move(outgoing);
    reveal_not_before_ = not_before;
    reveal_ready_ = false;
    revealing_ = true;
    ++group_->transitions;
    NSWindow* cover = nil;
    Impl* cover_host = nullptr;
    for (auto& host : reveal_outgoing_) {
      if (!host) continue;
      if (auto* widget = host->view_->GetWidget()) widget->SetOpacity(kCoverOpacity);
      if (!cover) {
        cover = host->view_->GetNativeWindow().GetNativeNSWindow();
        cover_host = host.get();
      }
    }
    auto* widget = view_->GetWidget();
    if (widget) widget->SetVisibilityChangedAnimationsEnabled(false);
    if (!view_->browser()->GetWindow()->IsVisible()) view_->browser()->GetWindow()->ShowInactive();
    NSWindow* window = view_->GetNativeWindow().GetNativeNSWindow();
    if (cover && window && cover.isVisible) [window orderWindow:NSWindowBelow relativeTo:cover.windowNumber];
    if (cover_host) MatchWindowFrame(cover_host);
    concealed_ = false;
    if (widget) widget->SetOpacity(1.f);
    // Draw the new space's sidebar before it is uncovered.
    Snapshot();
    reveal_timeout_.Start(FROM_HERE, base::Milliseconds(400),
        base::BindOnce(&Impl::OnRevealReady, reveal_weak_factory_.GetWeakPtr()));
    if (auto* contents = tabs_ ? tabs_->GetActiveWebContents() : nullptr) {
      contents->GetPrimaryMainFrame()->InsertVisualStateCallback(base::BindOnce(
          [](base::WeakPtr<Impl> self, bool) { if (self) self->OnRevealReady(); },
          reveal_weak_factory_.GetWeakPtr()));
    }
  }
  void OnRevealReady() {
    reveal_ready_ = true;
    MaybeStartRevealFade();
  }
  void MaybeStartRevealFade() {
    if (!revealing_ || !reveal_ready_ || fade_timer_.IsRunning()) return;
    const base::TimeDelta wait = reveal_not_before_ - base::TimeTicks::Now();
    if (wait.is_positive()) {
      reveal_delay_.Start(FROM_HERE, wait,
          base::BindOnce(&Impl::MaybeStartRevealFade, reveal_weak_factory_.GetWeakPtr()));
      return;
    }
    reveal_timeout_.Stop();
    fade_start_ = base::TimeTicks::Now();
    fade_timer_.Start(FROM_HERE, base::Milliseconds(16), this, &Impl::RevealStep);
    RevealStep();
  }
  void RevealStep() {
    const double t = std::clamp(
        (base::TimeTicks::Now() - fade_start_).InSecondsF() / kSpaceFadeSeconds, 0.0, 1.0);
    const float opacity = kCoverOpacity * static_cast<float>(1 - t * t * (3 - 2 * t));
    for (auto& host : reveal_outgoing_) {
      if (!host) continue;
      if (auto* widget = host->view_->GetWidget()) widget->SetOpacity(opacity);
    }
    if (t >= 1.0) FinishReveal();
  }
  // Completes a reveal immediately: this window becomes the active one and
  // the outgoing windows are hidden at full opacity for their next use.
  void FinishReveal() {
    if (!revealing_) return;
    revealing_ = false;
    fade_timer_.Stop();
    reveal_timeout_.Stop();
    reveal_delay_.Stop();
    reveal_weak_factory_.InvalidateWeakPtrs();
    // Activating brings this window above the (now transparent) outgoing one.
    view_->browser()->GetWindow()->Activate();
    if (auto* widget = view_->GetWidget()) widget->SetVisibilityChangedAnimationsEnabled(true);
    for (auto& host : reveal_outgoing_) {
      if (!host || host.get() == this) continue;
      auto* widget = host->view_->GetWidget();
      if (host->group_ == group_ && !host->view_->browser()->IsDeleteScheduled()) {
        if (widget) widget->SetVisibilityChangedAnimationsEnabled(false);
        host->view_->browser()->GetWindow()->Hide();
        host->AwaitSpaceSwipeRelease();
        if (widget) widget->SetVisibilityChangedAnimationsEnabled(true);
      }
      if (widget) widget->SetOpacity(1.f);
      host->QueueSnapshot();  // Lets its sidebar reset a finished swipe.
    }
    reveal_outgoing_.clear();
    group_->transitions = std::max(0, group_->transitions - 1);
    RememberActiveSpace();
    ScheduleSpaceSwipe();
  }
  void ScheduleSpaceSwipe() {
    // Swift posts gesture commands on this same UI task runner. A candidate
    // that started just before Hide() gets to register before we consume its queue.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Impl::ContinueSpaceSwipe, weak_factory_.GetWeakPtr()));
  }
  void AwaitSpaceSwipeRelease() {
    const auto& handoff = group_->swipe_handoff;
    if (!handoff || !handoff->tracking || handoff->source_window != view_->browser()->GetSessionID().id()) return;
    // AppKit can omit the final event when a gesture's window is hidden.
    swipe_release_timeout_.Start(FROM_HERE, base::Seconds(3), base::BindOnce(
        &Impl::UpdateSpaceSwipe, weak_factory_.GetWeakPtr(), handoff->landing_space, false, nullptr));
  }
  // Run the follow-up on the sidebar that actually owns the visible Space.
  void ContinueSpaceSwipe() {
    auto& handoff = group_->swipe_handoff;
    if (!handoff || handoff->tracking || handoff->next_space.empty() || group_->closing || group_->transitions ||
        handoff->landing_space != active_space_ || !view_->browser()->GetWindow()->IsVisible() ||
        view_->browser()->IsDeleteScheduled() || handoff->source_window == view_->browser()->GetSessionID().id())
      return;
    const std::string next = std::move(handoff->next_space);
    handoff.reset();
    if (!tabs_ || tabs_->closing_all() || !SpaceBelongsHere(active_space_) || catalog_.IsHidden(active_space_) ||
        !catalog_.Find(next) || catalog_.IsHidden(next)) return;
    Snapshot();
    BarkSwiftSidebarSelectSpace(swift_, next.c_str());
  }
  void UpdateSpaceSwipe(const std::string& after, bool tracking, const std::string* next) {
    auto& handoff = group_->swipe_handoff;
    if (!handoff || handoff->source_window != view_->browser()->GetSessionID().id() ||
        handoff->landing_space != after) return;
    // The outgoing host can still own a finger gesture when the cover is
    // hidden. Its release may replace the destination queued by an earlier swipe.
    swipe_release_timeout_.Stop();
    handoff->tracking = tracking;
    if (tracking) {
      if (!view_->browser()->GetWindow()->IsVisible()) AwaitSpaceSwipeRelease();
      return;
    }
    if (next && catalog_.Find(*next) && !catalog_.IsHidden(*next))
      handoff->next_space = *next == after ? std::string() : *next;
    // FinishReveal handles a gesture received while this window still covers
    // the destination. An already-posted command may also arrive after Hide().
    if (!view_->browser()->GetWindow()->IsVisible()) {
      for (auto* host : Instances())
        if (host->group_ == group_ && host != this) host->ScheduleSpaceSwipe();
    }
  }
  // A new switch first completes any switch still in progress in the group.
  void SettleReveals() {
    for (auto* host : Instances())
      if (host->group_ == group_ && host->revealing_) host->FinishReveal();
  }
  void RestoreGroupPresentation() {
    if (!tabs_ || tabs_->closing_all() || group_->closing) return;
    if (group_->user_presented) { group_->restoring = false; return; }
    const auto* saved = g_browser_process->local_state()->GetDict(kWindowGroupsPref).FindString(group_->id);
    Impl* target = this;
    for (auto* host : Instances()) {
      if (host->group_ == group_ && saved && host->SpaceBelongsHere(*saved)) target = host;
    }
    if (saved && target->SpaceBelongsHere(*saved)) target->SelectLocalSpace(*saved);
    auto* window = target->view_->browser()->GetWindow();
    window->Show();
    for (auto* host : Instances()) {
      if (host != target && host->group_ == group_) {
        host->MatchWindowFrame(target);
        host->view_->browser()->GetWindow()->Hide();
      }
    }
    group_->restoring = false;
    target->RememberActiveSpace();
    target->QueueSnapshot();
  }
  void AdoptTabs() {
    if (IsPrivate() || !tabs_) return;
    EnsureProfileSpaces();
    if (!SpaceBelongsHere(active_space_)) active_space_ = catalog_.FirstForProfile(ProfileKey());
    // Only session-restored windows join an old logical window. Reopening a
    // closed tab in a separately created window must not merge the windows.
    for (int i = 0; i < tabs_->count(); ++i) {
      const std::string restored = TakeRestoredWindowGroup(tabs_->GetWebContentsAt(i));
      if (restored.empty() || restored_group_attached_) continue;
      restored_group_attached_ = true;
      group_->id = restored;
      for (auto* host : Instances()) {
        if (host != this && !host->IsPrivate() && host->group_->id == restored) {
          group_ = host->group_;
          break;
        }
      }
      group_->restoring = true;
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
          base::BindOnce(&Impl::RestoreGroupPresentation, weak_factory_.GetWeakPtr()), base::Milliseconds(250));
    }
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      if (!IsFavorite(contents) && !SpaceBelongsHere(GetTabSpace(contents))) AssignTab(contents, active_space_);
      else if (GetTabWindowGroup(contents) != group_->id) PersistTab(contents);
      if (tabs_->IsTabPinned(i)) {
        RememberPinnedPage(contents, false);
        BackfillPinnedPage(contents);
      }
    }
    if (auto* active = tabs_->GetActiveWebContents()) {
      const std::string space = GetTabSpace(active);
      if (SpaceBelongsHere(space)) {
        active_space_ = space;
        selected_tabs_[space] = sessions::SessionTabHelper::IdForTab(active).id();
      }
    }
    RememberActiveSpace();
  }
  void SelectLocalSpace(const std::string& id) {
    if (!tabs_ || tabs_->closing_all() || !SpaceBelongsHere(id) || catalog_.IsHidden(id)) return;
    if (group_->swipe_handoff && group_->swipe_handoff->landing_space != id)
      group_->swipe_handoff.reset();
    AdoptTabs();
    if (id != active_space_) just_closed_pin_.reset();
    OpenPendingTabs(id);
    active_space_ = id;
    // The tab last used in this space; without one (after a restart, or when
    // it closed), the space's most recently seen tab.
    const auto remembered = selected_tabs_.find(id);
    int selection = -1;
    double latest = -1;
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      if (GetTabSpace(contents) != id) continue;
      if (remembered != selected_tabs_.end() &&
          remembered->second == sessions::SessionTabHelper::IdForTab(contents).id()) {
        selection = i;
        break;
      }
      const double seen = ReadTabMeta(contents).FindDouble("lastActive").value_or(0);
      if (selection < 0 || seen > latest) { selection = i; latest = seen; }
    }
    if (selection >= 0) tabs_->ActivateTabAt(selection);
    else NavigateTo(GURL("about:blank"), true);
    QueueSnapshot();
  }
  void SwitchSpace(const std::string& id, base::TimeDelta slide_duration = {}) {
    if (IsPrivate() || switching_space_ || catalog_.IsHidden(id)) return;
    auto* space = catalog_.Find(id);
    if (!space || !space->FindString("profile")) return;
    const std::string profile_key = *space->FindString("profile");
    if (profile_key == ProfileKey()) {
      group_->swipe_handoff.reset();
      reveal_not_before_ = base::TimeTicks();
      SelectLocalSpace(id);
      return;
    }
    const base::FilePath path = ProfilePath(profile_key);
    if (path.empty()) return;
    group_->swipe_handoff = WindowGroup::SwipeHandoff{view_->browser()->GetSessionID().id(), id, {}};
    just_closed_pin_.reset();
    reveal_not_before_ = slide_duration.is_positive()
        ? base::TimeTicks::Now() + slide_duration : base::TimeTicks();
    switch_preview_space_ = slide_duration.is_positive() ? id : std::string();
    AdoptTabs();
    for (auto* host : Instances()) {
      if (host->group_ == group_ && host->ProfileKey() == profile_key &&
          !host->view_->browser()->IsDeleteScheduled()) {
        PresentSpace(id, host->view_->browser());
        return;
      }
    }
    switching_space_ = true;
    g_browser_process->profile_manager()->CreateProfileAsync(path,
        base::BindOnce(&Impl::OpenSpaceProfile, weak_factory_.GetWeakPtr(), id));
    QueueSnapshot();
  }
  // Loads a space's profile ahead of a likely switch (a swipe toward it), so
  // the switch does not wait for the profile to load from disk.
  void PrepareSpace(const std::string& id) {
    if (IsPrivate() || catalog_.IsHidden(id)) return;
    const auto* space = catalog_.Find(id);
    const std::string* profile_key = space ? space->FindString("profile") : nullptr;
    if (!profile_key || *profile_key == ProfileKey()) return;
    const base::FilePath path = ProfilePath(*profile_key);
    auto* manager = g_browser_process->profile_manager();
    if (path.empty() || manager->GetProfileByPath(path)) return;
    manager->CreateProfileAsync(path, base::DoNothing());
  }
  void OpenSpaceProfile(const std::string& id, Profile* profile) {
    if (!profile) {
      CancelSpaceHandoff(id);
      switching_space_ = false;
      QueueSnapshot();
      return;
    }
    bool separate_window = false;
    for (auto* host : Instances()) {
      if (host->view_->GetProfile() == profile && host->group_ != group_)
        separate_window = true;
    }
    // An explicitly opened second Bark window keeps its own group. Do not
    // take its tabs when this window first opens the same profile.
    if (!separate_window) PendingPresentation() = PendingSpacePresentation{profile->GetPath()};
    profiles::OpenBrowserWindowForProfile(
        base::BindOnce(&Impl::PresentSpace, weak_factory_.GetWeakPtr(), id),
        separate_window, false, false, profile);
  }
  void CancelSpaceHandoff(const std::string& id) {
    const auto& handoff = group_->swipe_handoff;
    if (handoff && handoff->source_window == view_->browser()->GetSessionID().id() &&
        handoff->landing_space == id) group_->swipe_handoff.reset();
  }
  void PresentSpace(const std::string& id, BrowserWindowInterface* browser) {
    switching_space_ = false;
    PendingPresentation().reset();
    if (!browser || browser->IsDeleteScheduled() || !tabs_ || tabs_->closing_all()) {
      CancelSpaceHandoff(id);
      QueueSnapshot();
      return;
    }
    Impl* target = nullptr;
    for (auto* host : Instances()) if (host->view_->browser() == browser) target = host;
    if (!target || target->IsPrivate() || !target->SpaceBelongsHere(id)) {
      CancelSpaceHandoff(id);
      if (target) target->Unconceal();
      return;
    }
    // One logical Bark window owns profile-bound Chromium hosts. Never move a
    // WebContents to a different BrowserContext or copy profile storage.
    if (auto previous_group = target->group_; previous_group != group_) {
      for (auto* host : Instances()) if (host->group_ == previous_group) {
        host->group_ = group_;
        if (host->tabs_) for (int i = 0; i < host->tabs_->count(); ++i)
          host->PersistTab(host->tabs_->GetWebContentsAt(i));
      }
    }
    SettleReveals();
    std::vector<base::WeakPtr<Impl>> outgoing;
    Impl* frame_source = this;
    for (auto* host : Instances()) {
      if (host != target && host->group_ == group_ && !host->IsPrivate() &&
          host->view_->browser()->GetWindow()->IsVisible()) {
        outgoing.push_back(host->weak_factory_.GetWeakPtr());
        frame_source = host;
      }
    }
    // Reveal only when the target is not already on screen at full opacity.
    const bool reveal = !outgoing.empty() &&
        (!browser->GetWindow()->IsVisible() || target->concealed_);
    target->width_ = width_; target->collapsed_ = collapsed_; target->revealed_ = false;
    target->SetSidebarPresentation(false);
    target->MatchWindowFrame(frame_source);
    target->view_->InvalidateLayout();
    target->SelectLocalSpace(id);
    group_->user_presented = true;
    group_->restoring = false;
    const base::TimeTicks not_before = reveal_not_before_;
    reveal_not_before_ = base::TimeTicks();
    if (reveal) {
      target->BeginReveal(std::move(outgoing), not_before);
    } else {
      target->Unconceal();
      browser->GetWindow()->Show();
      browser->GetWindow()->Activate();
      target->MatchWindowFrame(frame_source);
      for (auto& host : outgoing) if (host) {
        host->view_->browser()->GetWindow()->Hide();
        host->AwaitSpaceSwipeRelease();
      }
      target->RememberActiveSpace();
      target->ScheduleSpaceSwipe();
    }
    target->QueueSnapshot();
  }
  void CloseOtherHosts(BrowserWindowInterface*) {
    if (group_->closing) return;
    group_->swipe_handoff.reset();
    if (IsProfileDirectoryScheduledForDeletion(view_->GetProfile()->GetPath())) {
      // Chromium closes all windows of the deleted profile. Keep the other
      // profiles in this logical window accessible, including hidden Spaces.
      Impl* remaining = nullptr;
      for (auto* host : Instances()) {
        if (host->group_ != group_ || !host->tabs_ || host->tabs_->closing_all() ||
            host->view_->browser()->IsDeleteScheduled() ||
            IsProfileDirectoryScheduledForDeletion(host->view_->GetProfile()->GetPath())) continue;
        if (host->view_->browser()->GetWindow()->IsVisible()) return;
        if (!remaining) remaining = host;
      }
      if (remaining) {
        remaining->Unconceal();
        remaining->view_->browser()->GetWindow()->Show();
        remaining->RememberActiveSpace();
      }
      return;
    }
    group_->closing = true;
    std::vector<base::WeakPtr<Impl>> others;
    for (auto* host : Instances()) {
      if (host != this && host->group_ == group_) others.push_back(host->weak_factory_.GetWeakPtr());
    }
    for (auto& host : others) {
      if (!host || !host->tabs_ || host->view_->browser()->IsDeleteScheduled()) continue;
      // Chromium activates the owning tab when it presents a beforeunload
      // dialog. A handler that allows closing should leave its host hidden.
      chrome::CloseWindow(host->view_->browser());
    }
    // A cancelled beforeunload dialog leaves a usable group that can be
    // closed again later. No unload handlers are bypassed.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](std::shared_ptr<WindowGroup> group) { group->closing = false; }, group_));
  }
  static void ReceiveCommand(void* context, const char* json) {
    auto* self = static_cast<Impl*>(context);
    if (!json) return;
    // Swift can emit while rendering or a native menu is tracking. Dispatch on
    // Chromium's UI task runner, not within tab-strip observer notifications.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Impl::Command, self->weak_factory_.GetWeakPtr(),
                                 std::string(json)));
  }

  void QueueSnapshot() {
    if (snapshot_pending_) return;
    snapshot_pending_ = true;
    // A loading page reports tab changes many times a second, and each
    // snapshot is built on the UI thread. The first goes out at once; a burst
    // is then limited to one per interval.
    const base::TimeDelta wait = last_snapshot_ + base::Milliseconds(50) - base::TimeTicks::Now();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&Impl::Snapshot, weak_factory_.GetWeakPtr()),
        std::max(wait, base::TimeDelta()));
  }
  // Other windows of this logical window preview this window's spaces.
  void QueueGroupSnapshot() {
    QueueSnapshot();
    if (IsPrivate()) return;
    for (auto* host : Instances())
      if (host != this && host->group_ == group_ && !host->IsPrivate()) host->QueueSnapshot();
    // Other windows list this window's pins.
    for (auto* host : SiblingWindows()) host->QueueSnapshot();
  }

  void Snapshot() {
    snapshot_pending_ = false;
    last_snapshot_ = base::TimeTicks::Now();
    if (!tabs_ || tabs_->closing_all()) return;
    std::optional<std::string> destinations;
    for (auto& popup : popups_) {
      if (popup->kind == "little" && popup->swift) {
        if (!destinations) destinations = base::WriteJson(LittleDestinations(view_->GetProfile(), active_space_));
        if (destinations && *destinations != popup->destinations_json) {
          popup->space = active_space_;
          popup->destinations_json = *destinations;
          BarkSwiftPopupSetSpaces(popup->swift, destinations->c_str());
        }
      }
      if (!popup->swift || popup->kind != "peek") continue;
      const bool can_split = CanSplitPopup(popup.get());
      if (can_split != popup->can_split) {
        popup->can_split = can_split;
        BarkSwiftPopupSetCanSplit(popup->swift, can_split);
      }
    }
    InstallExtensionsMenu();
    auto state = MakeSnapshot();
    if (!IsPrivate() && !group_->closing && !group_->restoring && !switching_space_ &&
        catalog_.IsHidden(active_space_) && view_->browser()->GetWindow()->IsVisible()) {
      const auto replacement = VisibleSpaceExcept(active_space_);
      if (!replacement.empty()) SwitchSpace(replacement);
    }
    SaveSpacePreviews();
    if (auto json = base::WriteJson(state)) BarkSwiftSidebarUpdate(swift_, json->c_str());
  }

  // The live sidebar and its saved preview use the same labels and folder placement.
  void AddTabLabels(base::DictValue& tab, const base::DictValue& meta, int i) const {
    if (const auto* title = meta.FindString("title"); title && !title->empty()) tab.Set("customTitle", *title);
    if (const auto* folder = meta.FindString("folder"); folder && tabs_->IsTabPinned(i) &&
        HasFolder(GetTabSpace(tabs_->GetWebContentsAt(i)), *folder)) tab.Set("folder", *folder);
  }

  // Hide only unused blank hosts, not tabs navigating to their first page.
  bool IsBlankPlaceholder(int i) const {
    auto* contents = tabs_->GetWebContentsAt(i);
    if (tabs_->IsTabPinned(i) || tabs_->GetSplitForTab(i) || IsFavorite(contents)) return false;
    auto& controller = contents->GetController();
    const auto* pending = controller.GetPendingEntry();
    if (pending && !IsBlankPage(pending->GetVirtualURL())) return false;
    const auto* committed = controller.GetLastCommittedEntry();
    return controller.GetEntryCount() <= 1 && (!committed || IsBlankPage(committed->GetVirtualURL()));
  }

  // Encodes one tab-strip entry for the Swift projection.
  base::DictValue TabValue(int i, bool active) const {
    auto* contents = tabs_->GetWebContentsAt(i);
    base::DictValue tab;
    tab.Set("id", sessions::SessionTabHelper::IdForTab(contents).id());
    tab.Set("tabHandle", tabs_->GetTabAtIndex(i)->GetHandle().raw_value());
    tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
    tab.Set("url", contents->GetVisibleURL().spec());
    tab.Set("active", active);
    tab.Set("pinned", tabs_->IsTabPinned(i));
    tab.Set("blankPlaceholder", IsBlankPlaceholder(i));
    tab.Set("loading", contents->IsLoading());
    auto* audio = RecentlyAudibleHelper::FromWebContents(contents);
    tab.Set("audible", audio && audio->WasRecentlyAudible());
    tab.Set("muted", contents->IsAudioMuted());
    const auto meta = ReadTabMeta(contents);
    AddTabLabels(tab, meta, i);
    auto* entry = contents->GetController().GetLastCommittedEntry();
    auto favicon = FaviconPNG(entry, 262144);
    if (tabs_->IsTabPinned(i)) {
      const bool closed = IsDormantPin(contents);
      const auto* page = CachedPinPage(meta, contents->GetVisibleURL());
      if (page && (closed || contents->IsLoading())) {
        if (closed || !entry || entry->GetTitle().empty()) {
          if (const auto* title = page->FindString("title")) tab.Set("title", *title);
        }
        if (closed || favicon.empty()) {
          if (const auto* icon = page->FindString("favicon")) favicon = *icon;
        }
      }
      tab.Set("sessionClosed", closed);
      if (closed && contents == just_closed_pin_.get()) tab.Set("keepVisibleAfterClose", true);
      if (const auto* pinned = meta.FindString("pinnedURL")) {
        tab.Set("pinnedURL", *pinned);
        tab.Set("drifted", Drifted(contents, meta));
      }
    }
    // Both tabs of a split view are listed; the pair shown on screen is the
    // one containing the active tab.
    if (auto split = tabs_->GetSplitForTab(i)) {
      tab.Set("split", split->ToString());
      const int current = tabs_->active_index();
      tab.Set("splitActive", tabs_->ContainsIndex(current) && tabs_->GetSplitForTab(current) == split);
    }
    tab.Set("faviconValid", !favicon.empty());
    if (!favicon.empty()) tab.Set("favicon", std::move(favicon));
    return tab;
  }

  // MARK: Space profiles

  // Reopens tabs that were moved into this space from another profile.
  void OpenPendingTabs(const std::string& id) {
    if (IsPrivate() || !tabs_ || !SpaceBelongsHere(id)) return;
    for (const auto& value : catalog_.TakePendingTabs(id)) {
      const auto* tab = value.GetIfDict();
      const std::string* spec = tab ? tab->FindString("url") : nullptr;
      const GURL url = spec ? GURL(*spec) : GURL();
      if (!url.is_valid()) continue;
      NavigateParams params(view_->browser(), url, ui::PAGE_TRANSITION_LINK);
      params.disposition = WindowOpenDisposition::kNewBackgroundTab;
      if (tab->FindBool("pinned").value_or(false)) {
        const auto* title = tab->FindString("title");
        params.contents_to_insert = CreateLazyTab(view_->GetProfile(), url,
            title ? base::UTF8ToUTF16(*title) : std::u16string());
        params.tabstrip_add_types = ADD_PINNED;
      }
      Navigate(&params);
      auto* contents = params.navigated_or_inserted_contents.get();
      if (!contents) continue;
      AssignTab(contents, id);
      const int index = tabs_->GetIndexOfWebContents(contents);
      if (tab->FindBool("pinned").value_or(false) && index != TabStripModel::kNoTab)
        tabs_->SetTabPinned(index, true);
    }
  }

  // Assigns a space to another profile. A tab cannot move between profiles,
  // so the space's tabs reopen (by URL) in the new profile's window; sign-ins
  // and site data stay with the old profile.
  void MoveSpaceToProfile(const std::string& id, const std::string& profile_key) {
    if (IsPrivate()) return;
    const auto* space = catalog_.Find(id);
    if (!space || !space->FindString("profile") || ProfilePath(profile_key).empty()) return;
    const std::string old_key = *space->FindString("profile");
    if (old_key == profile_key) return;

    // Capture the tabs first: once the space moves, these hosts would adopt
    // them into another space of the old profile.
    base::ListValue moved;
    std::vector<std::pair<base::WeakPtr<Impl>, base::WeakPtr<content::WebContents>>> closing;
    bool showing = false;
    for (auto* host : Instances()) {
      if (host->group_ != group_ || host->IsPrivate() || host->ProfileKey() != old_key ||
          !host->tabs_ || host->tabs_->closing_all()) continue;
      if (host->active_space_ == id && host->view_->browser()->GetWindow()->IsVisible()) showing = true;
      for (int i = 0; i < host->tabs_->count(); ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        if (GetTabSpace(contents) != id) continue;
        const GURL& url = contents->GetLastCommittedURL().is_valid() ? contents->GetLastCommittedURL()
                                                                     : contents->GetVisibleURL();
        if (url.is_valid() && !url.IsAboutBlank() &&
            !(url.SchemeIs("chrome") && url.host() == "newtab")) {
          base::DictValue tab;
          tab.Set("url", url.spec());
          tab.Set("pinned", host->tabs_->IsTabPinned(i));
          moved.Append(std::move(tab));
        }
        closing.emplace_back(host->weak_factory_.GetWeakPtr(), contents->GetWeakPtr());
      }
    }
    if (!catalog_.SetProfile(id, profile_key, std::move(moved))) return;

    // Show the space in its new profile, or open its tabs there now if that
    // profile's window already belongs to this logical window.
    if (showing) {
      SwitchSpace(id);
    } else {
      for (auto* host : Instances()) {
        if (host->group_ == group_ && !host->IsPrivate() && host->ProfileKey() == profile_key) {
          host->OpenPendingTabs(id);
          host->QueueSnapshot();
          break;
        }
      }
    }

    for (auto& [host, contents] : closing) {
      if (!host || !contents || !host->tabs_ || host->tabs_->closing_all()) continue;
      // Never close a window's last tab: that would close the window (and
      // with it, this logical window). Leave a blank tab in a remaining space.
      if (host->tabs_->count() == 1) {
        host->EnsureProfileSpaces();
        const std::string fallback = host->catalog_.FirstForProfile(host->ProfileKey());
        NavigateParams params(host->view_->browser(), GURL("about:blank"), ui::PAGE_TRANSITION_TYPED);
        params.disposition = WindowOpenDisposition::kNewBackgroundTab;
        Navigate(&params);
        if (auto* blank = params.navigated_or_inserted_contents.get(); blank && !fallback.empty())
          host->AssignTab(blank, fallback);
      }
      const int index = host->tabs_->GetIndexOfWebContents(contents.get());
      if (index != TabStripModel::kNoTab) host->tabs_->CloseWebContentsAt(index, CLOSE_NONE);
    }
    for (auto* host : Instances())
      if (host->group_ == group_ && !host->IsPrivate()) host->QueueSnapshot();
  }

  // MARK: Address bar suggestions

  // This strip contains the window's tabs for every Space in its current profile.
  base::ListValue MatchOpenTabs(const std::string& query) const {
    if (!tabs_ || tabs_->closing_all()) return {};
    const auto terms = base::SplitString(base::i18n::ToLower(base::UTF8ToUTF16(query)), u" ",
                                         base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    const size_t limit = terms.empty() ? 5 : 3;
    struct Candidate { int index; base::TimeTicks last_active; };
    std::vector<Candidate> candidates;
    auto* current = tabs_->GetActiveWebContents();
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      const GURL& url = contents->GetVisibleURL();
      if (contents == current || IsBlankPlaceholder(i) || url.IsAboutBlank() || url.SchemeIs("chrome")) continue;
      const std::u16string haystack = base::i18n::ToLower(contents->GetTitle() + u" " + base::UTF8ToUTF16(url.spec()));
      if (std::ranges::all_of(terms, [&](const auto& term) { return haystack.find(term) != std::u16string::npos; }))
        candidates.push_back({i, contents->GetLastActiveTimeTicks()});
    }
    std::ranges::sort(candidates, std::greater<>(), &Candidate::last_active);
    base::ListValue items;
    for (const auto& candidate : candidates) {
      if (items.size() >= limit) break;
      auto item = TabValue(candidate.index, false);
      item.Set("kind", "tab");
      if (!IsPrivate()) {
        auto* contents = tabs_->GetWebContentsAt(candidate.index);
        const auto* space = catalog_.Find(GetTabSpace(contents));
        if (IsFavorite(contents)) item.Set("space", "Favorites");
        else if (space && space->FindString("name")) item.Set("space", *space->FindString("name"));
      }
      items.Append(std::move(item));
    }
    return items;
  }

  static bool IsActionQuery(const std::string& query) {
    return base::StartsWith(base::TrimWhitespaceASCII(query, base::TRIM_ALL), ">");
  }

  // Actions are regenerated before execution, so their availability and targets
  // never depend on a stale row left in the command bar.
  base::ListValue CommandBarActions() {
    base::ListValue items;
    auto* target = tabs_->GetActiveWebContents();
    const int index = tabs_->active_index();
    const int target_id = target ? sessions::SessionTabHelper::IdForTab(target).id() : -1;
    const std::string context_url = target ? target->GetVisibleURL().spec() : "";
    const std::string page = target ? base::UTF16ToUTF8(target->GetTitle()) : std::string();
    const std::string page_detail = page.empty() ? "Current page" : page;
    auto add = [&](const std::string& key, const std::string& title, const std::string& detail,
                   const char* symbol, const char* action, bool targets_page = false,
                   const std::string& argument = std::string()) {
      base::DictValue item;
      item.Set("kind", "command"); item.Set("url", ""); item.Set("title", title);
      item.Set("commandID", key); item.Set("detail", detail); item.Set("symbol", symbol);
      item.Set("action", action); item.Set("argument", argument); item.Set("targetsPage", targets_page);
      item.Set("id", target_id); item.Set("contextURL", context_url);
      item.Set("contextSpace", active_space_); item.Set("invokerID", target_id);
      item.Set("invokerURL", context_url);
      items.Append(std::move(item));
    };
    add("settings", "Settings", "Bark preferences · ⌘,", "slider.horizontal.3", "settings");
    if (!IsPrivate()) {
      add("newLittleWindow", "New Little Window", "Quick lookup · ⌥⌘N", "macwindow.badge.plus", "newLittleWindow");
      add("newFolder", "New Folder", "In this space", "folder.badge.plus", "newFolder", false, "New Folder");
      add("archive", "Archived Tabs", "Search and restore tabs in this space", "archivebox", "");
      if (!organization_undo_.empty() && organization_undo_.back().space == active_space_)
        add("undoOrganization", "Undo " + organization_undo_.back().label,
            "Undo the last organization change · ⌥⌘Z", "arrow.uturn.backward", "undoOrganization");
    }
    const bool page_available = target && tabs_->ContainsIndex(index) && !IsBlankPage(PageURL(target));
    if (page_available) {
      const bool pinned = tabs_->IsTabPinned(index);
      if (!IsPrivate())
        add(pinned ? "unpin" : "pin", pinned ? "Unpin Tab" : "Pin Tab", page_detail, pinned ? "pin.slash" : "pin", "pin", true);
      if (tabs_->GetSplitForTab(index)) {
        add("unsplit", "Separate Split View", page_detail, "rectangle", "unsplit", true);
      } else if (!IsFavorite(target)) {
        add("splitNew", "Split View", "Choose a page beside " + page_detail, "rectangle.split.2x1", "splitNew", true);
      }
      if (!IsPrivate() && !IsFavorite(target)) for (const auto& value : catalog_.List()) {
        const auto& space = value.GetDict();
        const auto* id = space.FindString("id");
        const auto* profile = space.FindString("profile");
        const auto* name = space.FindString("name");
        if (id && name && profile && *profile == ProfileKey() && *id != active_space_)
          add("move:" + *id, "Move to " + *name, page_detail, "arrow.right.square", "moveTabToSpace", true, *id);
      }
      if (auto* container = ExtensionsContainer::From(*view_->browser())) {
        if (auto* model = ToolbarActionsModel::Get(view_->GetProfile())) for (const auto& id : model->action_ids()) {
          if (auto* action = container->GetActionForId(id); action && action->IsEnabled(target))
            add("extension:" + id, base::UTF16ToUTF8(action->GetActionName()),
                "Extension · " + page_detail, "puzzlepiece.extension", "activateExtension", true, id);
        }
      }
    }
    add("toggleSidebar", "Toggle Sidebar", "Show or hide the sidebar · ⌘S", "sidebar.left", "toggleSidebar");
    add("downloads", "Downloads", "View downloaded files", "arrow.down.circle", "downloads");
    add("history", "History", "View browsing history", "clock", "history");
    add("extensions", "Manage Extensions", "Manage this profile’s extensions", "puzzlepiece.extension", "extensions");
    return items;
  }

  base::ListValue CommandSuggestions(const std::string& input) {
    std::string query(base::TrimWhitespaceASCII(input, base::TRIM_ALL));
    if (IsActionQuery(query)) query = base::TrimWhitespaceASCII(query.substr(1), base::TRIM_ALL);
    const auto lower = base::i18n::ToLower(base::UTF8ToUTF16(query));
    const auto terms = base::SplitString(lower, u" ", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    struct Match { int rank; base::DictValue item; };
    std::vector<Match> matches;
    for (auto& value : CommandBarActions()) {
      auto& item = value.GetDict();
      const auto title = base::i18n::ToLower(base::UTF8ToUTF16(*item.FindString("title")));
      std::u16string aliases;
      const auto& key = *item.FindString("commandID");
      if (key == "settings") aliases = u" preferences options";
      if (key == "archive") aliases = u" archive restore closed tabs";
      if (base::StartsWith(key, "extension:")) aliases = u" extension";
      const auto haystack = title + aliases;
      if (!std::ranges::all_of(terms, [&](const auto& term) { return haystack.find(term) != std::u16string::npos; })) continue;
      const int rank = lower.empty() ? 3 : title == lower ? 0 : base::StartsWith(title, lower) ? 1 : 2;
      matches.push_back({rank, std::move(item)});
    }
    std::stable_sort(matches.begin(), matches.end(), [](const auto& a, const auto& b) { return a.rank < b.rank; });
    base::ListValue result;
    for (auto& match : matches) result.Append(std::move(match.item));
    return result;
  }

  void RunCommandBarAction(const base::DictValue& request) {
    const auto* key = request.FindString("text");
    const auto* context = request.FindDict("metadata");
    const auto* url = context ? context->FindString("url") : nullptr;
    const auto* space = context ? context->FindString("space") : nullptr;
    const auto* invoker = context ? context->FindString("invoker") : nullptr;
    const auto* invoker_url = context ? context->FindString("invokerURL") : nullptr;
    int invoker_id = -1;
    if (!key || !url || !space || !invoker || !invoker_url || !base::StringToInt(*invoker, &invoker_id)) return;
    for (const auto& value : CommandBarActions()) {
      const auto& item = value.GetDict();
      if (*item.FindString("commandID") != *key || item.FindInt("id") != request.FindInt("id") ||
          *item.FindString("contextURL") != *url || *item.FindString("contextSpace") != *space ||
          item.FindInt("invokerID") != invoker_id || *item.FindString("invokerURL") != *invoker_url) continue;
      const auto& action = *item.FindString("action");
      if (action.empty()) return;  // Native Swift presentation, not a browser command.
      const int index = FindTab(item.FindInt("id").value_or(-1));
      if (item.FindBool("targetsPage").value_or(false)) {
        if (!tabs_->ContainsIndex(index)) return;
        tabs_->ActivateTabAt(index);
      }
      base::DictValue command;
      command.Set("action", action);
      command.Set("id", item.FindInt("id").value_or(-1));
      command.Set("text", *item.FindString("argument"));
      base::DictValue metadata;
      metadata.Set("url", tabs_->ContainsIndex(index) ? PageURL(tabs_->GetWebContentsAt(index)).spec() : *url);
      command.Set("metadata", std::move(metadata));
      if (auto json = base::WriteJson(command)) Command(*json);
      return;
    }
  }

  void Suggest(const std::string& query) {
    suggest_query_ = query;
    const bool empty = base::TrimWhitespaceASCII(query, base::TRIM_ALL).empty();
    if (empty || IsActionQuery(query)) {
      if (autocomplete_) autocomplete_->Stop(AutocompleteStopReason::kClobbered);
      // A fresh address bar session starts without stale favicon lookups.
      if (empty) {
        suggestion_favicon_tasks_.TryCancelAll();
        suggestion_favicons_.clear();
      }
    } else {
      if (!autocomplete_) {
        // History only: no search provider, so typing is not sent to a
        // search engine while the address bar is open.
        autocomplete_ = std::make_unique<AutocompleteController>(
            std::make_unique<ChromeAutocompleteProviderClient>(view_->GetProfile()),
            AutocompleteControllerConfig{
                .provider_types = static_cast<int>(AutocompleteProvider::Type::kHistoryQuick) |
                                  static_cast<int>(AutocompleteProvider::Type::kHistoryUrl)});
        autocomplete_->AddObserver(this);
      }
      AutocompleteInput input(base::UTF8ToUTF16(query), metrics::OmniboxEventProto::OTHER,
                              ChromeAutocompleteSchemeClassifier(view_->GetProfile()));
      input.set_prevent_inline_autocomplete(true);
      autocomplete_->Start(input);
    }
    SendSuggestions();
  }

  void OnResultChanged(AutocompleteController*, bool) override { SendSuggestions(); }

  // Returns the history favicon for a suggestion's page, starting a lookup the
  // first time a page is seen. Results refresh the list when they arrive.
  const std::string& SuggestionFavicon(const GURL& url) {
    auto [it, inserted] = suggestion_favicons_.try_emplace(url.spec());
    if (!inserted) return it->second;
    auto* favicons = FaviconServiceFactory::GetForProfile(view_->GetProfile(), ServiceAccessType::IMPLICIT_ACCESS);
    if (!favicons) return it->second;
    favicons->GetFaviconImageForPageURL(url, base::BindOnce([](base::WeakPtr<Impl> self, const std::string& spec,
        const favicon_base::FaviconImageResult& result) {
      if (!self) return;
      auto it = self->suggestion_favicons_.find(spec);
      if (it == self->suggestion_favicons_.end()) return;
      it->second = SuggestionFaviconPNG(result.image, 16384);
      if (!it->second.empty() && !base::TrimWhitespaceASCII(self->suggest_query_, base::TRIM_ALL).empty())
        self->SendSuggestions();
    }, weak_factory_.GetWeakPtr(), url.spec()), &suggestion_favicon_tasks_);
    return it->second;
  }

  void SendSuggestions() {
    constexpr size_t kMaxSuggestions = 8;
    const bool empty = base::TrimWhitespaceASCII(suggest_query_, base::TRIM_ALL).empty();
    const bool actions_only = IsActionQuery(suggest_query_);
    base::ListValue items;
    auto commands = CommandSuggestions(suggest_query_);
    auto append_commands = [&](size_t limit) {
      for (auto& command : commands) {
        if (items.size() >= limit) break;
        items.Append(std::move(command));
      }
    };
    if (actions_only) {
      append_commands(kMaxSuggestions);
    } else if (!empty) {
      append_commands(3);
      for (auto& tab : MatchOpenTabs(suggest_query_)) items.Append(std::move(tab));
    } else {
      items = MatchOpenTabs(suggest_query_);
      append_commands(kMaxSuggestions);
    }
    std::set<std::string> seen;
    for (const auto& item : items) seen.insert(*item.GetDict().FindString("url"));
    if (!empty && !actions_only && autocomplete_) {
      for (const auto& match : autocomplete_->result()) {
        if (items.size() >= kMaxSuggestions) break;
        const GURL& url = match.destination_url;
        if (!url.is_valid() || !seen.insert(url.spec()).second) continue;
        base::DictValue item;
        const bool typed = match.type == omnibox::AutocompleteMatchType::kUrlWhatYouTyped;
        item.Set("kind", typed ? "url" : "history");
        item.Set("title", base::UTF16ToUTF8(typed ? match.contents : match.description));
        item.Set("url", url.spec());
        const std::string& favicon = SuggestionFavicon(url);
        if (!favicon.empty()) {
          item.Set("favicon", favicon);
          item.Set("faviconValid", true);
        }
        items.Append(std::move(item));
      }
    }
    base::DictValue message;
    message.Set("query", suggest_query_);
    const auto destination = ResolveAddress(suggest_query_, view_->GetProfile());
    message.Set("action", actions_only ? "command" : destination.is_search ? "search" : "navigate");
    if (!actions_only && destination.is_search && !destination.engine_name.empty())
      message.Set("searchEngine", base::UTF16ToUTF8(destination.engine_name));
    message.Set("items", std::move(items));
    if (auto json = base::WriteJson(message)) BarkSwiftSidebarSuggestions(swift_, json->c_str());
  }

  // A transition shows live tabs from this logical window when the profile is
  // open, or its saved preview until the new window is ready.
  base::ListValue SpacePreview(const std::string& space_id, const std::string& profile_key) const {
    constexpr int kPreviewTabLimit = 30;
    base::ListValue preview;
    for (auto* host : Instances()) {
      if (host->group_ != group_ || host->IsPrivate() || host->ProfileKey() != profile_key ||
          !host->tabs_ || host->tabs_->closing_all()) continue;
      auto selected = host->selected_tabs_.find(space_id);
      for (int i = 0; i < host->tabs_->count() && static_cast<int>(preview.size()) < kPreviewTabLimit; ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        if (GetTabSpace(contents) != space_id || host->IsBlankPlaceholder(i)) continue;
        const bool active = host->active_space_ == space_id
            ? host->tabs_->active_index() == i
            : selected != host->selected_tabs_.end() &&
                  selected->second == sessions::SessionTabHelper::IdForTab(contents).id();
        preview.Append(host->TabValue(i, active));
      }
      return preview;
    }
    // The profile's window is not open yet: show the tabs the space had when
    // it was last used (or tabs waiting to reopen there).
    int placeholder_id = -1;
    for (const auto& value : catalog_.SavedPreview(space_id)) {
      const auto* saved = value.GetIfDict();
      if (static_cast<int>(preview.size()) >= kPreviewTabLimit) break;
      if (!saved || !saved->FindString("url")) continue;
      const bool pinned = saved->FindBool("pinned").value_or(false);
      if (saved->FindBool("blankPlaceholder").value_or(
              !pinned && !saved->FindString("split") && IsBlankPage(GURL(*saved->FindString("url"))))) continue;
      base::DictValue tab;
      tab.Set("id", placeholder_id--);
      tab.Set("title", saved->FindString("title") ? *saved->FindString("title") : std::string());
      tab.Set("url", *saved->FindString("url"));
      tab.Set("active", saved->FindBool("active").value_or(false));
      tab.Set("pinned", pinned);
      tab.Set("blankPlaceholder", false);
      tab.Set("loading", false);
      for (const char* key : {"customTitle", "folder", "split"})
        if (const auto* label = saved->FindString(key)) tab.Set(key, *label);
      preview.Append(std::move(tab));
    }
    return preview;
  }

  // Saves the tabs of this window's spaces so other windows can preview them
  // during a swipe even after a restart, before this profile's window opens.
  void SaveSpacePreviews() {
    if (IsPrivate() || !tabs_ || tabs_->closing_all() || group_->restoring) return;
    std::map<std::string, base::ListValue> by_space;
    const std::string profile_key = ProfileKey();
    for (const auto& value : catalog_.List()) {
      const auto* entry = value.GetIfDict();
      const auto* id = entry ? entry->FindString("id") : nullptr;
      const auto* profile = entry ? entry->FindString("profile") : nullptr;
      if (id && profile && *profile == profile_key) by_space.try_emplace(*id);
    }
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      const std::string space = GetTabSpace(contents);
      const auto found = by_space.find(space);
      if (found == by_space.end() || found->second.size() >= 30 || IsBlankPlaceholder(i)) continue;
      const GURL& url = contents->GetVisibleURL();
      base::DictValue tab;
      tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
      tab.Set("url", url.spec());
      tab.Set("pinned", tabs_->IsTabPinned(i));
      tab.Set("blankPlaceholder", false);
      if (auto split = tabs_->GetSplitForTab(i)) tab.Set("split", split->ToString());
      AddTabLabels(tab, ReadTabMeta(contents), i);
      auto selected = selected_tabs_.find(space);
      tab.Set("active", space == active_space_ ? tabs_->active_index() == i
                        : selected != selected_tabs_.end() &&
                              selected->second == sessions::SessionTabHelper::IdForTab(contents).id());
      found->second.Append(std::move(tab));
    }
    // SetPreviewTabs can replace the preference list that catalog_.List() references.
    for (auto& [id, tabs] : by_space) catalog_.SetPreviewTabs(id, std::move(tabs));
  }

  static bool ShowNativePreferences(BrowserWindowInterface* browser) {
    for (auto* host : Instances()) {
      if (host->view_->browser() == browser && host->swift_) {
        BarkSwiftSidebarShowPreferences(host->swift_);
        return true;
      }
    }
    return false;
  }

  bool PictureInPictureEditable() const {
    auto* settings = ContentSettings();
    if (!settings || IsPrivate()) return false;
    HostContentSettingsMap::ProviderType source;
    settings->GetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE, &source);
    return source == content_settings::ProviderType::kPrefProvider ||
           source == content_settings::ProviderType::kDefaultProvider;
  }

  base::DictValue PreferencesState() const {
    base::DictValue result;
    auto* profile = view_->GetProfile();
    result.Set("profileId", ProfileKey());
    base::ListValue engines;
    std::string current;
    auto* service = TemplateURLServiceFactory::GetForProfile(profile);
    if (service) {
      const auto* selected = service->GetDefaultSearchProvider();
      if (selected) current = base::NumberToString(selected->id().value());
      if (service->loaded()) for (const auto& handle : service->GetTemplateURLs()) {
        auto* engine = handle.get();
        if (engine != selected && !service->CanMakeDefault(engine)) continue;
        base::DictValue item;
        item.Set("id", base::NumberToString(engine->id().value()));
        item.Set("name", base::UTF16ToUTF8(engine->short_name()));
        engines.Append(std::move(item));
      }
      // Before its asynchronous load, show the effective selection read-only.
      if (!service->loaded() && selected) {
        base::DictValue item;
        item.Set("id", current);
        item.Set("name", base::UTF16ToUTF8(selected->short_name()));
        engines.Append(std::move(item));
      }
    }
    result.Set("searchEngines", std::move(engines));
    result.Set("searchEngine", current);
    result.Set("searchLoaded", service && service->loaded());
    result.Set("searchEditable", service && service->CanDefaultSearchProviderBeModifiedByUser());
    auto* downloads = DownloadPrefs::FromBrowserContext(profile);
    auto* pref_service = profile->GetPrefs();
    result.Set("downloadPath", downloads ? downloads->DownloadPath().AsUTF8Unsafe() : std::string());
    result.Set("downloadEditable", downloads && !downloads->IsDownloadPathManaged() &&
        pref_service->IsUserModifiablePreference(prefs::kDownloadDefaultDirectory));
    result.Set("askDownload", downloads && downloads->PromptForDownload());
    result.Set("askDownloadEditable", downloads && !downloads->IsDownloadPathManaged() &&
        pref_service->IsUserModifiablePreference(prefs::kPromptForDownload));
    result.Set("pictureInPictureEditable", PictureInPictureEditable());
    return result;
  }

  void SetPreference(const base::DictValue& message) {
    const auto* metadata = message.FindDict("metadata");
    const auto* expected_profile = metadata ? metadata->FindString("profile") : nullptr;
    const auto* key = metadata ? metadata->FindString("key") : nullptr;
    const auto* value = message.FindString("text");
    if (!expected_profile || *expected_profile != ProfileKey() || !key || !value || IsPrivate()) return;
    auto* profile = view_->GetProfile();
    auto* pref_service = profile->GetPrefs();
    if (*key == "searchEngine") {
      auto* service = TemplateURLServiceFactory::GetForProfile(profile);
      if (!service || !service->loaded() || !service->CanDefaultSearchProviderBeModifiedByUser()) return;
      for (const auto& handle : service->GetTemplateURLs()) {
        auto* engine = handle.get();
        if (base::NumberToString(engine->id().value()) == *value && service->CanMakeDefault(engine)) {
          service->SetUserSelectedDefaultSearchProvider(engine);
          break;
        }
      }
    } else if (*key == "downloadPath") {
      auto* downloads = DownloadPrefs::FromBrowserContext(profile);
      const base::FilePath path(*value);
      if (!downloads || downloads->IsDownloadPathManaged() ||
          !pref_service->IsUserModifiablePreference(prefs::kDownloadDefaultDirectory) ||
          !path.IsAbsolute() || path.ReferencesParent()) return;
      downloads->SetDownloadPath(path);
    } else if (*key == "askDownload" && (*value == "on" || *value == "off")) {
      auto* downloads = DownloadPrefs::FromBrowserContext(profile);
      if (!downloads || downloads->IsDownloadPathManaged() ||
          !pref_service->IsUserModifiablePreference(prefs::kPromptForDownload)) return;
      pref_service->SetBoolean(prefs::kPromptForDownload, *value == "on");
    }
    for (auto* host : Instances()) if (host->view_->GetProfile() == profile) host->QueueSnapshot();
  }

  base::DictValue MakeSnapshot() {
    AdoptTabs();
    base::ListValue tab_list;
    base::ListValue favorites;
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      if (IsFavorite(contents)) favorites.Append(TabValue(i, tabs_->active_index() == i));
      if (!IsPrivate() && GetTabSpace(contents) != active_space_) continue;
      tab_list.Append(TabValue(i, tabs_->active_index() == i));
    }
    for (auto* host : SiblingWindows()) {
      for (int i = 0; i < host->tabs_->count() && host->tabs_->IsTabPinned(i); ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        const bool favorite = host->IsFavorite(contents);
        if (!favorite && GetTabSpace(contents) != active_space_) continue;
        auto tab = host->TabValue(i, false);
        tab.Set("elsewhere", host->view_->browser()->GetSessionID().id());
        (favorite ? favorites : tab_list).Append(std::move(tab));
      }
    }
    auto* profile = view_->GetProfile();
    const bool incognito = profile->IsOffTheRecord();
    base::ListValue spaces;
    base::ListValue profile_list;
    for (auto* entry : profiles_->GetAllProfilesAttributesSortedForDisplay()) {
      if (incognito || entry->IsOmitted()) continue;
      base::DictValue info;
      info.Set("id", entry->GetPath().BaseName().AsUTF8Unsafe());
      std::string name = base::UTF16ToUTF8(entry->GetName());
      info.Set("name", name == "Your Chromium" || name == "Your Bark" ? "Personal" : name);
      profile_list.Append(std::move(info));
    }
    if (!incognito) for (const auto& value : catalog_.List()) {
      const auto* item = value.GetIfDict();
      if (!item || !item->FindString("id") || !item->FindString("profile") ||
          item->FindBool("hidden").value_or(false) ||
          ProfilePath(*item->FindString("profile")).empty()) continue;
      auto space = item->Clone();
      for (const char* key : {"pendingTabs", "previewTabs", "archivedTabs", "arcTabIds", "arcSource", "arcProfile"}) space.Remove(key);
      space.Set("active", *item->FindString("id") == active_space_);
      spaces.Append(std::move(space));
    }
    // Swipes reveal neighboring spaces. A dock selection can slide directly to
    // any space, including one in a different profile's window.
    if (!switching_space_ && group_->transitions == 0) switch_preview_space_.clear();
    base::DictValue previews;
    for (size_t i = 0; i < spaces.size(); ++i) {
      const auto& space = spaces[i].GetDict();
      const std::string& id = *space.FindString("id");
      const bool adjacent = (i > 0 && spaces[i - 1].GetDict().FindBool("active").value_or(false)) ||
          (i + 1 < spaces.size() && spaces[i + 1].GetDict().FindBool("active").value_or(false));
      if (adjacent || id == switch_preview_space_)
        previews.Set(id, SpacePreview(id, *space.FindString("profile")));
    }
    base::DictValue state;
    if (!incognito && browser_import_result_) state.Set("browserImportResult", browser_import_result_->Clone());
    state.Set("sidebarCollapsed", collapsed_);
    state.Set("sidebarRevealed", revealed_);
    state.Set("sidebarWidth", width_);
    state.Set("tabs", std::move(tab_list));
    state.Set("archiveGeneration", archive_generation_);
    state.Set("favorites", std::move(favorites));
    state.Set("downloads", DownloadState());
    if (preferences_open_ && !incognito) state.Set("preferences", PreferencesState());
    if (!organization_undo_.empty() && organization_undo_.back().space == active_space_)
      state.Set("organizationUndoLabel", organization_undo_.back().label);
    if (auto media = MediaState(); !media.empty()) state.Set("media", std::move(media));
    if (!incognito) {
      base::DictValue features;
      features.Set("archiveAfterHours", ArchiveAfterHours());
      features.Set("peek", PeekEnabled());
      features.Set("littleWindow", LittleWindowEnabled());
      features.Set("globalLittleShortcut", GlobalLittleShortcutEnabled());
      if (GlobalLittleShortcut::Get().unavailable()) features.Set("globalLittleShortcutUnavailable", true);
      features.Set("autoPictureInPicture", AutoPictureInPictureAllowed());
      state.Set("features", std::move(features));
    }
    if (!incognito) {
      const auto* space = catalog_.Find(active_space_);
      const auto* archived = space ? space->FindList("archivedTabs") : nullptr;
      state.Set("archivedTabs", archived ? archived->Clone() : base::ListValue());
    }
    state.Set("spaces", std::move(spaces));
    state.Set("spacePreviews", std::move(previews));
    state.Set("incognito", incognito);
    state.Set("profiles", std::move(profile_list));
    state.Set("profileId", ProfileKey());
    state.Set("activeSpaceId", active_space_);
    state.Set("switchingSpace", switching_space_);
    switch (ThemeServiceFactory::GetForProfile(profile)->GetBrowserColorScheme()) {
      case ThemeService::BrowserColorScheme::kLight: state.Set("appearance", "light"); break;
      case ThemeService::BrowserColorScheme::kDark: state.Set("appearance", "dark"); break;
      default: state.Set("appearance", "system"); break;
    }
    state.Set("windowVisible", view_->browser()->GetWindow()->IsVisible());
    state.Set("profile", profile->GetPath().AsUTF8Unsafe());
    // A queued snapshot can run after the last tab closes but before its
    // native window is destroyed. Chromium's forward helper requires a tab.
    auto* active = tabs_->GetActiveWebContents();
    state.Set("canGoBack", active && chrome::CanGoBack(active));
    state.Set("canGoForward", active && chrome::CanGoForward(active));
    state.Set("notices", NoticesState(active));
    if (active) {
      if (site_controls_open_) state.Set("siteControls", SiteControlsState(active));
      if (auto* location = LocationBarModel::From(view_->browser())) {
        const auto security = location->GetSecurityLevel();
        state.Set("securityLevel", security == security_state::DANGEROUS ? "dangerous" :
            security == security_state::WARNING ? "warning" :
            security == security_state::SECURE ? "secure" : "neutral");
        state.Set("securityDescription", base::UTF16ToUTF8(location->GetSecureAccessibilityText()));
      }
    }
    return state;
  }

  int FindTab(int id) const {
    for (int i = 0; i < tabs_->count(); ++i) {
      if (sessions::SessionTabHelper::IdForTab(tabs_->GetWebContentsAt(i)).id() == id) return i;
    }
    return -1;
  }

  // Tabs listed in the sidebar: the active space's, or all in a private window.
  bool InActiveSpace(int index) const {
    return IsPrivate() || GetTabSpace(tabs_->GetWebContentsAt(index)) == active_space_;
  }
  bool IsFavorite(content::WebContents* contents) const {
    return !IsPrivate() && GetTabSpace(contents) == kFavoritesSpace;
  }

  // Before a tab leaves this window, show another of the space's tabs.
  void SelectAwayFrom(content::WebContents* contents) {
    if (tabs_->GetActiveWebContents() != contents) return;
    int next = -1;
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* candidate = tabs_->GetWebContentsAt(i);
      if (candidate == contents || (!InActiveSpace(i) && !IsFavorite(candidate)) ||
          candidate->GetController().NeedsReload()) continue;
      if (next < 0 || (tabs_->IsTabPinned(next) && !tabs_->IsTabPinned(i))) next = i;
    }
    if (next >= 0) tabs_->ActivateTabAt(next);
    // Keep the source workspace (including its other profile hosts) alive
    // without waking a dormant pin when its last open tab leaves.
    else NavigateTo(GURL("about:blank"), true);
  }

  // Other Bark windows of this profile, which can hold this space's pins
  // and Favorites. One live tab can be in only one window.
  std::vector<Impl*> SiblingWindows() const {
    std::vector<Impl*> windows;
    if (IsPrivate()) return windows;
    for (auto* host : Instances()) {
      if (host == this || host->IsPrivate() || host->view_->GetProfile() != view_->GetProfile() ||
          !host->tabs_ || host->tabs_->closing_all() || host->view_->browser()->IsDeleteScheduled() ||
          host->group_->closing) continue;
      windows.push_back(host);
    }
    return windows;
  }

  // Moves a pin or Favorite that is open in another window into this one,
  // with its live page, history and session, and shows it here.
  void ClaimTab(int window_id, int tab_id) {
    if (IsPrivate() || !tabs_ || tabs_->closing_all() || group_->closing) return;
    Impl* source = nullptr;
    for (auto* host : SiblingWindows())
      if (host->view_->browser()->GetSessionID().id() == window_id) source = host;
    if (!source) return;
    int index = source->FindTab(tab_id);
    if (!source->tabs_->ContainsIndex(index) || !source->tabs_->IsTabPinned(index)) return;
    auto* contents = source->tabs_->GetWebContentsAt(index);
    const std::string space = GetTabSpace(contents);
    if (space != kFavoritesSpace && space != active_space_) return;
    source->AdoptTabs();
    AdoptTabs();
    source->Unsplit(index);
    source->SelectAwayFrom(contents);
    index = source->tabs_->GetIndexOfWebContents(contents);
    if (index == TabStripModel::kNoTab) return;
    chrome::MoveTabsToExistingWindow(source->view_->browser(), view_->browser(), {index});
    index = tabs_->GetIndexOfWebContents(contents);
    if (index == TabStripModel::kNoTab) return;
    if (!tabs_->IsTabPinned(index)) index = tabs_->SetTabPinned(index, true);
    AdoptTabs();
    // Rewrite the saved window membership, as for a tab moved to a new window.
    PersistTab(contents);
    if (auto* session = SessionServiceFactory::GetForProfileIfExisting(view_->GetProfile()))
      session->TrackWindowAfterTabMove(view_->browser());
    tabs_->ActivateTabAt(tabs_->GetIndexOfWebContents(contents));
    contents->Focus();
    QueueGroupSnapshot();
    source->QueueGroupSnapshot();
  }

  // Move the real tab into an empty, independent browser of the same profile.
  // No startup/session tabs are copied into this window.
  void DetachTabToWindow(int index, std::optional<NSPoint> drop_point,
                         base::OnceClosure before_move_for_testing = {}) {
    if (!tabs_->ContainsIndex(index) || group_->closing ||
        (!InActiveSpace(index) && !IsFavorite(tabs_->GetWebContentsAt(index)))) return;
    AdoptTabs();
    auto* contents = tabs_->GetWebContentsAt(index);
    auto* source = view_->browser();
    BrowserWindowCreateParams params(source->GetProfile(), true);
    params.should_trigger_session_restore = false;
    params.initial_bounds = source->GetWindow()->GetBounds();
    params.initial_bounds.Offset(32, 32);
    auto* destination = CreateBrowserWindow(std::move(params));
    if (!destination) return;
    Impl* target = nullptr;
    for (auto* host : Instances()) if (host->view_->browser() == destination) target = host;
    if (!target) { destination->GetWindow()->Close(); return; }
    target->active_space_ = active_space_;
    target->group_->user_presented = true;
    target->restored_group_attached_ = true;

    // Detaching one half leaves its partner in the original window. Even a
    // dragged pin/Favorite becomes an ordinary tab in the destination.
    Unsplit(index);
    index = tabs_->GetIndexOfWebContents(contents);
    if (tabs_->IsTabPinned(index)) index = tabs_->SetTabPinned(index, false);
    if (!IsPrivate()) SetTabSpace(contents, active_space_);
    SelectAwayFrom(contents);
    index = tabs_->GetIndexOfWebContents(contents);
    if (before_move_for_testing) std::move(before_move_for_testing).Run();
    chrome::MoveTabsToExistingWindow(source, destination, {index});
    target->AdoptTabs();
    // Chromium transfers the tab's saved extra data as well as its live
    // WebContents. Rewrite that saved membership in the destination session
    // so a restart cannot put this window back into the source's group.
    if (!target->IsPrivate()) {
      target->PersistTab(contents);
      if (auto* session = SessionServiceFactory::GetForProfileIfExisting(destination->GetProfile())) {
        session->TrackWindowAfterTabMove(destination);
      }
    }
    if (drop_point) {
      NSWindow* window = target->view_->GetNativeWindow().GetNativeNSWindow();
      NSRect frame = window.frame;
      frame.origin = NSMakePoint(drop_point->x - 120, drop_point->y - frame.size.height + 20);
      for (NSScreen* screen in NSScreen.screens) {
        if (!NSPointInRect(*drop_point, screen.frame)) continue;
        NSRect visible = screen.visibleFrame;
        frame.origin.x = std::clamp(frame.origin.x, NSMinX(visible),
                                   std::max(NSMinX(visible), NSMaxX(visible) - frame.size.width));
        frame.origin.y = std::clamp(frame.origin.y, NSMinY(visible),
                                   std::max(NSMinY(visible), NSMaxY(visible) - frame.size.height));
        break;
      }
      [window setFrameOrigin:frame.origin];
    }
    destination->GetWindow()->Activate();
    contents->Focus();
    target->QueueSnapshot();
    QueueGroupSnapshot();
  }

  // Where a dragged tab lands: the Favorites grid shared by this profile's
  // spaces, or the active space's pinned or unpinned list.
  enum class TabZone { kFavorites, kPinned, kUnpinned };
  bool InZone(int index, TabZone zone) const {
    if (zone == TabZone::kFavorites) return IsFavorite(tabs_->GetWebContentsAt(index));
    return InActiveSpace(index) && tabs_->IsTabPinned(index) == (zone == TabZone::kPinned);
  }

  // Moves a tab before `before_id` in `zone`, or to the end of that zone
  // when `before_id` is not listed there. Favorites and pinned tabs are
  // Chromium pinned tabs, so they keep their place and restore pinned.
  void MoveTab(int id, int before_id, TabZone zone) {
    int from = FindTab(id);
    if (!tabs_->ContainsIndex(from)) return;
    auto* contents = tabs_->GetWebContentsAt(from);
    if (!InActiveSpace(from) && !IsFavorite(contents)) return;
    if (zone == TabZone::kFavorites && IsPrivate()) return;
    if (zone == TabZone::kFavorites && !IsFavorite(contents)) {
      SetTabSpace(contents, kFavoritesSpace);
      PersistTab(contents);
    } else if (zone != TabZone::kFavorites && IsFavorite(contents)) {
      AssignTab(contents, active_space_);
      selected_tabs_[active_space_] = id;
    }
    const bool pinned = zone != TabZone::kUnpinned;
    if (tabs_->IsTabPinned(from) != pinned) from = tabs_->SetTabPinned(from, pinned);
    int before = FindTab(before_id);
    if (before == from || (tabs_->ContainsIndex(before) && !InZone(before, zone))) before = -1;
    int to = -1;
    if (tabs_->ContainsIndex(before)) {
      // MoveWebContentsAt takes the final index, after `from` is removed.
      to = before > from ? before - 1 : before;
    } else {
      int last = -1;
      for (int i = 0; i < tabs_->count(); ++i)
        if (i != from && InZone(i, zone)) last = i;
      if (last >= 0) to = last > from ? last : last + 1;
    }
    if (to >= 0 && to != from) tabs_->MoveWebContentsAt(from, to, false);
  }

  // MARK: Split view

  // Chromium's own split view: two tabs of one space, side by side or stacked.
  // Chromium keeps the pair adjacent and restores it with the session.
  void Unsplit(int index) {
    if (!tabs_->ContainsIndex(index)) return;
    if (auto split = tabs_->GetSplitForTab(index)) tabs_->RemoveSplit(*split);
  }

  // Shows the tab at `index` alongside the active tab, on the leading or
  // trailing half of the chosen layout. A split holds two tabs, so a tab
  // already in a split leaves it first.
  void SplitWithActive(int index, split_tabs::SplitTabLayout layout, bool leading) {
    const int current = tabs_->active_index();
    if (!tabs_->ContainsIndex(index) || !tabs_->ContainsIndex(current) || index == current) return;
    auto* dragged = tabs_->GetWebContentsAt(index);
    auto* active = tabs_->GetWebContentsAt(current);
    // Favorites belong to every space, so they stay out of a space's split.
    if (IsFavorite(dragged) || IsFavorite(active) || !InActiveSpace(index) || !InActiveSpace(current)) return;
    Unsplit(index);
    Unsplit(tabs_->GetIndexOfWebContents(active));
    index = tabs_->GetIndexOfWebContents(dragged);
    if (!tabs_->ContainsIndex(index) || tabs_->GetActiveWebContents() != active) return;
    const auto split = tabs_->AddToNewSplit(
        {index}, split_tabs::SplitTabVisualData(layout),
        split_tabs::SplitTabCreatedSource::kDragAndDropTab);
    // The pair keeps its tab-strip order; put the dropped tab on the half it
    // was dropped on.
    const auto* data = tabs_->GetSplitData(split);
    const auto members = data ? data->ListTabs() : std::vector<tabs::TabInterface*>();
    if (members.size() == 2 && (members[0]->GetContents() == dragged) != leading)
      tabs_->ReverseTabsInSplit(split);
  }

  // MARK: Archive

  // Closes the active space's unpinned tabs and keeps them in the space's
  // archive, from which the sidebar can reopen them.
  void ArchiveTabs() {
    if (!tabs_ || tabs_->closing_all()) return;
    base::ListValue archived;
    std::vector<base::WeakPtr<content::WebContents>> closing;
    int keeper = -1;
    for (int i = 0; i < tabs_->count(); ++i) {
      if (!InActiveSpace(i)) continue;
      auto* contents = tabs_->GetWebContentsAt(i);
      if (tabs_->IsTabPinned(i)) {
        if (keeper < 0 || i == tabs_->active_index()) keeper = i;
        continue;
      }
      const GURL& url = contents->GetLastCommittedURL().is_valid() ? contents->GetLastCommittedURL()
                                                                   : contents->GetVisibleURL();
      if (url.is_valid() && !url.IsAboutBlank() && !(url.SchemeIs("chrome") && url.host() == "newtab")) {
        base::DictValue tab;
        tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
        tab.Set("url", url.spec());
        archived.Append(std::move(tab));
      }
      closing.push_back(contents->GetWeakPtr());
    }
    if (closing.empty()) return;
    // Let the sidebar animate the snapshot produced by this Clear action.
    ++archive_generation_;
    if (!IsPrivate()) {
      // The newest batch sits at the front of the archive, for "Undo".
      last_archive_space_ = active_space_;
      last_archive_count_ = std::min(archived.size(), SpaceCatalog::kMaxArchivedTabs);
      catalog_.Archive(active_space_, std::move(archived));
    }
    // Stay in this space: show a pinned tab, or a blank one, before closing,
    // so Chromium does not activate another space's tab (or close the window).
    if (keeper >= 0) {
      tabs_->ActivateTabAt(keeper);
    } else {
      NavigateTo(GURL("about:blank"), true);
    }
    for (auto& contents : closing) {
      const int index = contents ? tabs_->GetIndexOfWebContents(contents.get()) : TabStripModel::kNoTab;
      if (index != TabStripModel::kNoTab) tabs_->CloseWebContentsAt(index, TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    }
  }

  void RestoreArchived(size_t index) {
    if (IsPrivate()) return;
    const auto tab = catalog_.TakeArchived(active_space_, index);
    // Keep "Undo" pointing at what is left of the newest batch.
    if (last_archive_space_ == active_space_ && index < last_archive_count_) --last_archive_count_;
    const std::string* spec = tab.FindString("url");
    const GURL url = spec ? GURL(*spec) : GURL();
    if (!url.is_valid()) return;
    // Reuse the blank tab that archiving left behind instead of stranding it.
    auto* active = tabs_->GetActiveWebContents();
    const bool blank = active && InActiveSpace(tabs_->active_index()) &&
        !tabs_->IsTabPinned(tabs_->active_index()) && active->GetVisibleURL().IsAboutBlank();
    NavigateTo(url, !blank);
  }

  // Reopens the `count` most recently archived tabs, in their old order.
  void RestoreArchivedFront(size_t count) {
    if (IsPrivate()) return;
    const auto* space = catalog_.Find(active_space_);
    const auto* archived = space ? space->FindList("archivedTabs") : nullptr;
    count = std::min(count, archived ? archived->size() : size_t{0});
    for (size_t i = 0; i < count; ++i) RestoreArchived(0);
  }

  // Closes the active space's unpinned tabs other than `keep`: all of them,
  // or only those listed below it.
  void CloseOtherTabs(int keep, bool below_only) {
    if (!tabs_->ContainsIndex(keep) || !InActiveSpace(keep)) return;
    std::vector<base::WeakPtr<content::WebContents>> closing;
    for (int i = below_only ? keep + 1 : 0; i < tabs_->count(); ++i) {
      if (i == keep || !InActiveSpace(i) || tabs_->IsTabPinned(i)) continue;
      closing.push_back(tabs_->GetWebContentsAt(i)->GetWeakPtr());
    }
    if (closing.empty()) return;
    // Stay in this space: Chromium must not activate another space's tab.
    if (below_only ? tabs_->active_index() > keep : tabs_->active_index() != keep) tabs_->ActivateTabAt(keep);
    for (auto& contents : closing) {
      const int index = contents ? tabs_->GetIndexOfWebContents(contents.get()) : TabStripModel::kNoTab;
      if (index != TabStripModel::kNoTab) tabs_->CloseWebContentsAt(index, TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    }
  }

  // Moves a tab to another space of this profile. This space keeps a tab to
  // show: another of its tabs, or a blank one.
  void MoveTabToSpace(int index, const std::string& space) {
    if (IsPrivate() || !tabs_->ContainsIndex(index) || !InActiveSpace(index) ||
        space == active_space_ || !SpaceBelongsHere(space)) return;
    auto* contents = tabs_->GetWebContentsAt(index);
    if (tabs_->active_index() == index) {
      int next = -1;
      for (int i = 0; i < tabs_->count(); ++i) {
        if (i == index || !InActiveSpace(i)) continue;
        if (next < 0 || (i > index && next < index)) next = i;
      }
      if (next >= 0) tabs_->ActivateTabAt(next);
      else NavigateTo(GURL("about:blank"), true);
      index = tabs_->GetIndexOfWebContents(contents);
      if (index == TabStripModel::kNoTab) return;
    }
    AssignTab(contents, space);
    EditTabMeta(contents, [](base::DictValue& meta) { return meta.Remove("folder"); });
    selected_tabs_[space] = sessions::SessionTabHelper::IdForTab(contents).id();
  }

  // MARK: Downloads

  static constexpr base::TimeDelta kRecentDownload = base::Seconds(30);

  void QueueDownloadSnapshot() {
    if (download_throttle_.IsRunning()) return;
    download_throttle_.Start(FROM_HERE, base::Milliseconds(500),
                             base::BindOnce(&Impl::QueueSnapshot, weak_factory_.GetWeakPtr()));
  }

  // {active, progress (0-1, or -1 when unknown), recent (a download finished
  // in the last 30 seconds)}.
  base::DictValue DownloadState() const {
    int active = 0;
    int64_t received = 0, total = 0;
    bool known = true, recent = false;
    if (download_notifier_ && download_notifier_->GetManager()) {
      download::SimpleDownloadManager::DownloadVector items;
      download_notifier_->GetManager()->GetAllDownloads(&items);
      for (download::DownloadItem* item : items) {
        if (item->IsTransient()) continue;
        if (item->GetState() == download::DownloadItem::IN_PROGRESS) {
          ++active;
          received += item->GetReceivedBytes();
          if (item->GetTotalBytes() > 0) total += item->GetTotalBytes();
          else known = false;
        } else if (item->GetState() == download::DownloadItem::COMPLETE &&
                   base::Time::Now() - item->GetEndTime() < kRecentDownload) {
          recent = true;
        }
      }
    }
    base::DictValue state;
    state.Set("active", active);
    state.Set("progress", active && known && total > 0 ? std::min(1.0, static_cast<double>(received) / total) : -1.0);
    state.Set("recent", recent);
    return state;
  }

  static bool HandlePinnedClose(BrowserWindowInterface* browser, content::WebContents* contents,
                                PinnedTabCloseAction action) {
    for (auto* host : Instances()) {
      if (host->view_->browser() == browser) return host->ClosePinnedTab(contents, action);
    }
    return false;
  }

  bool ClosePinnedTab(content::WebContents* contents, PinnedTabCloseAction action) {
    if (!contents || !tabs_ || tabs_->closing_all() || group_->closing) return false;
    const int index = tabs_->GetIndexOfWebContents(contents);
    if (!tabs_->ContainsIndex(index)) return false;
    const int id = sessions::SessionTabHelper::IdForTab(contents).id();
    std::erase_if(pending_pin_closes_, [](const auto& item) { return !item.second; });
    if (action != PinnedTabCloseAction::kRequest) {
      if (!pending_pin_closes_.erase(id)) return false;
      if (action == PinnedTabCloseAction::kConfirm && tabs_->IsTabPinned(index)) {
        // Replacing the contents destroys the sender of this callback.
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
            base::BindOnce(&Impl::UnloadPinnedTab, weak_factory_.GetWeakPtr(), contents->GetWeakPtr()));
      }
      return true;
    }
    if (!tabs_->IsTabPinned(index)) return false;
    if (pending_pin_closes_.contains(id)) return true;
    if (contents->NeedToFireBeforeUnload()) {
      pending_pin_closes_[id] = contents->GetWeakPtr();
      tabs_->ActivateTabAt(index);
      contents->DispatchBeforeUnload(false);
    } else {
      UnloadPinnedTab(contents->GetWeakPtr());
    }
    return true;
  }

  static bool IsDormantPin(content::WebContents* contents) {
    return contents->GetController().NeedsReload() && !contents->IsLoading() &&
           !contents->GetPrimaryMainFrame()->IsRenderFrameLive();
  }

  void UnloadPinnedTab(base::WeakPtr<content::WebContents> contents) {
    if (!contents || !tabs_ || tabs_->closing_all() || group_->closing) return;
    int index = tabs_->GetIndexOfWebContents(contents.get());
    if (!tabs_->ContainsIndex(index) || !tabs_->IsTabPinned(index)) return;
    const bool was_active = tabs_->active_index() == index;
    if (!was_active && IsDormantPin(contents.get())) return;
    Unsplit(index);
    if (tabs_->GetActiveWebContents() == contents.get()) {
      int next = -1;
      // Closing a pin must not wake another dormant pin. Prefer an open
      // ordinary tab in this space, then an already loaded pin, then a blank.
      for (int i = 0; i < tabs_->count(); ++i) {
        auto* candidate = tabs_->GetWebContentsAt(i);
        if (candidate == contents.get() || (!InActiveSpace(i) && !IsFavorite(candidate)) ||
            candidate->GetController().NeedsReload()) continue;
        if (next < 0 || (tabs_->IsTabPinned(next) && !tabs_->IsTabPinned(i))) next = i;
      }
      if (next >= 0) tabs_->ActivateTabAt(next);
      else NavigateTo(GURL("about:blank"), true);
    }
    if (!contents || !tabs_ || tabs_->GetActiveWebContents() == contents.get()) return;
    index = tabs_->GetIndexOfWebContents(contents.get());
    if (!tabs_->ContainsIndex(index) || !tabs_->IsTabPinned(index)) return;

    const auto meta = ReadTabMeta(contents.get());
    const auto* saved = meta.FindString("pinnedURL");
    GURL home = saved ? GURL(*saved) : GURL();
    auto& controller = contents->GetController();
    if (!home.is_valid()) {
      if (auto* pending = controller.GetPendingEntry()) home = pending->GetVirtualURL();
      if (!home.is_valid()) home = contents->GetVisibleURL();
      if (!home.is_valid()) home = GURL("about:blank");
    }
    // Seed only the home page's presentation. Copying the old controller
    // would also restore its browsing history and DOM session storage.
    auto replacement = CreateLazyTab(contents->GetBrowserContext(), home);
    auto* entry = replacement->GetController().GetLastCommittedEntry();
    for (int i = controller.GetEntryCount() - 1; i >= 0; --i) {
      auto* previous = controller.GetEntryAtIndex(i);
      if (!previous->GetVirtualURL().EqualsIgnoringRef(home)) continue;
      entry->SetTitle(previous->GetTitle());
      entry->GetFavicon() = previous->GetFavicon();
      break;
    }
    auto dormant = replacement->GetWeakPtr();
    // This closes the old page's session. Let its performance-manager page
    // node go away and the tab helpers register the replacement as a new page.
    // AboutToBeDiscarded is for memory discards that preserve a page session.
    replacement->SetWasDiscarded(true);
    tabs_->DiscardWebContents(contents.get(), std::move(replacement)).reset();
    if (!dormant || !tabs_) return;
    if (was_active) just_closed_pin_ = dormant;
    dormant->NotifyWasDiscarded();
    tabs_->UpdateWebContentsState(dormant.get(), TabChangeType::kAll);
    QueueGroupSnapshot();
  }

  // Legacy gradients and the two-point color canvas share the space catalog.
  void ApplySpaceStyle(const std::string& id, const base::DictValue& metadata) {
    if (const auto* gradient = metadata.FindString("gradient"))
      catalog_.SetField(id, "gradient", gradient->empty() ? base::Value() : base::Value(*gradient));
    double grain = 0;
    if (const auto* text = metadata.FindString("grain"); text && base::StringToDouble(*text, &grain) &&
        std::isfinite(grain))
      catalog_.SetField(id, "grain", grain <= 0 ? base::Value() : base::Value(std::clamp(grain, 0.0, 1.0)));
    if (const auto* canvas = metadata.FindString("gradientCanvas")) {
      if (canvas->empty()) {
        catalog_.SetField(id, "gradientCanvas", base::Value());
      } else if (canvas->size() <= 1024) {
        if (auto value = base::JSONReader::ReadDict(*canvas, base::JSON_PARSE_RFC))
          catalog_.SetField(id, "gradientCanvas", base::Value(std::move(*value)));
      }
    }
  }

  void NavigateTo(const GURL& url, bool new_tab, bool replace_current_entry = false) {
    NavigateParams params(view_->browser(), url, ui::PAGE_TRANSITION_TYPED);
    params.should_replace_current_entry = replace_current_entry;
    params.disposition = new_tab || tabs_->empty()
        ? WindowOpenDisposition::kNewForegroundTab : WindowOpenDisposition::kCurrentTab;
    Navigate(&params);
    if (auto* contents = tabs_->GetActiveWebContents()) contents->Focus();
  }

  void NavigateNewPage(const GURL& url) {
    AdoptTabs();
    const int active = tabs_->active_index();
    for (int offset = 0; offset < tabs_->count(); ++offset) {
      const int i = (std::max(active, 0) + offset) % tabs_->count();
      if (!InActiveSpace(i) || !IsBlankPlaceholder(i)) continue;
      auto* contents = tabs_->GetWebContentsAt(i);
      const auto* pending = contents->GetController().GetPendingEntry();
      if (!IsBlankPage(contents->GetVisibleURL()) ||
          (pending && !IsBlankPage(pending->GetVirtualURL()))) continue;
      if (i != active) tabs_->ActivateTabAt(i);
      // The backing page was never a sidebar entry or a visited destination.
      NavigateTo(url, /*new_tab=*/false, /*replace_current_entry=*/true);
      return;
    }
    NavigateTo(url, true);
  }

  void Command(const std::string& json) {
    if (!tabs_ || tabs_->closing_all()) return;
    auto message = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
    if (!message) return;
    const std::string* action = message->FindString("action");
    if (!action) return;
    const std::string* text = message->FindString("text");
    if (*action == "commandBarAction") {
      RunCommandBarAction(*message);
      return;
    }
    int index = FindTab(message->FindInt("id").value_or(-1));
    auto* browser = view_->browser();
    const bool incognito = view_->GetProfile()->IsOffTheRecord();
    // Private windows have their own tabs, not a route into persistent space
    // creation or the original profile's appearance settings.
    if (incognito && (*action == "space" || *action == "createSpace" || *action == "deleteSpace" ||
                      *action == "manageSpaces" || *action == "moveTabToSpace" ||
                      *action == "createProfile" || *action == "deleteProfile" || *action == "customizeSpace" || *action == "appearance" || *action == "importBrowserData")) return;
    if (*action == "newLittleWindow") {
      if (!incognito) OpenFreshLittleWindow(this);
      return;
    }
    auto* active = tabs_->GetActiveWebContents();
    // Scope popover actions to the page they described, including navigations
    // in the same tab, so stale extension clicks cannot grant another page access.
    if (*action == "activateExtension" || *action == "siteSettings" || *action == "setSitePermission" ||
        *action == "findInPage" || *action == "inspectPage") {
      const auto* metadata = message->FindDict("metadata");
      const auto* expected_url = metadata ? metadata->FindString("url") : nullptr;
      if (!active || index != tabs_->active_index() || !expected_url || *expected_url != PageURL(active).spec()) return;
    }
    if (*action == "restoreAllArchived" || *action == "clearArchive" || *action == "togglePinnedSection") {
      // Space-specific UI supplies the Space it displayed so a queued action
      // cannot affect another Space after a switch.
      if (const auto* metadata = message->FindDict("metadata")) {
        const auto* expected_space = metadata->FindString("space");
        if (!expected_space || *expected_space != active_space_) return;
      }
    }
    base::ScopedClosureRunner remember_organization;
    const std::string organization_label = OrganizationLabel(*action);
    if (!incognito && !organization_label.empty()) {
      remember_organization.ReplaceClosure(base::BindOnce(&Impl::RememberOrganization,
          weak_factory_.GetWeakPtr(), active_space_, organization_label,
          message->FindInt("id").value_or(-1), OrganizationState()));
    }
    if (*action == "noticeAction") {
      PerformNoticeAction(*message, active, index);
      return;  // A notice delegate can synchronously close this browser.
    }
    if ((*action == "select" || *action == "switchToTab") && tabs_->ContainsIndex(index)) {
      auto* target = tabs_->GetWebContentsAt(index);
      if (*action == "switchToTab" && !InActiveSpace(index) && !IsFavorite(target)) {
        const std::string space = GetTabSpace(target);
        selected_tabs_[space] = sessions::SessionTabHelper::IdForTab(target).id();
        SelectLocalSpace(space);
      } else {
        tabs_->ActivateTabAt(index);
      }
      if (auto* contents = tabs_->GetActiveWebContents()) contents->Focus();
    } else if (*action == "removeClosedPin") {
      if (!tabs_->ContainsIndex(index) || !tabs_->IsTabPinned(index)) return;
      auto* contents = tabs_->GetWebContentsAt(index);
      // A queued click can arrive after the pin was reopened or moved.
      if (contents == active || !IsDormantPin(contents) ||
          (!InActiveSpace(index) && !IsFavorite(contents))) return;
      tabs_->CloseWebContentsAt(index, CLOSE_USER_GESTURE);
      return;
    } else if (*action == "closePinnedSession" || *action == "close") {
      if (!tabs_->ContainsIndex(index)) return;
      if (tabs_->IsTabPinned(index)) {
        ClosePinnedTab(tabs_->GetWebContentsAt(index), PinnedTabCloseAction::kRequest);
        return;
      }
      if (*action == "closePinnedSession") return;
      tabs_->CloseWebContentsAt(index, CLOSE_USER_GESTURE);
      return;  // Closing the last tab may destroy this browser window.
    } else if (*action == "pin" && tabs_->ContainsIndex(index) && !IsPrivate()) {
      tabs_->SetTabPinned(index, !tabs_->IsTabPinned(index));
    } else if (*action == "mute" && tabs_->ContainsIndex(index)) {
      auto* contents = tabs_->GetWebContentsAt(index);
      contents->SetAudioMuted(!contents->IsAudioMuted());
    } else if (*action == "duplicate" && tabs_->ContainsIndex(index) && chrome::CanDuplicateTabAt(browser, index)) {
      chrome::DuplicateTabAt(browser, index);
    } else if ((*action == "closeOthers" || *action == "closeBelow") && tabs_->ContainsIndex(index)) {
      CloseOtherTabs(index, *action == "closeBelow");
    } else if (*action == "moveTabToSpace" && text) {
      MoveTabToSpace(index, *text);
    } else if (*action == "claimTab") {
      const auto* metadata = message->FindDict("metadata");
      const std::string* window = metadata ? metadata->FindString("window") : nullptr;
      int window_id;
      if (window && base::StringToInt(*window, &window_id))
        ClaimTab(window_id, message->FindInt("id").value_or(-1));
      return;
    } else if (*action == "detachTab" && tabs_->ContainsIndex(index)) {
      std::optional<NSPoint> point;
      if (const auto* metadata = message->FindDict("metadata")) {
        const auto* x = metadata->FindString("screenX");
        const auto* y = metadata->FindString("screenY");
        double screen_x, screen_y;
        if (x && y && base::StringToDouble(*x, &screen_x) && base::StringToDouble(*y, &screen_y) &&
            std::isfinite(screen_x) && std::isfinite(screen_y)) point = NSMakePoint(screen_x, screen_y);
      }
      DetachTabToWindow(index, point);
      return;
    } else if (*action == "moveTab" && tabs_->ContainsIndex(index)) {
      const auto* metadata = message->FindDict("metadata");
      int before = -1;
      const std::string* before_text = metadata ? metadata->FindString("before") : nullptr;
      if (before_text && !base::StringToInt(*before_text, &before)) before = -1;
      const std::string* zone = metadata ? metadata->FindString("zone") : nullptr;
      MoveTab(message->FindInt("id").value_or(-1), before,
              !zone ? (tabs_->IsTabPinned(index) ? TabZone::kPinned : TabZone::kUnpinned)
              : *zone == "favorites" ? TabZone::kFavorites
              : *zone == "pinned" && !IsPrivate() ? TabZone::kPinned : TabZone::kUnpinned);
    } else if (*action == "splitTab" && tabs_->ContainsIndex(index)) {
      const bool stacked = text && (*text == "top" || *text == "bottom");
      SplitWithActive(index, stacked ? split_tabs::SplitTabLayout::kStacked
                                     : split_tabs::SplitTabLayout::kSideBySide,
                      text && (*text == "left" || *text == "top"));
    } else if (*action == "splitNew" && active) {
      // Chromium's "new split" page lists the open tabs to choose from.
      if (!tabs_->GetSplitForTab(tabs_->active_index()) && !IsFavorite(active))
        chrome::NewSplitTab(browser, split_tabs::SplitTabLayout::kSideBySide,
                            split_tabs::SplitTabCreatedSource::kKeyboardShortcut);
    } else if (*action == "unsplit") {
      Unsplit(tabs_->ContainsIndex(index) ? index : tabs_->active_index());
    } else if (*action == "new") {
      chrome::ExecuteCommand(browser, IDC_NEW_TAB);
    } else if (*action == "suggest" && text) {
      Suggest(*text);
      return;  // Suggestions are not part of the sidebar snapshot.
    } else if ((*action == "navigate" || *action == "navigateNew") && text) {
      const bool new_page = *action == "navigateNew";
      if (new_page && base::TrimWhitespaceASCII(*text, base::TRIM_ALL).empty()) return;
      const GURL destination = ResolveAddress(*text, view_->GetProfile()).url;
      if (!destination.is_valid()) return;
      if (new_page) NavigateNewPage(destination);
      else NavigateTo(destination, false);
    } else if (*action == "back" && active && chrome::CanGoBack(active)) {
      chrome::GoBack(browser, WindowOpenDisposition::kCurrentTab);
    } else if (*action == "forward" && active && chrome::CanGoForward(active)) {
      chrome::GoForward(browser, WindowOpenDisposition::kCurrentTab);
    } else if (*action == "reload" && active) {
      chrome::Reload(browser, WindowOpenDisposition::kCurrentTab);
    } else if (*action == "stop" && active) {
      chrome::Stop(browser);
    } else if (*action == "extensions") {
      NavigateTo(GURL("chrome://extensions/"), true);
    } else if (*action == "siteControls" && text) {
      site_controls_open_ = *text == "open";
      if (site_controls_open_) {
        // Refresh icons after their asynchronous load, and reflect changes made
        // by extension actions or permissions while the popover remains open.
        site_controls_timer_.Start(FROM_HERE, base::Seconds(1),
            base::BindRepeating(&Impl::QueueSnapshot, weak_factory_.GetWeakPtr()));
      } else {
        site_controls_timer_.Stop();
      }
    } else if (*action == "setSitePermission") {
      SetSitePermission(active, *message);
    } else if (*action == "activateExtension" && text) {
      ActivateExtensionMenuItem(*text);
    } else if (*action == "siteSettings" && active && active->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
      chrome::ShowSiteSettings(browser, active->GetLastCommittedURL());
    } else if (*action == "findInPage" && active) {
      chrome::Find(browser);
    } else if (*action == "inspectPage" && active && chrome::IsCommandEnabled(browser, IDC_DEV_TOOLS)) {
      chrome::ExecuteCommand(browser, IDC_DEV_TOOLS);
    } else if (*action == "extensionMenu") {
      // Chromium hides its toolbar extensions button when nothing is
      // installed; Bark's sidebar always shows it, so open the extensions page.
      if (auto* extensions = ExtensionsContainer::From(*browser); extensions && extensions->HasAnyExtensions())
        extensions->ToggleExtensionsMenu();
      else
        NavigateTo(GURL("chrome://extensions/"), true);
    } else if (*action == "siteInfo" && active) {
      ShowPageInfoDialog(active, {}, bubble_anchor_util::Anchor::kLocationBar);
    } else if (*action == "history") {
      NavigateTo(GURL("chrome://history/"), true);
    } else if (*action == "downloads") {
      NavigateTo(GURL("chrome://downloads/"), true);
    } else if (*action == "renameTab" && tabs_->ContainsIndex(index) && text && text->size() <= 512) {
      const std::string title(base::TrimWhitespaceASCII(*text, base::TRIM_ALL));
      EditTabMeta(tabs_->GetWebContentsAt(index), [&](base::DictValue& meta) {
        if (title.empty()) return meta.Remove("title");
        meta.Set("title", title.substr(0, 200));
        return true;
      });
    } else if (*action == "resetPin" && tabs_->ContainsIndex(index) && tabs_->IsTabPinned(index)) {
      auto* contents = tabs_->GetWebContentsAt(index);
      const auto meta = ReadTabMeta(contents);
      const auto* pinned = meta.FindString("pinnedURL");
      const GURL url = pinned ? GURL(*pinned) : GURL();
      if (url.is_valid()) {
        content::NavigationController::LoadURLParams load(url);
        load.transition_type = ui::PAGE_TRANSITION_AUTO_BOOKMARK;
        contents->GetController().LoadURLWithParams(load);
        if (tabs_->active_index() != index) tabs_->ActivateTabAt(index);
      }
    } else if (*action == "setPinURL" && tabs_->ContainsIndex(index) && tabs_->IsTabPinned(index)) {
      auto* contents = tabs_->GetWebContentsAt(index);
      const GURL url = PageURL(contents);
      if (!IsBlankPage(url) && EditTabMeta(contents, [&](base::DictValue& meta) {
        meta.Set("pinnedURL", url.spec());
        return true;
      })) RememberPinnedPage(contents, true);
    } else if (*action == "newFolder" && !incognito) {
      std::string name = text ? std::string(base::TrimWhitespaceASCII(*text, base::TRIM_ALL)) : std::string();
      if (name.empty()) name = "New Folder";
      const std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
      bool added = false;
      EditFolders([&](base::ListValue& folders) {
        if (folders.size() >= 64) return;
        base::DictValue folder;
        folder.Set("id", id);
        folder.Set("name", name.substr(0, 64));
        const auto* metadata = message->FindDict("metadata");
        const auto* parent = metadata ? metadata->FindString("parent") : nullptr;
        if (parent && !parent->empty()) {
          if (!HasFolder(active_space_, *parent)) return;
          folder.Set("parent", *parent);
          // Make the new child visible for inline naming, even when an
          // ancestor is collapsed. This expansion belongs to the same Undo.
          std::set<std::string> visited;
          std::string ancestor = *parent;
          while (!ancestor.empty() && visited.insert(ancestor).second) {
            std::string next;
            for (auto& value : folders) {
              auto& entry = value.GetDict();
              if (entry.FindString("id") && *entry.FindString("id") == ancestor) {
                entry.Set("collapsed", false);
                if (const auto* parent_id = entry.FindString("parent")) next = *parent_id;
                break;
              }
            }
            ancestor = std::move(next);
          }
        }
        folders.Append(std::move(folder));
        added = true;
      });
      if (added && tabs_->ContainsIndex(index)) MoveTabToFolder(index, id);
    } else if ((*action == "renameFolder" || *action == "deleteFolder" || *action == "toggleFolder" || *action == "moveFolder") && !incognito) {
      const auto* metadata = message->FindDict("metadata");
      const std::string* folder = metadata ? metadata->FindString("folder") : nullptr;
      if (!folder) return;
      const std::string name = text ? std::string(base::TrimWhitespaceASCII(*text, base::TRIM_ALL)) : std::string();
      EditFolders([&](base::ListValue& folders) {
        std::string previous_parent;
        for (const auto& value : folders) {
          const auto& entry = value.GetDict();
          if (entry.FindString("id") && *entry.FindString("id") == *folder && entry.FindString("parent"))
            previous_parent = *entry.FindString("parent");
        }
        // Deleting a container promotes its child folders without losing tabs.
        if (*action == "deleteFolder") for (auto& value : folders) {
          auto& entry = value.GetDict();
          if (entry.FindString("parent") && *entry.FindString("parent") == *folder) {
            if (previous_parent.empty()) entry.Remove("parent");
            else entry.Set("parent", previous_parent);
          }
        }
        folders.EraseIf([&](base::Value& value) {
          auto* entry = value.GetIfDict();
          if (!entry || !entry->FindString("id") || *entry->FindString("id") != *folder) return false;
          if (*action == "deleteFolder") return true;
          if (*action == "renameFolder" && !name.empty()) entry->Set("name", name.substr(0, 64));
          if (*action == "toggleFolder") {
            entry->Set("collapsed", !entry->FindBool("collapsed").value_or(false));
            just_closed_pin_.reset();
          }
          if (*action == "moveFolder") {
            const auto* parent = metadata->FindString("parent");
            if (parent && !parent->empty()) entry->Set("parent", *parent);
            else entry->Remove("parent");
          }
          return false;
        });
      });
      // A deleted folder's pins stay pinned, out of the folder.
      if (*action == "deleteFolder") {
        for (int i = 0; i < tabs_->count(); ++i) {
          auto* contents = tabs_->GetWebContentsAt(i);
          if (!InActiveSpace(i)) continue;
          EditTabMeta(contents, [&](base::DictValue& meta) {
            const auto* current = meta.FindString("folder");
            return current && *current == *folder && meta.Remove("folder");
          });
        }
      }
    } else if (*action == "moveToFolder" && tabs_->ContainsIndex(index) && !incognito) {
      const auto* metadata = message->FindDict("metadata");
      const std::string* folder = metadata ? metadata->FindString("folder") : nullptr;
      MoveTabToFolder(index, folder ? *folder : std::string());
    } else if (*action == "togglePinnedSection" && !incognito) {
      const auto* space = catalog_.Find(active_space_);
      if (space && catalog_.SetField(active_space_, "pinsCollapsed",
          base::Value(!space->FindBool("pinsCollapsed").value_or(false)))) just_closed_pin_.reset();
    } else if (*action == "undoOrganization" && !incognito) {
      UndoOrganization();
    } else if (*action == "setArchiveAfter" && text && !incognito) {
      int hours = 0;
      if (base::StringToInt(*text, &hours) && hours >= 0 && hours <= 24 * 365)
        [NSUserDefaults.standardUserDefaults setInteger:hours forKey:kArchiveAfterHours];
      AutoArchive();
    } else if (*action == "setGlobalLittleShortcut" && text && !incognito) {
      [NSUserDefaults.standardUserDefaults setBool:*text == "on" forKey:kGlobalLittleShortcut];
      SyncGlobalLittleShortcut(/*retry=*/true);
      for (auto* host : Instances()) host->QueueSnapshot();
    } else if ((*action == "setPeek" || *action == "setLittleWindow") && text && !incognito) {
      [NSUserDefaults.standardUserDefaults setBool:*text != "on"
                                            forKey:*action == "setPeek" ? kPeekDisabled : kLittleWindowDisabled];
      for (auto* host : Instances()) host->QueueSnapshot();
    } else if (*action == "setAutoPictureInPicture" && text && !incognito && PictureInPictureEditable()) {
      if (auto* settings = ContentSettings())
        settings->SetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
                                           *text == "on" ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
    } else if (*action == "mediaToggle" && tabs_->ContainsIndex(index)) {
      ToggleMedia(index);
    } else if (*action == "requestSwitcher") {
      SendSwitcher();
      return;  // The switcher is not part of the sidebar snapshot.
    } else if (*action == "archiveTabs") {
      ArchiveTabs();
    } else if (*action == "restoreArchived" && message->FindInt("id").value_or(-1) >= 0) {
      const size_t archived_index = static_cast<size_t>(*message->FindInt("id"));
      if (const auto* metadata = message->FindDict("metadata")) {
        const auto* space = catalog_.Find(active_space_);
        const auto* archived = space ? space->FindList("archivedTabs") : nullptr;
        const auto* expected_space = metadata->FindString("space");
        const auto* expected_url = metadata->FindString("url");
        const auto* expected_title = metadata->FindString("title");
        if (!expected_space || *expected_space != active_space_ || !expected_url || !expected_title ||
            !archived || archived_index >= archived->size()) return;
        const auto& tab = (*archived)[archived_index].GetDict();
        if (!tab.FindString("url") || *tab.FindString("url") != *expected_url ||
            !tab.FindString("title") || *tab.FindString("title") != *expected_title) return;
      }
      RestoreArchived(archived_index);
    } else if (*action == "undoArchive") {
      if (last_archive_space_ == active_space_) RestoreArchivedFront(last_archive_count_);
      last_archive_count_ = 0;
    } else if (*action == "restoreAllArchived") {
      RestoreArchivedFront(SpaceCatalog::kMaxArchivedTabs);
      last_archive_count_ = 0;
    } else if (*action == "clearArchive" && !incognito) {
      catalog_.ClearArchive(active_space_);
      last_archive_count_ = 0;
    } else if (*action == "deleteSpace" && text) {
      catalog_.Remove(*text, VisibleSpaceExcept(*text));
    } else if (*action == "manageSpaces") {
      NavigateTo(GURL("chrome://spaces/"), true);
    } else if (*action == "showFactoryReset" && view_->GetProfile()->IsRegularProfile()) {
      NavigateTo(GURL("chrome://spaces/#factory-reset"), true);
    } else if (*action == "importBrowserData" && text) {
      browser_import_result_.reset();
      ImportBrowserData(*text, base::BindOnce([](base::WeakPtr<Impl> self, base::DictValue result) {
        if (!self) return;
        self->browser_import_result_ = std::move(result);
        self->QueueSnapshot();
      }, weak_factory_.GetWeakPtr()));
    } else if (*action == "bookmarks") {
      NavigateTo(GURL("chrome://bookmarks/"), true);
    } else if (*action == "settings") {
      BarkSwiftSidebarShowPreferences(swift_);
    } else if (*action == "preferencesState" && text) {
      preferences_open_ = *text == "open";
      if (preferences_open_ && !incognito)
        if (auto* service = TemplateURLServiceFactory::GetForProfile(view_->GetProfile())) service->Load();
    } else if (*action == "setPreference" && text && !incognito) {
      SetPreference(*message);
    } else if (*action == "advancedSettings" && text) {
      if (*text == "" || *text == "searchEngines" || *text == "privacy" ||
          *text == "autofill" || *text == "defaultBrowser")
        NavigateTo(GURL("chrome://settings/" + *text), true);
    } else if (*action == "hostActivated" && !group_->closing && !group_->restoring &&
               group_->transitions == 0 && !concealed_ && browser->GetWindow()->IsVisible()) {
      // AppKit restores caption-button frames when returning from another
      // window (for example Settings). Reapply the floating panel's offset.
      view_->InvalidateLayout();
      for (auto* host : Instances()) {
        if (host != this && host->group_ == group_ && host->view_->browser()->GetWindow()->IsVisible()) {
          MatchWindowFrame(host);
          host->view_->browser()->GetWindow()->Hide();
        }
      }
    } else if (*action == "toggleSidebar") {
      collapsed_ = !collapsed_;
      revealed_ = false;
      if (!incognito)
        [[NSUserDefaults standardUserDefaults] setBool:collapsed_ forKey:kSidebarCollapsed];
      SetSidebarPresentation(true);
    } else if (*action == "revealSidebar" && text) {
      const bool reveal = collapsed_ && *text == "true";
      if (revealed_ != reveal) {
        revealed_ = reveal;
        SetSidebarPresentation(true);
      }
    } else if (*action == "resize") {
      double requested = message->FindDouble("width").value_or(width_);
      width_ = static_cast<int>(std::clamp(requested, 200.0, 400.0));
      if (!incognito)
        [[NSUserDefaults standardUserDefaults] setInteger:width_ forKey:kSidebarWidth];
      view_->InvalidateLayout();
    } else if (*action == "appearance" && text) {
      auto scheme = ThemeService::BrowserColorScheme::kSystem;
      if (*text == "dark") scheme = ThemeService::BrowserColorScheme::kDark;
      else if (*text == "light") scheme = ThemeService::BrowserColorScheme::kLight;
      ThemeServiceFactory::GetForProfile(view_->GetProfile())->SetBrowserColorScheme(scheme);
    } else if (*action == "space" && text) {
      // A swipe sends the switch as its slide animation starts, so another
      // profile's window can render meanwhile; reveal it once the slide ends.
      base::TimeDelta slide_duration;
      if (auto* metadata = message->FindDict("metadata")) {
        if (auto* after = metadata->FindString("revealAfter")) {
          int ms = 0;
          if (base::StringToInt(*after, &ms))
            slide_duration = base::Milliseconds(std::clamp(ms, 0, 500));
        }
      }
      SwitchSpace(*text, slide_duration);
    } else if ((*action == "trackSpaceSwipe" || *action == "queueSpaceSwipe") && !incognito) {
      const auto* metadata = message->FindDict("metadata");
      if (const auto* after = metadata ? metadata->FindString("after") : nullptr)
        UpdateSpaceSwipe(*after, *action == "trackSpaceSwipe", text);
    } else if (*action == "prepareSpace" && text) {
      PrepareSpace(*text);
    } else if (*action == "createSpace" && text && !text->empty() && text->size() <= 128) {
      std::string theme = "gray";
      std::string emoji;
      std::string profile_key = ProfileKey();
      if (auto* metadata = message->FindDict("metadata")) {
        if (auto* value = metadata->FindString("theme"); value && value->size() <= 32) theme = *value;
        if (auto* value = metadata->FindString("emoji"); value && value->size() <= 256) emoji = *value;
        if (auto* value = metadata->FindString("profile")) profile_key = *value;
      }
      if (!ProfilePath(profile_key).empty()) {
        AdoptTabs();
        auto id = catalog_.Create(*text, profile_key, theme, emoji);
        if (!id.empty()) {
          if (auto* metadata = message->FindDict("metadata")) ApplySpaceStyle(id, *metadata);
          SwitchSpace(id);
        }
      }
    } else if (*action == "customizeSpace") {
      // Defaults to the active space; the sidebar's context menu can name any.
      auto* metadata = message->FindDict("metadata");
      std::string target = active_space_;
      if (auto* id = metadata ? metadata->FindString("space") : nullptr; id && catalog_.Find(*id)) target = *id;
      auto* space = catalog_.Find(target);
      if (space && metadata && space->FindString("name")) {
        auto* theme = metadata->FindString("theme");
        auto* emoji = metadata->FindString("emoji");
        std::string name = *space->FindString("name");
        if (auto* renamed = metadata->FindString("name"); renamed && renamed->size() <= 128 &&
            !base::TrimWhitespaceASCII(*renamed, base::TRIM_ALL).empty()) name = *renamed;
        if (theme && emoji) catalog_.Update(target, name, *theme, *emoji);
        ApplySpaceStyle(target, *metadata);
      }
    } else if (*action == "setSpaceProfile") {
      if (auto* metadata = message->FindDict("metadata")) {
        auto* space = metadata->FindString("space");
        auto* profile = metadata->FindString("profile");
        if (space && profile) MoveSpaceToProfile(*space, *profile);
      }
    } else if (*action == "deleteProfile" && text) {
      const base::FilePath path = ProfilePath(*text);
      if (!path.empty()) webui::DeleteProfileAtPath(path, ProfileMetrics::DELETE_PROFILE_SETTINGS);
      return;  // Deleting this window's profile can destroy the sidebar.
    } else if (*action == "createProfile" && text && !text->empty() && text->size() <= 128) {
      ProfileManager::CreateMultiProfileAsync(base::UTF8ToUTF16(*text), 0, false,
          base::BindOnce([](base::WeakPtr<Impl> self, Profile* profile) {
            if (!self || !profile) return;
            self->EnsureProfileSpaces();
            self->QueueSnapshot();
          }, weak_factory_.GetWeakPtr()));
    }
    QueueSnapshot();
  }

  std::optional<base::DictValue> browser_import_result_;

  // The newest batch of archived tabs, which "Undo" reopens.
  std::vector<OrganizationUndo> organization_undo_;
  std::string last_archive_space_;
  size_t last_archive_count_ = 0;
  int archive_generation_ = 0;
  raw_ptr<BrowserView> view_;
  raw_ptr<TabStripModel> tabs_;
  raw_ptr<ProfileAttributesStorage> profiles_;
  SpaceCatalog catalog_;
  PrefChangeRegistrar space_observer_;
  base::ScopedObservation<ThemeService, ThemeServiceObserver> theme_observation_{this};
  base::ScopedObservation<infobars::InfoBarManager, infobars::InfoBarManager::Observer> notice_observation_{this};
  std::map<infobars::InfoBar*, std::string> notice_ids_;
  uint64_t notice_sequence_ = 0;
  std::string test_notice_action_;
  std::unique_ptr<download::AllDownloadItemNotifier> download_notifier_;
  base::OneShotTimer download_throttle_;
  base::OneShotTimer download_expiry_;
  base::CallbackListSubscription close_subscription_;
  std::shared_ptr<WindowGroup> group_ = std::make_shared<WindowGroup>();
  std::string active_space_;
  std::string switch_preview_space_;
  std::map<std::string, int> selected_tabs_;
  bool switching_space_ = false;
  base::OneShotTimer swipe_release_timeout_;
  bool restored_group_attached_ = false;
  raw_ptr<views::NativeViewHost> host_;
  raw_ptr<views::NativeViewHost> page_frame_host_;
  raw_ptr<views::NativeViewHost> backdrop_host_;
  raw_ptr<views::NativeViewHost> header_host_;
  raw_ptr<views::NativeViewHost> resize_host_;
  raw_ptr<views::NativeViewHost> edge_host_;
  BarkSidebarEdgeView* __strong edge_hint_ = nil;
  raw_ptr<views::View> site_anchor_;
  raw_ptr<views::View> extensions_anchor_;
  // Retained Swift object, released by BarkSwiftSidebarDestroy. This is an
  // opaque runtime handle, not a C++ object allocated by PartitionAlloc.
  RAW_PTR_EXCLUSION void* swift_ = nullptr;
  RAW_PTR_EXCLUSION void* header_swift_ = nullptr;
  RAW_PTR_EXCLUSION void* resize_swift_ = nullptr;
  RAW_PTR_EXCLUSION void* page_frame_swift_ = nullptr;
  RAW_PTR_EXCLUSION void* backdrop_swift_ = nullptr;
  std::unique_ptr<AutocompleteController> autocomplete_;
  std::string suggest_query_;
  // Page URL -> base64 favicon PNG ("" while pending or when none is stored).
  std::map<std::string, std::string> suggestion_favicons_;
  base::CancelableTaskTracker suggestion_favicon_tasks_;
  int width_ = 260;
  bool snapshot_pending_ = false;
  bool site_controls_open_ = false;
  bool preferences_open_ = false;
  base::RepeatingTimer site_controls_timer_;
  base::TimeTicks last_snapshot_;
  bool collapsed_ = false;
  bool revealed_ = false;
  bool traffic_lights_managed_ = false;
  double sidebar_progress_ = 1;
  struct TrafficLightFrame {
    NSRect original = NSZeroRect;
    NSRect applied = NSZeroRect;
    bool initialized = false;
  };
  std::map<NSWindowButton, TrafficLightFrame> traffic_light_frames_;
  double sidebar_velocity_ = 0;
  double sidebar_target_ = 1;
  base::TimeTicks sidebar_motion_start_;
  base::TimeTicks sidebar_motion_tick_;
  base::RepeatingTimer sidebar_motion_timer_;
  // Space presentation; see BeginReveal().
  bool concealed_ = false;
  bool revealing_ = false;
  bool reveal_ready_ = false;
  base::TimeTicks reveal_not_before_;
  std::vector<base::WeakPtr<Impl>> reveal_outgoing_;
  base::OneShotTimer reveal_timeout_;
  base::OneShotTimer reveal_delay_;
  base::RepeatingTimer fade_timer_;
  base::TimeTicks fade_start_;
  std::map<int, base::WeakPtr<content::WebContents>> pending_pin_closes_;
  base::CancelableTaskTracker pin_history_tasks_;
  base::WeakPtr<content::WebContents> just_closed_pin_;
  // Tab IDs, most recently shown first, for Control-Tab.
  std::vector<int> recent_tabs_;
  // The tab the sidebar's media player showed last.
  int media_tab_ = -1;
  base::RepeatingTimer archive_timer_;
  std::vector<std::unique_ptr<Popup>> popups_;
  RAW_PTR_EXCLUSION void* promotion_cover_ = nullptr;
  base::WeakPtr<content::WebContents> covered_contents_;
  base::WeakPtrFactory<Impl> promotion_weak_factory_{this};
  base::WeakPtrFactory<Impl> reveal_weak_factory_{this};
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

BEGIN_METADATA(SidebarMac::Impl, LittleWindowAnchor)
END_METADATA

bool SidebarMac::IsPeek(const BrowserView* view) {
  return view->GetProperty(kBarkPeek);
}

views::View* SidebarMac::LittleToolbarAnchor(const BrowserView* view, bool extensions) {
  return view->GetProperty(extensions ? kLittleExtensionsAnchor : kLittleSiteAnchor);
}

bool SidebarMac::OpenStandaloneLittleWindow(Profile* profile, const GURL& url) {
  if (!IsSwiftUIEnabled() || !LittleWindowEnabled() || !profile->IsRegularProfile() ||
      !url.SchemeIsHTTPOrHTTPS()) return false;
  if (Impl::OpenExternalLink(url)) return true;
  SpaceCatalog catalog(g_browser_process->local_state());
  Impl::EnsureProfileSpaces(catalog, g_browser_process->profile_manager()->GetProfileAttributesStorage());
  auto* popup = Impl::OpenStandaloneLittle(profile, url,
      catalog.FirstForProfile(profile->GetPath().BaseName().AsUTF8Unsafe()));
  if (!popup) return false;
  ExternalLink() = &Impl::OpenExternalLink;
  Impl::SyncGlobalLittleShortcut();
  return true;
}

namespace {
// chrome.windows.create({type: "popup"}) opens an app popup named for the
// calling extension. Web app popups and other window types keep their frames.
bool IsExtensionPopup(BrowserWindowInterface* browser) {
  if (browser->GetType() != BrowserWindowInterface::TYPE_APP_POPUP) return false;
  const auto* state = BrowserInitState::From(browser);
  constexpr std::string_view kPrefix = "_crx_";
  const std::string_view name = state ? state->create_params().app_name : std::string_view();
  return name.starts_with(kPrefix) &&
         extensions::ExtensionRegistry::Get(browser->GetProfile())->enabled_extensions().GetByID(
             std::string(name.substr(kPrefix.size())));
}
}  // namespace

void SidebarMac::AttachLittleWindow(BrowserWindowInterface* browser, content::WebContents* page) {
  if (browser->GetType() != BrowserWindowInterface::TYPE_POPUP && !IsExtensionPopup(browser)) return;
  if (!IsSwiftUIEnabled() || !browser->GetProfile()->IsRegularProfile()) return;
  Impl::AttachLittleWindow(browser, page);
  ExternalLink() = &Impl::OpenExternalLink;
  Impl::SyncGlobalLittleShortcut();
}

bool SidebarMac::IsEnabled(BrowserWindowInterface* browser) {
  InitializeUpdater();
  return UsesSidebar(*browser);
}
SidebarMac::SidebarMac(BrowserView* view) : impl_(std::make_unique<Impl>(view)) {}
SidebarMac::~SidebarMac() = default;
bool SidebarMac::CanShow() const { return impl_->CanShow(); }
int SidebarMac::width() const { return impl_->width(); }
void SidebarMac::Layout() { impl_->Layout(); }
void SidebarMac::FocusAddress() { impl_->FocusAddress(); }
views::View* SidebarMac::bubble_anchor(bool extensions) const {
  return impl_->bubble_anchor(extensions);
}
}  // namespace bark
