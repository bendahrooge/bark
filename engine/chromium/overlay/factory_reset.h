#ifndef BARK_FACTORY_RESET_H_
#define BARK_FACTORY_RESET_H_

#include <vector>

#include "base/files/file_path.h"

namespace bark {
// Called on a blocking sequence after confirmation in a regular profile.
bool ScheduleFactoryReset(const base::FilePath& user_data,
                          const std::vector<base::FilePath>& profiles);

// Reserve the singleton on the UI thread before dispatching the marker write.
void BeginFactoryReset();
bool ShouldRetainDataLockForReset();
bool FinishFactoryResetOnExit(const base::FilePath& user_data);

// Called with exclusive ownership, after all profile writers have stopped or
// before any profile opens if the previous shutdown was interrupted.
bool FinishPendingFactoryReset(const base::FilePath& user_data);
}  // namespace bark

#endif  // BARK_FACTORY_RESET_H_
