#include "bark/factory_reset_mac.h"

#import <AppKit/AppKit.h>

#include "base/apple/bundle_locations.h"
#include "base/apple/foundation_util.h"
#include "base/files/file_util.h"
#include "base/strings/sys_string_conversions.h"

namespace bark {
bool ClearFactoryResetMacData() {
  NSString* identifier = base::apple::OuterBundle().bundleIdentifier;
  if (!identifier.length || ![identifier isEqual:identifier.lastPathComponent] ||
      [identifier isEqual:@"."] || [identifier isEqual:@".."]) return false;
  const std::string bundle = base::SysNSStringToUTF8(identifier);
  base::FilePath library;
  if (!base::apple::GetUserDirectory(NSLibraryDirectory, &library)) return false;
  for (const auto& path : {library.Append("Caches").Append(bundle),
                           library.Append("HTTPStorages").Append(bundle),
                           library.Append("HTTPStorages").Append(bundle + ".binarycookies"),
                           library.Append("Saved Application State").Append(bundle + ".savedState"),
                           library.Append("WebKit").Append(bundle)}) {
    if (!base::DeletePathRecursively(path)) return false;
  }
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  [defaults removePersistentDomainForName:identifier];
  return [defaults synchronize];
}

void ShowFactoryResetError() {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Bark couldn’t finish its factory reset";
  alert.informativeText = @"Check that Bark can write to its data folder, then reopen it to retry.";
  [alert runModal];
}
}  // namespace bark
