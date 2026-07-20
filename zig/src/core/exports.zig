// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Profiles are the foundations of Partout, and profiles are made of modules. A
//! basic module may statically represent a subset of the network settings of a
//! device (e.g. DNS), whereas a connection module describes how to establish a
//! connection to a remote service in order to obtain and apply such settings
//! (e.g. VPN, tunnel, proxy).
//!
//! The core module exposes the API model, registry and importer strategies,
//! serialization helpers, and bundled module types used to build those profiles.
//! Use its logging and error entities to track and troubleshoot the internal
//! library activities.

pub const actor = @import("actor.zig");
pub const api = @import("api.zig");
pub const concurrency = @import("concurrency.zig");
pub const logging = @import("logging.zig");
pub const util = @import("util.zig");

const registry = @import("registry.zig");
const uuid = @import("uuid.zig");

pub const Actor = actor.Actor;
pub const Condition = concurrency.Condition;
pub const Drainer = concurrency.Drainer;
pub const ImportContext = registry.ImportContext;
pub const ImportError = registry.ImportError;
pub const ModuleImplementation = registry.ModuleImplementation;
pub const Mutex = concurrency.Mutex;
pub const Registry = registry.Registry;
pub const RunAfter = concurrency.RunAfter;
pub const SerializeError = registry.SerializeError;

pub const isGeneratedId = uuid.isV4;
pub const newId = uuid.newId;
