// SPDX-FileCopyrightText: 2026 Davide De Rosa
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
        case enabledModules([UniqueID])
        case disabledModules([UniqueID])
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

        // Removed = only here, not in other
        let removedModules = previous.modules
            .filter {
                module(withId: $0.id) == nil
            }
            .map(\.id)

        // Added = not here, only in other
        let addedModules = modules
            .filter {
                previous.module(withId: $0.id) == nil
            }
            .map(\.id)

        // Changed = in both but modified content
        let changedModules = modules
            .filter {
                guard let previousModule = previous.module(withId: $0.id) else { return false }
                return $0.fingerprint != previousModule.fingerprint
            }
            .map(\.id)

        // Enabled/Disabled
        let enabledModules = modules
            .filter {
                !previous.activeModulesIds.contains($0.id) &&
                    activeModulesIds.contains($0.id)
            }
            .map(\.id)
        let disabledModules = modules
            .filter {
                previous.activeModulesIds.contains($0.id) &&
                    !activeModulesIds.contains($0.id)
            }
            .map(\.id)

        // Pack diff results
        if !addedModules.isEmpty {
            diff.append(.addedModules(addedModules))
        }
        if !removedModules.isEmpty {
            diff.append(.removedModules(removedModules))
        }
        if !changedModules.isEmpty {
            diff.append(.changedModules(changedModules))
        }
        if !enabledModules.isEmpty {
            diff.append(.enabledModules(enabledModules))
        }
        if !disabledModules.isEmpty {
            diff.append(.disabledModules(disabledModules))
        }

        return Set(diff)
    }
}
