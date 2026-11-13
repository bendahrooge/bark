#include "bark/mac/space_test_driver.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/thread_pool.h"
#include "base/timer/timer.h"

namespace bark {
namespace {
class Driver {
 public:
  Driver(base::FilePath directory,
         base::RepeatingCallback<base::DictValue(base::DictValue)> command)
      : directory_(std::move(directory)), command_(std::move(command)) {
    timer_.Start(FROM_HERE, base::Milliseconds(100), this, &Driver::Poll);
  }
 private:
  void Poll() {
    if (pending_) return;
    pending_ = true;
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE, {base::MayBlock()},
        base::BindOnce([](base::FilePath path) {
          std::string json;
          base::ReadFileToStringWithMaxSize(path, &json, 65536);
          return json;
        }, directory_.AppendASCII("request.json")),
        base::BindOnce(&Driver::Read, weak_factory_.GetWeakPtr()));
  }
  void Read(std::string json) {
    pending_ = false;
    auto request = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
    if (!request) return;
    int id = request->FindInt("requestId").value_or(0);
    if (id <= last_id_) return;
    last_id_ = id;
    auto result = command_.Run(std::move(*request));
    result.Set("requestId", id);
    auto response = base::WriteJson(result);
    if (!response) return;
    base::ThreadPool::PostTask(FROM_HERE, {base::MayBlock()},
        base::BindOnce([](base::FilePath directory, std::string text) {
          auto temporary = directory.AppendASCII("response.tmp");
          if (base::WriteFile(temporary, text))
            base::ReplaceFile(temporary, directory.AppendASCII("response.json"), nullptr);
        }, directory_, std::move(*response)));
  }
  base::FilePath directory_;
  base::RepeatingCallback<base::DictValue(base::DictValue)> command_;
  base::RepeatingTimer timer_;
  bool pending_ = false;
  int last_id_ = 0;
  base::WeakPtrFactory<Driver> weak_factory_{this};
};
}  // namespace
void StartSpaceTestDriver(base::RepeatingCallback<base::DictValue(base::DictValue)> command) {
  auto* flags = base::CommandLine::ForCurrentProcess();
  if (!flags->HasSwitch("remote-debugging-pipe") || !flags->HasSwitch("user-data-dir")) return;
  auto directory = flags->GetSwitchValuePath("bark-ui-test-directory");
  if (directory.empty() || !flags->GetSwitchValuePath("user-data-dir").IsParent(directory)) return;
  static base::NoDestructor<Driver> driver(directory, std::move(command));
}
}  // namespace bark
