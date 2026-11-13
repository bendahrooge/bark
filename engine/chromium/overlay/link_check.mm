// Exercise the same static Swift ABI and linker used by the browser framework.
#import <AppKit/AppKit.h>

extern "C" void* BarkSwiftSidebarCreate(void*, void (*)(void*, const char*));
extern "C" void BarkSwiftSidebarDestroy(void*);
extern "C" void* BarkSwiftSidebarHeaderCreate(void*);
extern "C" void BarkSwiftSidebarHeaderDestroy(void*);

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    void* sidebar = BarkSwiftSidebarCreate(nullptr, nullptr);
    void* header = BarkSwiftSidebarHeaderCreate(sidebar);
    BarkSwiftSidebarHeaderDestroy(header);
    BarkSwiftSidebarDestroy(sidebar);
  }
  return 0;
}
