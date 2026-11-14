#ifndef BARK_MAC_ARC_IMPORTER_H_
#define BARK_MAC_ARC_IMPORTER_H_

#include <string>
#include "base/functional/callback.h"
#include "base/values.h"

namespace bark {
// Suppresses automatic empty spaces while the importer is creating profiles;
// every imported profile receives its selected spaces before completion.
bool IsArcImportInProgress();
// Validates the whole request before creating profiles. Writes only to Bark's
// normal services; the Arc installation is read only by ArcImportReader.
void ImportArc(const std::string& json,
               base::OnceCallback<void(base::DictValue)> completion);
}  // namespace bark
#endif
