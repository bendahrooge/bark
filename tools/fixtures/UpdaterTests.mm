#import <AppKit/AppKit.h>
#include "updater_mac.h"

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Main"];
    NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:@"Bark" action:nil keyEquivalent:@""];
    appItem.submenu = [[NSMenu alloc] initWithTitle:@"Bark"];
    [menu addItem:appItem];
    NSApp.mainMenu = menu;
    bark::InitializeUpdater();
    bark::InitializeUpdater();
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    NSMenu* appMenu = appItem.submenu;
    if (appMenu.numberOfItems != 2) return 1;
    NSMenuItem* check = [appMenu itemWithTitle:@"Check for Updates…"];
    NSMenuItem* automatic = [appMenu itemWithTitle:@"Automatically Check for Updates"];
    if (!check || !automatic) return 2;
    if (![NSStringFromClass([check.target class]) isEqualToString:@"SPUStandardUpdaterController"]) return 3;
    id updater = [check.target valueForKey:@"updater"];
    if (![[updater valueForKey:@"canCheckForUpdates"] boolValue]) return 4;
    if ([[updater valueForKey:@"automaticallyChecksForUpdates"] boolValue]) return 5;
    [NSApp sendAction:automatic.action to:automatic.target from:automatic];
    if (![[updater valueForKey:@"automaticallyChecksForUpdates"] boolValue]) return 6;
    [NSApp sendAction:automatic.action to:automatic.target from:automatic];
    NSLog(@"Sparkle loaded, initialized once, and update controls work");
  }
  return 0;
}
