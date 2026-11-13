#ifndef BARK_MAC_UPDATER_MAC_H_
#define BARK_MAC_UPDATER_MAC_H_

#include <string>

namespace bark {
// Called on the browser UI thread. Only packaged releases have update settings.
void InitializeUpdater();
bool IsUpdaterConfigured();
std::string ReleaseVersion();
// Opens the same Sparkle update flow used by the application menu.
void CheckForUpdates();
}

#endif  // BARK_MAC_UPDATER_MAC_H_
