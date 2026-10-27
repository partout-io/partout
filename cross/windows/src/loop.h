// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <functional>
#include <future>
#include <memory>
#include <utility>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

namespace Partout {
// One native command worker. Completions go directly to the consumer's mailbox
// (or WireGuard's passive adapter); this class never dispatches protocol code.
class RuntimeLoop {
public:
    RuntimeLoop();
    ~RuntimeLoop();
    RuntimeLoop(const RuntimeLoop &) = delete;
    RuntimeLoop &operator=(const RuntimeLoop &) = delete;

    // Borrowed process runtime. Its owner must quiesce all users before destruction.
    // Only one runtime may be active, matching the daemon's process-wide lifetime.
    static RuntimeLoop *Current();
    bool IsWorker() const;
    void Schedule(std::function<void()> command);
    void Drain();

    // Setup and lifecycle barriers only. Packet writes and resumes use Schedule.
    template <typename Task> auto Perform(Task &&task) -> decltype(task()) {
        if (IsWorker()) return task();
        using Result = decltype(task());
        // std::function requires a copyable callback; packaged_task is move-only.
        auto command = std::make_shared<std::packaged_task<Result()>>(std::forward<Task>(task));
        auto result = command->get_future();
        Schedule([command] {
            (*command)();
        });
        return result.get();
    }

private:
    std::mutex mutex_;
    std::condition_variable changed_;
    std::deque<std::function<void()>> commands_;
    bool quitting_ = false;
    std::thread worker_;
    std::thread::id worker_id_;
    std::promise<void> started_;
    void Run();
};
} // namespace Partout
