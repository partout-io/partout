// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Profile {
    public enum DiffResult: Hashable, Sendable {
        public enum BehaviorChange: Hashable, Sendable {
            case disconnectsOnSleep
            case includesAllNetworks
        }

        case changedName
        case changedBehavior([BehaviorChange])
        case changedActiveModules
        case addedModules([UniqueID])
        case removedModules([UniqueID])
        case changedModules([UniqueID])
    }

    public func differences(from previous: Profile) -> Set<DiffResult> {
        var diff: [DiffResult] = []
        if previous.name != name {
            diff.append(.changedName)
        }
        if previous.behavior != behavior {
            var changes: [DiffResult.BehaviorChange] = []
            let previousBehavior = previous.behavior ?? .default
            let thisBehavior = behavior ?? .default
            if previousBehavior.disconnectsOnSleep != thisBehavior.disconnectsOnSleep {
                changes.append(.disconnectsOnSleep)
            }
            if previousBehavior.includesAllNetworks != thisBehavior.includesAllNetworks {
                changes.append(.includesAllNetworks)
            }
            diff.append(.changedBehavior(changes))
        }
        if previous.activeModulesIds != activeModulesIds {
            diff.append(.changedActiveModules)
        }
        // removed = only here, not in other
        let removedModules = previous.modules
            .filter {
                module(withId: $0.id) == nil
            }
            .map(\.id)
        // added = not here, only in other
        let addedModules = modules
            .filter {
                previous.module(withId: $0.id) == nil
            }
            .map(\.id)
        // changed = in both but modified content
        let changedModules = modules
            .filter {
                guard let previousModule = previous.module(withId: $0.id) else { return false }
                return $0.fingerprint != previousModule.fingerprint
            }
            .map(\.id)
        if !addedModules.isEmpty {
            diff.append(.addedModules(addedModules))
        }
        if !removedModules.isEmpty {
            diff.append(.removedModules(removedModules))
        }
        if !changedModules.isEmpty {
            diff.append(.changedModules(changedModules))
        }
        return Set(diff)
    }
}
