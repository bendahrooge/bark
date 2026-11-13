#ifndef BARK_SPACE_TEST_DRIVER_H_
#define BARK_SPACE_TEST_DRIVER_H_
#include "base/functional/callback.h"
#include "base/values.h"
namespace bark {
// Opt-in integration driver, available only alongside Chromium's private
// debugging pipe and within an explicitly selected disposable data directory.
void StartSpaceTestDriver(base::RepeatingCallback<base::DictValue(base::DictValue)> command);
}
#endif
