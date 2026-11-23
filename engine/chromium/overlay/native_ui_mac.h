#ifndef BARK_NATIVE_UI_MAC_H_
#define BARK_NATIVE_UI_MAC_H_

#include "base/functional/callback_forward.h"

class BrowserWindowInterface;

namespace bark {

// Release apps opt into the Swift interface in Info.plist; development
// browsers can opt in at launch.
bool IsSwiftUIEnabled();
bool UsesSidebar(const BrowserWindowInterface& browser);
bool LittleWindowEnabled();
// Holds normal window creation until AppKit has delivered its startup URL.
bool DeferStartupWindow(base::OnceClosure launch);

}  // namespace bark

#endif  // BARK_NATIVE_UI_MAC_H_
