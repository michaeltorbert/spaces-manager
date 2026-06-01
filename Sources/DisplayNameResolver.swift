import AppKit
import Foundation

enum DisplayNameResolver {
    /// Resolves CGS display identifiers in the caller-provided display order.
    /// Uses NSScreen, so call from UI/main-thread paths.
    static func names(for displayIDs: [String]) -> [String: String] {
        let screenNames = screenNamesByDisplayIdentifier()
        var usedCounts: [String: Int] = [:]
        var resolved: [String: String] = [:]

        for displayID in displayIDs {
            guard let baseName = screenNames[displayID]
                ?? screenNames[displayID.lowercased()]
            else { continue }

            let count = usedCounts[baseName, default: 0] + 1
            usedCounts[baseName] = count
            resolved[displayID] = count == 1 ? baseName : "\(baseName) \(count)"
        }

        return resolved
    }

    private static func screenNamesByDisplayIdentifier() -> [String: String] {
        var names: [String: String] = [:]

        func add(_ identifier: String, name: String) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, !trimmedName.isEmpty else { return }
            names[identifier] = trimmedName
            names[identifier.lowercased()] = trimmedName
        }

        let mainDisplayID = CGMainDisplayID()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            else { continue }

            let directDisplayID = CGDirectDisplayID(number.uint32Value)
            let localizedName = screen.localizedName
            add(String(directDisplayID), name: localizedName)

            if directDisplayID == mainDisplayID {
                add("Main", name: localizedName)
            }

            if let uuid = CGDisplayCreateUUIDFromDisplayID(directDisplayID)?
                .takeRetainedValue() {
                add(CFUUIDCreateString(nil, uuid) as String, name: localizedName)
            }
        }

        return names
    }
}
