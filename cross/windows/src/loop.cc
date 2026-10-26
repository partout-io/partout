// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "loop.h"
#include "winrt/log.h"
#include <winrt/base.h>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace Partout {
namespace {
thread_local winrt_loop current_loop = nullptr;
struct SubmissionScope {
    winrt_loop previous = current_loop;
    explicit SubmissionScope(winrt_loop loop) { current_loop = loop; }
    ~SubmissionScope() { current_loop = previous; }
};
}
winrt_loop CurrentLoop() { return current_loop; }

struct RuntimeLoop::State {
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<std::function<void()>> commands;
    bool quitting = false;
    std::thread worker;
    std::thread::id worker_id;
    std::promise<void> started;
};
RuntimeLoop::RuntimeLoop() : state_(std::make_unique<State>()) {
    auto started = state_->started.get_future();
    state_->worker = std::thread([this] { Run(); });
    try { started.get(); }
    catch (...) { state_->worker.join(); throw; }
}
RuntimeLoop::~RuntimeLoop() {
    { std::lock_guard lock(state_->mutex); state_->quitting = true; }
    state_->changed.notify_one();
    state_->worker.join();
}
bool RuntimeLoop::IsWorker() const { return std::this_thread::get_id() == state_->worker_id; }
void RuntimeLoop::Post(std::function<void()> command) {
    { std::lock_guard lock(state_->mutex);
      if (state_->quitting) throw std::runtime_error("RuntimeLoop is closed");
      state_->commands.push_back(std::move(command)); }
    state_->changed.notify_one();
}
void RuntimeLoop::Run() {
    auto &self = *state_;
    self.worker_id = std::this_thread::get_id();
    try { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
    catch (...) { self.started.set_exception(std::current_exception()); return; }
    self.started.set_value();
    for (;;) {
        std::function<void()> command;
        {
            std::unique_lock lock(self.mutex);
            self.changed.wait(lock, [&] { return self.quitting || !self.commands.empty(); });
            if (self.commands.empty()) break;
            command = std::move(self.commands.front());
            self.commands.pop_front();
        }
        try { command(); }
        catch (...) { winrt_log(WinrtLogError, "Partout::RuntimeLoop: command failed: HRESULT=0x%08x",
            static_cast<unsigned>(winrt::to_hresult().value)); }
    }
    // Cached activation factories must not survive the apartment that supplied
    // them when the last native worker is released and a later one is created.
    winrt::clear_factory_cache();
    winrt::uninit_apartment();
}
}

struct __winrt_loop_struct {
    Partout::RuntimeLoop handle;
    std::atomic<size_t> references{1};
};
namespace Partout {
RuntimeLoop &Loop(winrt_loop loop) { return loop->handle; }
void RetainLoop(winrt_loop loop) { ++loop->references; }
}
extern "C" {
winrt_loop winrt_loop_create(void) {
    try { return new __winrt_loop_struct{}; } catch (...) { return nullptr; }
}
bool winrt_loop_submit(winrt_loop loop, void (*execute)(void *), void *context) {
    try {
        loop->handle.Post([=] {
            Partout::SubmissionScope scope{loop};
            execute(context);
        });
        return true;
    } catch (...) { return false; }
}
void winrt_loop_free(winrt_loop loop) {
    if (!loop) return;
    // Setup may publish a retained transport while the owner closes.
    if (!loop->handle.IsWorker()) loop->handle.Invoke([] {});
    if (--loop->references == 0) delete loop;
}
}
