// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "loop.h"
#include "winrt/log.h"
#include <winrt/base.h>
#include <stdexcept>
#include <atomic>

namespace Partout {
namespace {
std::atomic<RuntimeLoop *> current_loop = nullptr;
std::mutex runtime_mutex;
}

RuntimeLoop *RuntimeLoop::Current() {
    return current_loop.load();
}

RuntimeLoop::RuntimeLoop() {
    std::lock_guard runtime_lock(runtime_mutex);
    if (current_loop.load())
        throw std::runtime_error("A RuntimeLoop is already active");
    // Publish only after apartment initialization succeeds below. Creation and
    // destruction are serialized by the runtime owner, before/after its users.
    auto started = started_.get_future();
    try {
        worker_ = std::thread([this] {
            Run();
        });
        started.get();
        current_loop = this;
    } catch (...) {
        if (worker_.joinable())
            worker_.join();
        throw;
    }
}

RuntimeLoop::~RuntimeLoop() {
    std::lock_guard runtime_lock(runtime_mutex);
    current_loop = nullptr;
    {
        std::lock_guard lock(mutex_);
        quitting_ = true;
    }
    changed_.notify_one();
    worker_.join();
}

bool RuntimeLoop::IsWorker() const {
    return std::this_thread::get_id() == worker_id_;
}

void RuntimeLoop::Drain() {
    Invoke([] {});
}

void RuntimeLoop::Post(std::function<void()> command) {
    {
        std::lock_guard lock(mutex_);
        if (quitting_)
            throw std::runtime_error("RuntimeLoop is closed");
        commands_.push_back(std::move(command));
    }
    changed_.notify_one();
}

void RuntimeLoop::Run() {
    worker_id_ = std::this_thread::get_id();
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
        started_.set_exception(std::current_exception());
        return;
    }
    started_.set_value();
    for (;;) {
        std::function<void()> command;
        {
            std::unique_lock lock(mutex_);
            changed_.wait(lock, [&] {
                return quitting_ || !commands_.empty();
            });
            if (commands_.empty())
                break;
            command = std::move(commands_.front());
            commands_.pop_front();
        }
        try {
            command();
        } catch (...) {
            winrt_log(WinrtLogError, "Partout::RuntimeLoop: command failed: HRESULT=0x%08x",
                      static_cast<unsigned>(winrt::to_hresult().value));
        }
    }
    // Cached activation factories must not survive the apartment that supplied
    // them when the last native worker is released and a later one is created.
    winrt::clear_factory_cache();
    winrt::uninit_apartment();
}
} // namespace Partout
