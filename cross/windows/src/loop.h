// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <functional>
#include <future>
#include <memory>
#include <utility>

namespace Partout {
// One native command worker. Completions go directly to the consumer's mailbox
// (or WireGuard's passive adapter); this class never dispatches protocol code.
class RuntimeLoop : public std::enable_shared_from_this<RuntimeLoop> {
public:
    RuntimeLoop();
    ~RuntimeLoop();
    RuntimeLoop(const RuntimeLoop &) = delete;
    RuntimeLoop &operator=(const RuntimeLoop &) = delete;

    bool IsWorker() const;
    void Post(std::function<void()> command);
    // Setup and lifecycle barriers only. Packet writes and resumes use Post.
    template<typename Task> auto Invoke(Task &&task) -> decltype(task()) {
        if (IsWorker()) return task();
        using Result = decltype(task());
        auto command = std::make_shared<std::packaged_task<Result()>>(std::forward<Task>(task));
        auto result = command->get_future();
        Post([command] { (*command)(); });
        return result.get();
    }
private:
    struct State;
    std::unique_ptr<State> state_;
    void Run();
};
}
