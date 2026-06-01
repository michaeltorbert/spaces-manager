import AppKit

// MARK: - Per-space window inspection

struct SpaceWindowSummary {
    let count: Int
    let dominantApp: NSRunningApplication?
}

/// Shared filter for "normal user app windows" on spaces. Both the window
/// count (#22) and dominant-app detection (#23) apply this same criteria so
/// the subtitle/icon match the parenthesized count and Dock / SystemUIServer /
/// utility-panel / accessory-agent windows cannot dominate either calculation.
enum SpaceWindowInspector {
    private static let allSpacesMask: UInt32 = 0x7
    private static let minimumWindowDimension: CGFloat = 40

    private struct UserAppWindow {
        let id: UInt32
        let app: NSRunningApplication
    }

    private struct SummaryBuilder {
        var count = 0
        var pidCounts: [pid_t: Int] = [:]
        var appsByPid: [pid_t: NSRunningApplication] = [:]

        mutating func add(app: NSRunningApplication) {
            count += 1
            pidCounts[app.processIdentifier, default: 0] += 1
            appsByPid[app.processIdentifier] = app
        }

        var summary: SpaceWindowSummary {
            let topPid = pidCounts.max {
                if $0.value == $1.value {
                    return $0.key > $1.key
                }
                return $0.value < $1.value
            }?.key
            return SpaceWindowSummary(
                count: count,
                dominantApp: topPid.flatMap { appsByPid[$0] }
            )
        }
    }

    /// Returns per-space window summaries for the requested spaces. The window
    /// list comes from CoreGraphics, then each regular app window is mapped
    /// back to its Mission Control space membership through SkyLight.
    static func summaries(forSpaces spaceIDs: [CGSSpaceID]) -> [CGSSpaceID: SpaceWindowSummary] {
        let requestedSpaceIDs = Set(spaceIDs.filter { $0 != 0 })
        guard !requestedSpaceIDs.isEmpty else { return [:] }

        let cid = CGSMainConnectionID()
        var builders: [CGSSpaceID: SummaryBuilder] = [:]
        for window in userAppWindows() {
            for spaceID in spaces(forWindow: window.id, cid: cid) {
                guard requestedSpaceIDs.contains(spaceID) else { continue }
                builders[spaceID, default: SummaryBuilder()].add(app: window.app)
            }
        }
        return builders.mapValues { $0.summary }
    }

    private static func userAppWindows() -> [UserAppWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var windows: [UserAppWindow] = []
        let ourPid = getpid()
        var appCache: [pid_t: NSRunningApplication?] = [:]
        var seenWindowIDs = Set<UInt32>()

        for info in windowInfo {
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  seenWindowIDs.insert(windowID).inserted,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  isSubstantialWindow(info),
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }

            let pid = pid_t(pidNumber.int32Value)
            guard pid > 1, pid != ourPid else { continue }

            let app: NSRunningApplication?
            if let cached = appCache[pid] {
                app = cached
            } else {
                app = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = app
            }
            guard let app, app.activationPolicy == .regular else { continue }

            windows.append(UserAppWindow(id: windowID, app: app))
        }
        return windows
    }

    private static func isSubstantialWindow(_ info: [String: Any]) -> Bool {
        if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
           alpha <= 0 {
            return false
        }
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return false }
        return rect.width >= minimumWindowDimension
            && rect.height >= minimumWindowDimension
    }

    private static func spaces(forWindow windowID: UInt32,
                               cid: CGSConnectionID) -> [CGSSpaceID] {
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        guard let spaceNumbers = SLSCopySpacesForWindows(
            cid,
            allSpacesMask,
            windowIDs
        ) as? [NSNumber] else { return [] }

        return spaceNumbers
            .map { $0.uint64Value }
            .filter { $0 != 0 }
    }
}


// MARK: - Window counts per space

enum WindowCounter {
    /// Count of normal-level windows on the given space owned by a regular
    /// (Dock-visible) app. See `SpaceWindowInspector` for the exact filter.
    /// Returns 0 if the space ID is unknown or the private API calls fail.
    static func count(forSpace id64: CGSSpaceID) -> Int {
        SpaceWindowInspector.summaries(forSpaces: [id64])[id64]?.count ?? 0
    }
}


// MARK: - Dominant-app detection

enum DominantAppFinder {
    /// Returns the regular (Dock-visible) app that owns the most normal-level
    /// user windows on the given space, or nil if no such windows exist. Uses
    /// the same filter as `WindowCounter` so the subtitle/icon line up with
    /// the `(N)` count and so utility / accessory owners can't dominate.
    static func find(forSpace id64: CGSSpaceID) -> NSRunningApplication? {
        SpaceWindowInspector.summaries(forSpaces: [id64])[id64]?.dominantApp
    }
}
