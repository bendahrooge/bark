#ifndef BARK_MAC_UPDATER_MAC_H_
#define BARK_MAC_UPDATER_MAC_H_

namespace bark {
// Called on the browser UI thread. Only packaged releases have update settings.
void InitializeUpdater();
}

#endif  // BARK_MAC_UPDATER_MAC_H_
