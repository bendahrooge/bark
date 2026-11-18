#include "bark/native_ui_mac.h"

#import <Foundation/Foundation.h>

#include "base/command_line.h"

namespace bark {

bool IsSwiftUIEnabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch("bark-swift-ui") ||
         [[NSBundle.mainBundle objectForInfoDictionaryKey:@"BarkEnableSwiftUI"]
             boolValue];
}

}  // namespace bark
