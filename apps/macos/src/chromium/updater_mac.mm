#include "updater_mac.h"

#import <AppKit/AppKit.h>

// Load the bundled framework at runtime so development builds do not require
// Sparkle and Chromium's sandbox helpers never link or initialize it. These
// selectors are Sparkle 2's public SPUStandardUpdaterController/SPUUpdater API.
@protocol BarkSparkleUpdater
@property(nonatomic) BOOL automaticallyChecksForUpdates;
@end

@protocol BarkSparkleController
- (instancetype)initWithStartingUpdater:(BOOL)start
                       updaterDelegate:(id)delegate
                    userDriverDelegate:(id)driverDelegate;
- (void)checkForUpdates:(id)sender;
@property(readonly) id<BarkSparkleUpdater> updater;
@end

@interface BarkUpdateSettings : NSObject <NSMenuItemValidation>
@property(nonatomic, strong) id<BarkSparkleController> controller;
- (void)toggleAutomaticChecks:(id)sender;
@end

@implementation BarkUpdateSettings
- (void)toggleAutomaticChecks:(id)sender {
  self.controller.updater.automaticallyChecksForUpdates =
      !self.controller.updater.automaticallyChecksForUpdates;
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
  item.state = self.controller.updater.automaticallyChecksForUpdates
                   ? NSControlStateValueOn : NSControlStateValueOff;
  return YES;
}
@end

namespace bark {
void InitializeUpdater() {
  if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"SUFeedURL"])
    return;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Browser windows may be constructed before the application menu is ready.
    dispatch_async(dispatch_get_main_queue(), ^{
      NSURL* url = [[[NSBundle mainBundle] privateFrameworksURL]
          URLByAppendingPathComponent:@"Sparkle.framework"];
      NSError* error = nil;
      if (![[NSBundle bundleWithURL:url] loadAndReturnError:&error]) {
        NSLog(@"Bark could not load its update framework: %@", error);
        return;
      }
      Class controllerClass = NSClassFromString(@"SPUStandardUpdaterController");
      if (!controllerClass) {
        NSLog(@"Bark's update framework is missing its controller");
        return;
      }
      static BarkUpdateSettings* settings;
      settings = [[BarkUpdateSettings alloc] init];
      settings.controller = [(id<BarkSparkleController>)[controllerClass alloc]
          initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];
      NSMenu* appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
      NSMenuItem* check = [[NSMenuItem alloc]
          initWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:)
          keyEquivalent:@""];
      check.target = settings.controller;
      [appMenu insertItem:check atIndex:MIN(1, appMenu.numberOfItems)];
      NSMenuItem* automatic = [[NSMenuItem alloc]
          initWithTitle:@"Automatically Check for Updates"
          action:@selector(toggleAutomaticChecks:) keyEquivalent:@""];
      automatic.target = settings;
      [appMenu insertItem:automatic atIndex:MIN(2, appMenu.numberOfItems)];
    });
  });
}
}  // namespace bark
