import AppKit

// MARK: - Per-space window inspection

/// Shared filter for "normal user app windows" on a space. Both the window
/// count (#22) and the dominant-app detection (#23) need to apply the same
/// criteria so the subtitle/icon match the parenthesized count and Dock /
/// SystemUIServer / utility-panel / accessory-agent windows can't dominate
/// either calculation.
///
/// A window is included if all of the following hold:
///   - `SLSCopyWindowsWithOptionsAndTags(..., options: 2)` returns it
///     (on-screen, not minimized/hidden),
///   - `SLSGetWindowLevel == 0` (kCGNormalWindowLevel — excludes status bar,
///     Dock, menus, tooltips, floating/utility panels, sticky overlays),
///   - the owner connection resolves to a PID > 1 that isn't our own,
///   - `NSRunningApplication(processIdentifier:)` returns an app with
///     `activationPolicy == .regular` (excludes daemons, agents, and
///     accessory apps).
enum SpaceWindowInspector {
    static func forEachUserAppWindow(forSpace id64: CGSSpaceID,
                                     _ body: (NSRunningApplication) -> Void) {
        guard id64 != 0 else { return }
        let cid = CGSMainConnectionID()
        let spaces = [NSNumber(value: id64)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windows = SLSCopyWindowsWithOptionsAndTags(
            cid, 0, spaces, 2, &setTags, &clearTags) as? [Int]
        else { return }

        let ourPid = getpid()
        var appCache: [pid_t: NSRunningApplication?] = [:]
        for wid in windows {
            var level: Int32 = 0
            guard SLSGetWindowLevel(cid, UInt32(wid), &level) == 0,
                  level == 0
            else { continue }

            var ownerCID: Int32 = 0
            guard SLSGetWindowOwner(cid, UInt32(wid), &ownerCID) == 0
            else { continue }
            var pid: pid_t = 0
            guard SLSConnectionGetPID(ownerCID, &pid) == 0,
                  pid > 1, pid != ourPid
            else { continue }

            let app: NSRunningApplication?
            if let cached = appCache[pid] {
                app = cached
            } else {
                app = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = app
            }
            guard let app, app.activationPolicy == .regular else { continue }

            body(app)
        }
    }
}


// MARK: - Window counts per space

enum WindowCounter {
    /// Count of on-screen, normal-level windows on the given space owned by a
    /// regular (Dock-visible) app. See `SpaceWindowInspector` for the exact
    /// filter. Returns 0 if the space ID is unknown or the private API calls
    /// fail.
    static func count(forSpace id64: CGSSpaceID) -> Int {
        var count = 0
        SpaceWindowInspector.forEachUserAppWindow(forSpace: id64) { _ in
            count += 1
        }
        return count
    }
}


// MARK: - Dominant-app detection

enum DominantAppFinder {
    /// Returns the regular (Dock-visible) app that owns the most normal-level
    /// user windows on the given space, or nil if no such windows exist. Uses
    /// the same filter as `WindowCounter` so the subtitle/icon line up with
    /// the `(N)` count and so utility / accessory owners can't dominate.
    static func find(forSpace id64: CGSSpaceID) -> NSRunningApplication? {
        var pidCounts: [pid_t: Int] = [:]
        var appsByPid: [pid_t: NSRunningApplication] = [:]
        SpaceWindowInspector.forEachUserAppWindow(forSpace: id64) { app in
            pidCounts[app.processIdentifier, default: 0] += 1
            appsByPid[app.processIdentifier] = app
        }
        guard let topPid = pidCounts.max(by: { $0.value < $1.value })?.key
        else { return nil }
        return appsByPid[topPid]
    }
}
