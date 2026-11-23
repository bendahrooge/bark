#include "bark/native_ui_mac.h"

#import <Foundation/Foundation.h>

#include "base/command_line.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"

namespace bark {

bool IsSwiftUIEnabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch("bark-swift-ui") ||
         [[NSBundle.mainBundle objectForInfoDictionaryKey:@"BarkEnableSwiftUI"]
             boolValue];
}

bool UsesSidebar(const BrowserWindowInterface& browser) {
  if (!IsSwiftUIEnabled() ||
      browser.GetType() != BrowserWindowInterface::Type::TYPE_NORMAL) {
    return false;
  }
  const Profile* profile = browser.GetProfile();
  return profile && (profile->IsRegularProfile() || profile->IsIncognitoProfile());
}

}  // namespace bark
