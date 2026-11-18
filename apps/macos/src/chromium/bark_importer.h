#ifndef BARK_MAC_BARK_IMPORTER_H_
#define BARK_MAC_BARK_IMPORTER_H_

#include <string>
#include "base/functional/callback.h"
#include "base/values.h"

namespace bark {
// Suppresses automatic empty spaces while the importer is creating profiles;
// every imported profile receives its selected spaces before completion.
bool IsBarkImportInProgress();
// Validates the whole request before creating profiles. Writes only to Bark's
// normal services. BarkImportReader reads the source data.
void ImportBrowserData(const std::string& json,
               base::OnceCallback<void(base::DictValue)> completion);
}  // namespace bark
#endif
