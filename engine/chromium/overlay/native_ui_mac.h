#ifndef BARK_NATIVE_UI_MAC_H_
#define BARK_NATIVE_UI_MAC_H_

namespace bark {

// Release apps opt into the Swift interface in Info.plist; development
// browsers can opt in at launch.
bool IsSwiftUIEnabled();

}  // namespace bark

#endif  // BARK_NATIVE_UI_MAC_H_
