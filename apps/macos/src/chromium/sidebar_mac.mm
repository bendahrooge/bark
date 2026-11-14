#include "bark/mac/sidebar_mac.h"
#include "bark/space_catalog.h"
#include "bark/space_tab_data.h"
#include "bark/mac/space_test_driver.h"
#include "bark/mac/updater_mac.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/base64.h"
#include "base/command_line.h"
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
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
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
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/bubble_anchor_util.h"
#include "chrome/browser/ui/extensions/extensions_container.h"
#include "chrome/browser/ui/page_info/page_info_dialog.h"
#include "chrome/browser/ui/recently_audible_helper.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/split_tab_metrics.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_frame_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "base/i18n/case_conversion.h"
#include "base/strings/string_split.h"
#include "components/download/content/public/all_download_item_notifier.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/download_manager.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "components/omnibox/browser/location_bar_model.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/split_tabs/split_tab_id.h"
#include "components/split_tabs/split_tab_visual_data.h"
#include "components/tabs/public/split_tab_data.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/url_fixer.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/window_open_disposition.h"
#include "ui/base/base_window.h"
#include "ui/gfx/image/image.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/widget/widget.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"

extern "C" {
void* BarkSwiftSidebarCreate(void*, void (*)(void*, const char*));
void BarkSwiftSidebarUpdate(void*, const char*);
void BarkSwiftSidebarFocusAddress(void*);
void BarkSwiftSidebarDestroy(void*);
void* BarkSwiftSidebarHeaderCreate(void*);
void BarkSwiftSidebarHeaderDestroy(void*);
void BarkSwiftSidebarSuggestions(void*, const char*);
}

namespace bark {
namespace {
constexpr char kEnableSwiftUI[] = "bark-swift-ui";
constexpr NSString* kSidebarWidth = @"BarkChromium.SidebarWidth";
constexpr NSString* kSidebarCollapsed = @"BarkChromium.SidebarCollapsed";
struct WindowGroup {
  std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  bool closing = false;
  bool restoring = false;
  // Set once the user explicitly selects a space in this window. A pending
  // session-restore presentation must not override that choice.
  bool user_presented = false;
  // True while a space switch cross-fades between this group's windows.
  int transitions = 0;
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

GURL AddressURL(const std::string& input) {
  if (input.empty()) return GURL("about:blank");
  GURL fixed = url_formatter::FixupURL(input, std::string());
  if (fixed.is_valid() &&
      (input.find(":") != std::string::npos ||
       input.find(".") != std::string::npos || input == "localhost")) {
    return fixed;
  }
  return GURL("https://www.google.com/search?q=" +
              base::EscapeQueryParamValue(input, true));
}
}  // namespace

class SidebarMac::Impl : public TabStripModelObserver,
                         public ProfileAttributesStorageObserver,
                         public ThemeServiceObserver,
                         public download::AllDownloadItemNotifier::Observer,
                         public AutocompleteController::Observer {
 public:
  explicit Impl(BrowserView* view)
      : view_(view), tabs_(view->browser()->GetTabStripModel()),
        profiles_(&g_browser_process->profile_manager()->GetProfileAttributesStorage()),
        catalog_(g_browser_process->local_state()) {
    Instances().push_back(this);
    if (!IsPrivate()) {
      SetSpaceProfileMover(&MoveFromSettings);
      EnsureProfileSpaces();
      active_space_ = catalog_.FirstForProfile(ProfileKey());
      space_observer_.Init(g_browser_process->local_state());
      space_observer_.Add(kSpacesPref, base::BindRepeating(&Impl::QueueSnapshot, weak_factory_.GetWeakPtr()));
      close_subscription_ = view_->browser()->RegisterBrowserDidClose(
          base::BindRepeating(&Impl::CloseOtherHosts, weak_factory_.GetWeakPtr()));
    }
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:kSidebarWidth];
    width_ = saved ? std::clamp<int>(saved, 200, 400) : 260;
    collapsed_ = [[NSUserDefaults standardUserDefaults] boolForKey:kSidebarCollapsed];
    // Native Chromium bubbles need Views anchors in the same widget. These
    // noninteractive views track the corresponding Swift controls.
    site_anchor_ = view_->AddChildView(std::make_unique<views::View>());
    extensions_anchor_ = view_->AddChildView(std::make_unique<views::View>());
    site_anchor_->SetCanProcessEventsWithinSubtree(false);
    extensions_anchor_->SetCanProcessEventsWithinSubtree(false);
    swift_ = BarkSwiftSidebarCreate(this, &ReceiveCommand);
    host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    host_->Attach(gfx::NativeView((__bridge NSView*)swift_));
    header_swift_ = BarkSwiftSidebarHeaderCreate(swift_);
    header_host_ = view_->AddChildView(std::make_unique<views::NativeViewHost>());
    header_host_->Attach(gfx::NativeView((__bridge NSView*)header_swift_));
    tabs_->AddObserver(this);
    profiles_->AddObserver(this);
    // The color mode can also change in chrome://settings.
    theme_observation_.Observe(ThemeServiceFactory::GetForProfile(view_->GetProfile()));
    if (auto* downloads = view_->GetProfile()->GetDownloadManager())
      download_notifier_ = std::make_unique<download::AllDownloadItemNotifier>(downloads, this);
    AdoptPendingPresentation();
    StartSpaceTestDriver(base::BindRepeating(&Impl::TestRequest));
    QueueSnapshot();
  }

  ~Impl() override {
    std::erase(Instances(), this);
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
    header_host_->Detach();
    view_->RemoveChildViewT(header_host_.ExtractAsDangling());
    BarkSwiftSidebarHeaderDestroy(header_swift_);
    host_->Detach();
    view_->RemoveChildViewT(host_.ExtractAsDangling());
    BarkSwiftSidebarDestroy(swift_);
    view_->RemoveChildViewT(site_anchor_.ExtractAsDangling());
    view_->RemoveChildViewT(extensions_anchor_.ExtractAsDangling());
  }

  int expanded_width() const {
    return std::min(width_, std::max(0, view_->width() - 500));
  }

  int width() const {
    return view_->IsFullscreen() || collapsed_ ? 0 : expanded_width();
  }

  void Layout() {
    const bool fullscreen = view_->IsFullscreen();
    const int sidebar_width = expanded_width();
    if (sidebar_width != last_layout_width_) {
      last_layout_width_ = sidebar_width;
      QueueSnapshot();
    }
    host_->SetVisible(!fullscreen && (!collapsed_ || revealed_) && sidebar_width > 0);
    // Separate hosts leave the actual traffic lights and their hit targets
    // untouched; the collapse control sits immediately alongside them.
    const auto params = view_->browser_widget()->GetFrameView()->GetBrowserLayoutParams();
    const int top = std::max(38, static_cast<int>(std::max(
        params.leading_exclusion.ContentWithPadding().height(),
        params.trailing_exclusion.ContentWithPadding().height())));
    host_->SetBounds(0, top, sidebar_width, std::max(0, view_->height() - top));
    header_host_->SetVisible(!fullscreen && sidebar_width > 0);
    const int compact_header_width = view_->GetProfile()->IsOffTheRecord() ? 56 : 28;
    header_host_->SetBounds(84, std::max(0, (top - 28) / 2),
                           collapsed_ ? compact_header_width : std::max(28, sidebar_width - 94), 28);
    const bool expanded = !collapsed_ || revealed_;
    site_anchor_->SetBounds(expanded ? 17 : 84, expanded ? top + 9 : 5, 24, 28);
    extensions_anchor_->SetBounds(expanded ? sidebar_width - 41 : 84,
                                  expanded ? top + 9 : 5, 24, 28);
    site_anchor_->SetVisible(!fullscreen);
    extensions_anchor_->SetVisible(!fullscreen);
  }

  views::View* bubble_anchor(bool extensions) const {
    return extensions ? extensions_anchor_.get() : site_anchor_.get();
  }

  void FocusAddress() {
    if (!tabs_ || tabs_->closing_all()) return;
    // The address bar opens centered over the window, so a collapsed sidebar
    // stays collapsed. Refresh first so it shows the active tab's URL.
    Snapshot();
    BarkSwiftSidebarFocusAddress(swift_);
  }

  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange&,
                             const TabStripSelectionChange&) override {
    QueueGroupSnapshot();
  }
  void OnTabChangedAt(tabs::TabInterface*, TabChangeType) override { QueueGroupSnapshot(); }
  void OnTabPinnedStateChanged(tabs::TabInterface*, int) override { QueueGroupSnapshot(); }
  void OnSplitTabChanged(const SplitTabChange&) override { QueueGroupSnapshot(); }
  void OnTabStripModelDestroyed(TabStripModel*) override { tabs_ = nullptr; }
  void OnProfileAdded(const base::FilePath&) override { QueueSnapshot(); }
  void OnProfileWasRemoved(const base::FilePath&, const std::u16string&) override { QueueSnapshot(); }
  void OnProfileNameChanged(const base::FilePath&, const std::u16string&) override { QueueSnapshot(); }
  void OnProfileIsOmittedChanged(const base::FilePath&) override { QueueSnapshot(); }
  void OnThemeChanged() override { QueueSnapshot(); }

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
  static std::vector<Impl*>& Instances() {
    static base::NoDestructor<std::vector<Impl*>> instances;
    return *instances;
  }
  static base::DictValue TestRequest(base::DictValue request) {
    if (auto* action = request.FindString("action"); action && *action != "snapshot") {
      for (auto* host : Instances()) {
        if (host->view_->browser()->GetSessionID().id() != request.FindInt("windowId").value_or(-1)) continue;
        if (*action == "testCloseWindow") chrome::CloseWindow(host->view_->browser());
        else if (auto json = base::WriteJson(request)) host->Command(*json);
        break;
      }
    }
    base::ListValue windows;
    for (auto* host : Instances()) {
      if (!host->tabs_ || host->tabs_->closing_all() || host->view_->browser()->IsDeleteScheduled()) continue;
      auto state = host->MakeSnapshot();
      state.Set("windowId", host->view_->browser()->GetSessionID().id());
      state.Set("windowGroup", host->group_->id);
      state.Set("visible", host->view_->browser()->GetWindow()->IsVisible());
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
        if (auto* helper = sessions::SessionTabHelper::FromWebContents(contents))
          tab.Set("sessionWindow", helper->window_id().id());
        all_tabs.Append(std::move(tab));
      }
      state.Set("allTabs", std::move(all_tabs));
      windows.Append(std::move(state));
    }
    base::DictValue result;
    result.Set("windows", std::move(windows));
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
  void EnsureProfileSpaces() {
    if (IsPrivate()) return;
    for (auto* entry : profiles_->GetAllProfilesAttributesSortedForDisplay()) {
      std::string key = entry->GetPath().BaseName().AsUTF8Unsafe();
      if (entry->IsOmitted() || !catalog_.FirstForProfile(key).empty()) continue;
      NSString* prefix = base::SysUTF8ToNSString("BarkChromium." + entry->GetPath().AsUTF8Unsafe());
      NSString* theme = [[NSUserDefaults standardUserDefaults] stringForKey:[prefix stringByAppendingString:@".theme"]];
      NSString* emoji = [[NSUserDefaults standardUserDefaults] stringForKey:[prefix stringByAppendingString:@".emoji"]];
      std::string name = base::UTF16ToUTF8(entry->GetName());
      if (name == "Your Chromium" || name == "Your Bark") name = "Personal";
      catalog_.Create(name, key, base::SysNSStringToUTF8(theme ?: @"gray"), base::SysNSStringToUTF8(emoji ?: @"🍃"));
    }
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
      }
    }
  }
  void RememberActiveSpace() {
    if (IsPrivate() || group_->closing || group_->restoring || active_space_.empty() ||
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
        if (widget) widget->SetVisibilityChangedAnimationsEnabled(true);
      }
      if (widget) widget->SetOpacity(1.f);
      host->QueueSnapshot();  // Lets its sidebar reset a finished swipe.
    }
    reveal_outgoing_.clear();
    group_->transitions = std::max(0, group_->transitions - 1);
    RememberActiveSpace();
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
    if (!tabs_ || tabs_->closing_all() || !SpaceBelongsHere(id)) return;
    AdoptTabs();
    OpenPendingTabs(id);
    active_space_ = id;
    int selection = -1;
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      if (GetTabSpace(contents) != id) continue;
      if (selection < 0 || selected_tabs_[id] == sessions::SessionTabHelper::IdForTab(contents).id()) selection = i;
    }
    if (selection >= 0) tabs_->ActivateTabAt(selection);
    else NavigateTo(GURL("about:blank"), true);
    // A favorite chosen from another profile's window.
    if (const int favorite = std::exchange(pending_favorite_, -1); favorite >= 0) {
      const int index = FindTab(favorite);
      if (tabs_->ContainsIndex(index) && IsFavorite(tabs_->GetWebContentsAt(index))) tabs_->ActivateTabAt(index);
    }
    QueueSnapshot();
  }
  void SwitchSpace(const std::string& id) {

    if (IsPrivate() || switching_space_) return;
    auto* space = catalog_.Find(id);
    if (!space || !space->FindString("profile")) return;
    const std::string profile_key = *space->FindString("profile");
    if (profile_key == ProfileKey()) {
      reveal_not_before_ = base::TimeTicks();
      SelectLocalSpace(id);
      return;
    }
    const base::FilePath path = ProfilePath(profile_key);
    if (path.empty()) return;
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
    if (IsPrivate()) return;
    const auto* space = catalog_.Find(id);
    const std::string* profile_key = space ? space->FindString("profile") : nullptr;
    if (!profile_key || *profile_key == ProfileKey()) return;
    const base::FilePath path = ProfilePath(*profile_key);
    auto* manager = g_browser_process->profile_manager();
    if (path.empty() || manager->GetProfileByPath(path)) return;
    manager->CreateProfileAsync(path, base::DoNothing());
  }
  void OpenSpaceProfile(const std::string& id, Profile* profile) {
    if (!profile) { switching_space_ = false; QueueSnapshot(); return; }
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
  void PresentSpace(const std::string& id, BrowserWindowInterface* browser) {
    switching_space_ = false;
    PendingPresentation().reset();
    if (!browser || browser->IsDeleteScheduled() || !tabs_ || tabs_->closing_all()) { QueueSnapshot(); return; }
    Impl* target = nullptr;
    for (auto* host : Instances()) if (host->view_->browser() == browser) target = host;
    if (!target || target->IsPrivate() || !target->SpaceBelongsHere(id)) {
      if (target) target->Unconceal();
      return;
    }
    // One logical Bark window owns profile-bound Chromium hosts. Never move a
    // WebContents to a different BrowserContext or copy profile storage.
    auto previous_group = target->group_;
    for (auto* host : Instances()) if (host->group_ == previous_group) {
      host->group_ = group_;
      if (host->tabs_) for (int i = 0; i < host->tabs_->count(); ++i)
        host->PersistTab(host->tabs_->GetWebContentsAt(i));
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
      for (auto& host : outgoing) if (host) host->view_->browser()->GetWindow()->Hide();
      target->RememberActiveSpace();
    }
    target->QueueSnapshot();
  }
  void CloseOtherHosts(BrowserWindowInterface*) {
    if (group_->closing) return;
    group_->closing = true;
    std::vector<base::WeakPtr<Impl>> others;
    for (auto* host : Instances()) {
      if (host != this && host->group_ == group_) others.push_back(host->weak_factory_.GetWeakPtr());
    }
    for (auto& host : others) {
      if (!host || !host->tabs_ || host->view_->browser()->IsDeleteScheduled()) continue;
      // Preserve Chromium's beforeunload confirmation, including its visible
      // window, when a background space contains an unfinished form.
      for (int i = 0; i < host->tabs_->count(); ++i) {
        if (host->tabs_->GetWebContentsAt(i)->NeedToFireBeforeUnload()) {
          host->view_->browser()->GetWindow()->Show();
          break;
        }
      }
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
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Impl::Snapshot, weak_factory_.GetWeakPtr()));
  }
  // Other windows of this logical window preview this window's spaces.
  void QueueGroupSnapshot() {
    QueueSnapshot();
    if (IsPrivate()) return;
    for (auto* host : Instances())
      if (host != this && host->group_ == group_ && !host->IsPrivate()) host->QueueSnapshot();
  }

  void Snapshot() {
    snapshot_pending_ = false;
    if (!tabs_ || tabs_->closing_all()) return;
    auto state = MakeSnapshot();
    SaveSpacePreviews();
    if (auto json = base::WriteJson(state)) BarkSwiftSidebarUpdate(swift_, json->c_str());
  }

  // Encodes one tab-strip entry for the Swift projection.
  base::DictValue TabValue(int i, bool active) const {
    auto* contents = tabs_->GetWebContentsAt(i);
    base::DictValue tab;
    tab.Set("id", sessions::SessionTabHelper::IdForTab(contents).id());
    tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
    tab.Set("url", contents->GetVisibleURL().spec());
    tab.Set("active", active);
    tab.Set("pinned", tabs_->IsTabPinned(i));
    tab.Set("loading", contents->IsLoading());
    auto* audio = RecentlyAudibleHelper::FromWebContents(contents);
    tab.Set("audible", audio && audio->WasRecentlyAudible());
    tab.Set("muted", contents->IsAudioMuted());
    // Both tabs of a split view are listed; the pair shown on screen is the
    // one containing the active tab.
    if (auto split = tabs_->GetSplitForTab(i)) {
      tab.Set("split", split->ToString());
      const int current = tabs_->active_index();
      tab.Set("splitActive", tabs_->ContainsIndex(current) && tabs_->GetSplitForTab(current) == split);
    }
    if (auto* driver = favicon::ContentFaviconDriver::FromWebContents(contents)) {
      gfx::Image icon = driver->GetFavicon();
      if (!icon.IsEmpty()) {
        auto png = icon.As1xPNGBytes();
        if (png && png->size() <= 262144) {
          tab.Set("favicon", base::Base64Encode(*png));
        }
      }
    }
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
      params.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
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
        params.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
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

  // Hosts whose tabs this window can switch to: every space of this logical
  // window, or only itself for a private window.
  std::vector<Impl*> SwitchableHosts() {
    std::vector<Impl*> hosts;
    for (auto* host : Instances()) {
      if (host == this || (!IsPrivate() && !host->IsPrivate() && host->group_ == group_))
        hosts.push_back(host);
    }
    return hosts;
  }

  // Open tabs whose title or URL contains every typed word, most recently
  // used first. An empty query lists recent tabs.
  base::ListValue MatchOpenTabs(const std::string& query, size_t limit) {
    const auto terms = base::SplitString(base::i18n::ToLower(base::UTF8ToUTF16(query)), u" ",
                                         base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    struct Candidate { raw_ptr<Impl> host; int index; base::TimeTicks last_active; };
    std::vector<Candidate> candidates;
    auto* current = tabs_->GetActiveWebContents();
    for (auto* host : SwitchableHosts()) {
      if (!host->tabs_ || host->tabs_->closing_all()) continue;
      for (int i = 0; i < host->tabs_->count(); ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        const GURL& url = contents->GetVisibleURL();
        if (contents == current || url.IsAboutBlank() || url.SchemeIs("chrome")) continue;
        const std::u16string haystack = base::i18n::ToLower(contents->GetTitle() + u" " + base::UTF8ToUTF16(url.spec()));
        if (std::ranges::all_of(terms, [&](const auto& term) { return haystack.find(term) != std::u16string::npos; }))
          candidates.push_back({host, i, contents->GetLastActiveTimeTicks()});
      }
    }
    std::ranges::sort(candidates, std::greater<>(), &Candidate::last_active);
    base::ListValue items;
    for (const auto& candidate : candidates) {
      if (items.size() >= limit) break;
      auto item = candidate.host->TabValue(candidate.index, false);
      item.Set("kind", "tab");
      if (!IsPrivate()) {
        auto* contents = candidate.host->tabs_->GetWebContentsAt(candidate.index);
        const auto* space = catalog_.Find(GetTabSpace(contents));
        if (candidate.host->IsFavorite(contents)) item.Set("space", "Favorites");
        else if (space && space->FindString("name")) item.Set("space", *space->FindString("name"));
      }
      items.Append(std::move(item));
    }
    return items;
  }

  void Suggest(const std::string& query) {
    suggest_query_ = query;
    const bool empty = base::TrimWhitespaceASCII(query, base::TRIM_ALL).empty();
    if (empty) {
      if (autocomplete_) autocomplete_->Stop(AutocompleteStopReason::kClobbered);
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

  void SendSuggestions() {
    constexpr size_t kMaxSuggestions = 8;
    const bool empty = base::TrimWhitespaceASCII(suggest_query_, base::TRIM_ALL).empty();
    base::ListValue items = MatchOpenTabs(suggest_query_, empty ? 5 : 3);
    std::set<std::string> seen;
    for (const auto& item : items) seen.insert(*item.GetDict().FindString("url"));
    if (!empty && autocomplete_) {
      for (const auto& match : autocomplete_->result()) {
        if (items.size() >= kMaxSuggestions) break;
        const GURL& url = match.destination_url;
        if (!url.is_valid() || !seen.insert(url.spec()).second) continue;
        base::DictValue item;
        const bool typed = match.type == omnibox::AutocompleteMatchType::kUrlWhatYouTyped;
        item.Set("kind", typed ? "url" : "history");
        item.Set("title", base::UTF16ToUTF8(typed ? match.contents : match.description));
        item.Set("url", url.spec());
        items.Append(std::move(item));
      }
    }
    base::DictValue message;
    message.Set("query", suggest_query_);
    message.Set("items", std::move(items));
    if (auto json = base::WriteJson(message)) BarkSwiftSidebarSuggestions(swift_, json->c_str());
  }

  // Activates an open tab from the address bar, switching space (and the
  // profile window) when the tab lives in another space.
  void SwitchToTab(int id) {
    for (auto* host : SwitchableHosts()) {
      if (!host->tabs_ || host->tabs_->closing_all()) continue;
      for (int i = 0; i < host->tabs_->count(); ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        if (sessions::SessionTabHelper::IdForTab(contents).id() != id) continue;
        const std::string space = GetTabSpace(contents);
        if (host->IsFavorite(contents)) {
          // Favorites belong to no space: show the window's current space.
          if (host == this) {
            tabs_->ActivateTabAt(i);
            contents->Focus();
          } else {
            host->pending_favorite_ = id;
            SwitchSpace(host->active_space_);
          }
        } else if (host == this && (IsPrivate() || space == active_space_)) {
          tabs_->ActivateTabAt(i);
          contents->Focus();
        } else if (host == this) {
          selected_tabs_[space] = id;
          SelectLocalSpace(space);
          contents->Focus();
        } else {
          host->selected_tabs_[space] = id;
          SwitchSpace(space);
        }
        return;
      }
    }
  }

  // Read-only tab list for a space shown while the user swipes toward it. The
  // space's tabs live in whichever host of this logical window owns its
  // profile; a profile that has not been opened yet simply has no tabs.
  base::ListValue SpacePreview(const std::string& space_id, const std::string& profile_key) const {
    constexpr int kPreviewTabLimit = 30;
    base::ListValue preview;
    for (auto* host : Instances()) {
      if (host->group_ != group_ || host->IsPrivate() || host->ProfileKey() != profile_key ||
          !host->tabs_ || host->tabs_->closing_all()) continue;
      auto selected = host->selected_tabs_.find(space_id);
      for (int i = 0; i < host->tabs_->count() && static_cast<int>(preview.size()) < kPreviewTabLimit; ++i) {
        auto* contents = host->tabs_->GetWebContentsAt(i);
        if (GetTabSpace(contents) != space_id) continue;
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
      if (!saved || !saved->FindString("url") || static_cast<int>(preview.size()) >= kPreviewTabLimit) continue;
      base::DictValue tab;
      tab.Set("id", placeholder_id--);
      tab.Set("title", saved->FindString("title") ? *saved->FindString("title") : std::string());
      tab.Set("url", *saved->FindString("url"));
      tab.Set("active", saved->FindBool("active").value_or(false));
      tab.Set("pinned", saved->FindBool("pinned").value_or(false));
      tab.Set("loading", false);
      preview.Append(std::move(tab));
    }
    return preview;
  }

  // Saves the tabs of this window's spaces so other windows can preview them
  // during a swipe even after a restart, before this profile's window opens.
  void SaveSpacePreviews() {
    if (IsPrivate() || !tabs_ || tabs_->closing_all() || group_->restoring) return;
    std::map<std::string, base::ListValue> by_space;
    for (int i = 0; i < tabs_->count(); ++i) {
      auto* contents = tabs_->GetWebContentsAt(i);
      const std::string space = GetTabSpace(contents);
      auto& tabs = by_space[space];
      if (!SpaceBelongsHere(space) || tabs.size() >= 30) continue;
      const GURL& url = contents->GetVisibleURL();
      base::DictValue tab;
      tab.Set("title", base::UTF16ToUTF8(contents->GetTitle()));
      tab.Set("url", url.spec());
      tab.Set("pinned", tabs_->IsTabPinned(i));
      auto selected = selected_tabs_.find(space);
      tab.Set("active", space == active_space_ ? tabs_->active_index() == i
                        : selected != selected_tabs_.end() &&
                              selected->second == sessions::SessionTabHelper::IdForTab(contents).id());
      tabs.Append(std::move(tab));
    }
    for (const auto& value : catalog_.List()) {
      const auto* space = value.GetIfDict();
      if (!space || !space->FindString("id") || !space->FindString("profile") ||
          *space->FindString("profile") != ProfileKey()) continue;
      auto found = by_space.find(*space->FindString("id"));
      catalog_.SetPreviewTabs(*space->FindString("id"),
                              found == by_space.end() ? base::ListValue() : std::move(found->second));
    }
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
          ProfilePath(*item->FindString("profile")).empty()) continue;
      auto space = item->Clone();
      space.Set("active", *item->FindString("id") == active_space_);
      spaces.Append(std::move(space));
    }
    // Tabs of the spaces adjacent to the active one, for the swipe preview.
    base::DictValue previews;
    for (size_t i = 0; i < spaces.size(); ++i) {
      if (!spaces[i].GetDict().FindBool("active").value_or(false)) continue;
      for (size_t neighbor : {i - 1, i + 1}) {
        if (neighbor >= spaces.size()) continue;  // i - 1 wraps for i == 0.
        const auto& space = spaces[neighbor].GetDict();
        const std::string id = *space.FindString("id");
        previews.Set(id, SpacePreview(id, *space.FindString("profile")));
      }
      break;
    }
    base::DictValue state;
    state.Set("sidebarCollapsed", collapsed_);
    state.Set("sidebarRevealed", revealed_);
    state.Set("sidebarWidth", expanded_width());
    state.Set("tabs", std::move(tab_list));
    state.Set("favorites", std::move(favorites));
    state.Set("downloads", DownloadState());
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
    if (active) {
      if (auto* location = LocationBarModel::From(view_->browser())) {
        const auto security = location->GetSecurityLevel();
        state.Set("securityLevel", security == security_state::DANGEROUS ? "dangerous" :
            security == security_state::WARNING ? "warning" : "neutral");
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

  // Chromium's own split view: two tabs of one space side by side. Chromium
  // keeps the pair adjacent in the tab strip and restores it with the session.
  void Unsplit(int index) {
    if (!tabs_->ContainsIndex(index)) return;
    if (auto split = tabs_->GetSplitForTab(index)) tabs_->RemoveSplit(*split);
  }

  // Shows the tab at `index` beside the active tab, on the leading or
  // trailing half of the page. A split holds two tabs, so a tab already in a
  // split leaves it first.
  void SplitWithActive(int index, bool leading) {
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
        {index}, split_tabs::SplitTabVisualData(split_tabs::SplitTabLayout::kSideBySide),
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

  void NavigateTo(const GURL& url, bool new_tab) {
    NavigateParams params(view_->browser(), url, ui::PAGE_TRANSITION_TYPED);
    params.disposition = new_tab || tabs_->empty()
        ? WindowOpenDisposition::NEW_FOREGROUND_TAB : WindowOpenDisposition::CURRENT_TAB;
    Navigate(&params);
    if (auto* contents = tabs_->GetActiveWebContents()) contents->Focus();
  }

  void Command(const std::string& json) {
    if (!tabs_ || tabs_->closing_all()) return;
    auto message = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
    if (!message) return;
    const std::string* action = message->FindString("action");
    if (!action) return;
    const std::string* text = message->FindString("text");
    int index = FindTab(message->FindInt("id").value_or(-1));
    auto* browser = view_->browser();
    const bool incognito = view_->GetProfile()->IsOffTheRecord();
    // Private windows have their own tabs, not a route into persistent space
    // creation or the original profile's appearance settings.
    if (incognito && (*action == "space" || *action == "createSpace" || *action == "deleteSpace" ||
                      *action == "manageSpaces" || *action == "moveTabToSpace" ||
                      *action == "createProfile" || *action == "customizeSpace" || *action == "appearance")) return;
    auto* active = tabs_->GetActiveWebContents();
    if (*action == "select" && tabs_->ContainsIndex(index)) {
      tabs_->ActivateTabAt(index);
      if (auto* contents = tabs_->GetActiveWebContents()) contents->Focus();
    } else if (*action == "close" && tabs_->ContainsIndex(index)) {
      tabs_->CloseWebContentsAt(index, CLOSE_USER_GESTURE);
      return;  // Closing the last tab may destroy this browser window.
    } else if (*action == "pin" && tabs_->ContainsIndex(index)) {
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
    } else if (*action == "moveTab" && tabs_->ContainsIndex(index)) {
      const auto* metadata = message->FindDict("metadata");
      int before = -1;
      const std::string* before_text = metadata ? metadata->FindString("before") : nullptr;
      if (before_text && !base::StringToInt(*before_text, &before)) before = -1;
      const std::string* zone = metadata ? metadata->FindString("zone") : nullptr;
      MoveTab(message->FindInt("id").value_or(-1), before,
              !zone ? (tabs_->IsTabPinned(index) ? TabZone::kPinned : TabZone::kUnpinned)
              : *zone == "favorites" ? TabZone::kFavorites
              : *zone == "pinned" ? TabZone::kPinned : TabZone::kUnpinned);
    } else if (*action == "splitTab" && tabs_->ContainsIndex(index)) {
      SplitWithActive(index, text && *text == "left");
    } else if (*action == "splitNew" && active) {
      // Chromium's "new split" page lists the open tabs to choose from.
      if (!tabs_->GetSplitForTab(tabs_->active_index()) && !IsFavorite(active))
        chrome::NewSplitTab(browser, split_tabs::SplitTabLayout::kSideBySide,
                            split_tabs::SplitTabCreatedSource::kKeyboardShortcut);
    } else if (*action == "unsplit") {
      Unsplit(tabs_->ContainsIndex(index) ? index : tabs_->active_index());
    } else if (*action == "new") {
      // Same path as Cmd+T, so Chromium focuses the address bar for the new
      // tab and Bark presents the centered address bar.
      chrome::NewTab(browser, NewTabTypes::kNewTabButton);
    } else if (*action == "suggest" && text) {
      Suggest(*text);
      return;  // Suggestions are not part of the sidebar snapshot.
    } else if (*action == "switchToTab") {
      SwitchToTab(message->FindInt("id").value_or(-1));
    } else if (*action == "navigate" && text) {
      NavigateTo(AddressURL(*text), false);
    } else if (*action == "back" && active && chrome::CanGoBack(active)) {
      chrome::GoBack(browser, WindowOpenDisposition::CURRENT_TAB);
    } else if (*action == "forward" && active && chrome::CanGoForward(active)) {
      chrome::GoForward(browser, WindowOpenDisposition::CURRENT_TAB);
    } else if (*action == "reload" && active) {
      chrome::Reload(browser, WindowOpenDisposition::CURRENT_TAB);
    } else if (*action == "stop" && active) {
      chrome::Stop(browser);
    } else if (*action == "extensions") {
      NavigateTo(GURL("chrome://extensions/"), true);
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
    } else if (*action == "archiveTabs") {
      ArchiveTabs();
    } else if (*action == "restoreArchived" && message->FindInt("id").value_or(-1) >= 0) {
      RestoreArchived(static_cast<size_t>(*message->FindInt("id")));
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
      // Fails for a profile's last space. Its tabs are adopted by a
      // remaining space of the profile on the next snapshot.
      catalog_.Remove(*text);
    } else if (*action == "manageSpaces") {
      NavigateTo(GURL("chrome://spaces/"), true);
    } else if (*action == "settings") {
      NavigateTo(GURL("chrome://settings/"), true);
    } else if (*action == "hostActivated" && !group_->closing && !group_->restoring &&
               group_->transitions == 0 && !concealed_ && browser->GetWindow()->IsVisible()) {
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
      view_->InvalidateLayout();
    } else if (*action == "revealSidebar" && text) {
      revealed_ = collapsed_ && *text == "true";
      view_->InvalidateLayout();
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
      if (auto* metadata = message->FindDict("metadata")) {
        if (auto* after = metadata->FindString("revealAfter")) {
          int ms = 0;
          if (base::StringToInt(*after, &ms))
            reveal_not_before_ = base::TimeTicks::Now() + base::Milliseconds(std::clamp(ms, 0, 500));
        }
      }
      SwitchSpace(*text);
    } else if (*action == "prepareSpace" && text) {
      PrepareSpace(*text);
    } else if (*action == "createSpace" && text && !text->empty() && text->size() <= 128) {
      std::string theme = "gray";
      std::string emoji = "🍃";
      std::string profile_key = ProfileKey();
      if (auto* metadata = message->FindDict("metadata")) {
        if (auto* value = metadata->FindString("theme"); value && value->size() <= 32) theme = *value;
        if (auto* value = metadata->FindString("emoji"); value && value->size() <= 256) emoji = *value;
        if (auto* value = metadata->FindString("profile")) profile_key = *value;
      }
      if (!ProfilePath(profile_key).empty()) {
        AdoptTabs();
        auto id = catalog_.Create(*text, profile_key, theme, emoji);
        if (!id.empty()) SwitchSpace(id);
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
      }
    } else if (*action == "setSpaceProfile") {
      if (auto* metadata = message->FindDict("metadata")) {
        auto* space = metadata->FindString("space");
        auto* profile = metadata->FindString("profile");
        if (space && profile) MoveSpaceToProfile(*space, *profile);
      }
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

  // The newest batch of archived tabs, which "Undo" reopens.
  std::string last_archive_space_;
  size_t last_archive_count_ = 0;
  raw_ptr<BrowserView> view_;
  raw_ptr<TabStripModel> tabs_;
  raw_ptr<ProfileAttributesStorage> profiles_;
  SpaceCatalog catalog_;
  PrefChangeRegistrar space_observer_;
  base::ScopedObservation<ThemeService, ThemeServiceObserver> theme_observation_{this};
  std::unique_ptr<download::AllDownloadItemNotifier> download_notifier_;
  base::OneShotTimer download_throttle_;
  base::OneShotTimer download_expiry_;
  base::CallbackListSubscription close_subscription_;
  std::shared_ptr<WindowGroup> group_ = std::make_shared<WindowGroup>();
  std::string active_space_;
  std::map<std::string, int> selected_tabs_;
  int pending_favorite_ = -1;
  bool switching_space_ = false;
  bool restored_group_attached_ = false;
  raw_ptr<views::NativeViewHost> host_;
  raw_ptr<views::NativeViewHost> header_host_;
  raw_ptr<views::View> site_anchor_;
  raw_ptr<views::View> extensions_anchor_;
  // Retained Swift object, released by BarkSwiftSidebarDestroy. This is an
  // opaque runtime handle, not a C++ object allocated by PartitionAlloc.
  RAW_PTR_EXCLUSION void* swift_ = nullptr;
  RAW_PTR_EXCLUSION void* header_swift_ = nullptr;
  std::unique_ptr<AutocompleteController> autocomplete_;
  std::string suggest_query_;
  int width_ = 260;
  int last_layout_width_ = 0;
  bool snapshot_pending_ = false;
  bool collapsed_ = false;
  bool revealed_ = false;
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
  base::WeakPtrFactory<Impl> reveal_weak_factory_{this};
  base::WeakPtrFactory<Impl> weak_factory_{this};
};

bool SidebarMac::IsEnabled(BrowserWindowInterface* browser) {
  InitializeUpdater();
  const bool release_ui = [[[NSBundle mainBundle]
      objectForInfoDictionaryKey:@"BarkEnableSwiftUI"] boolValue];
  return (release_ui || base::CommandLine::ForCurrentProcess()->HasSwitch(kEnableSwiftUI)) &&
         browser->GetType() == BrowserWindowInterface::Type::TYPE_NORMAL &&
         (browser->GetProfile()->IsRegularProfile() ||
          browser->GetProfile()->IsIncognitoProfile());
}
SidebarMac::SidebarMac(BrowserView* view) : impl_(std::make_unique<Impl>(view)) {}
SidebarMac::~SidebarMac() = default;
int SidebarMac::width() const { return impl_->width(); }
void SidebarMac::Layout() { impl_->Layout(); }
void SidebarMac::FocusAddress() { impl_->FocusAddress(); }
views::View* SidebarMac::bubble_anchor(bool extensions) const {
  return impl_->bubble_anchor(extensions);
}
}  // namespace bark
