import AppKit

// MARK: - Frontmost window relocation

enum SpaceWindowMoveResult {
    case moved
    case alreadyThere
    case noWindow
    case unsupportedSpace
    case failed
}

enum SpaceWindowMover {
    private static let allSpacesMask: UInt32 = 0x7
    private static let userSpaceType: Int32 = 0
    private static let compatWorkspaceID: Int32 = 0x79616265
    private static let minimumWindowDimension: CGFloat = 40
    private static let verificationAttempts = 4
    private static let verificationDelay: TimeInterval = 0.1

    static func movableFrontmostWindowSpaceIDs() -> Set<CGSSpaceID>? {
        guard let windowID = frontmostMovableWindowID() else { return nil }

        let cid = CGSMainConnectionID()
        let sourceSpaces = spaces(forWindow: windowID, cid: cid)
        guard sourceSpaces.contains(where: { SLSSpaceGetType(cid, $0) == userSpaceType }) else {
            return nil
        }
        return Set(sourceSpaces)
    }

    static func moveFrontmostWindow(to space: Space) -> SpaceWindowMoveResult {
        guard !space.isFullscreen, space.id64 != 0 else {
            return .unsupportedSpace
        }

        let cid = CGSMainConnectionID()
        guard SLSSpaceGetType(cid, space.id64) == userSpaceType else {
            return .unsupportedSpace
        }

        guard let windowID = frontmostMovableWindowID() else {
            return .noWindow
        }

        let sourceSpaces = spaces(forWindow: windowID, cid: cid)
        if sourceSpaces.contains(space.id64) {
            return .alreadyThere
        }
        guard let sourceSpace = sourceSpaces.first,
              SLSSpaceGetType(cid, sourceSpace) == userSpaceType
        else {
            return .unsupportedSpace
        }

        move(windowID: windowID, toSpaceID: space.id64, cid: cid)
        return waitForMove(of: windowID, to: space.id64, cid: cid) ? .moved : .failed
    }

    private static func frontmostMovableWindowID() -> UInt32? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var seenWindowIDs = Set<UInt32>()
        var appCache: [pid_t: NSRunningApplication?] = [:]
        for info in windowInfo {
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  seenWindowIDs.insert(windowID).inserted,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  isSubstantialWindow(info)
            else { continue }

            let pid = pid_t(pidNumber.int32Value)
            guard pid > 1, pid != getpid() else { continue }

            let app: NSRunningApplication?
            if let cached = appCache[pid] {
                app = cached
            } else {
                app = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = app
            }
            guard app?.activationPolicy == .regular else { continue }

            return windowID
        }
        return nil
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

    private static func move(windowID: UInt32,
                             toSpaceID spaceID: CGSSpaceID,
                             cid: CGSConnectionID) {
        if usesWorkspaceCompatibilityMove {
            var mutableWindowID = windowID
            _ = SLSSpaceSetCompatID(cid, spaceID, compatWorkspaceID)
            _ = SLSSetWindowListWorkspace(cid, &mutableWindowID, 1, compatWorkspaceID)
            _ = SLSSpaceSetCompatID(cid, spaceID, 0)
        } else {
            let windowIDs = [NSNumber(value: windowID)] as CFArray
            SLSMoveWindowsToManagedSpace(cid, windowIDs, spaceID)
        }
    }

    private static func waitForMove(of windowID: UInt32,
                                    to spaceID: CGSSpaceID,
                                    cid: CGSConnectionID) -> Bool {
        for attempt in 0..<verificationAttempts {
            if spaces(forWindow: windowID, cid: cid).contains(spaceID) {
                return true
            }
            if attempt < verificationAttempts - 1 {
                Thread.sleep(forTimeInterval: verificationDelay)
            }
        }
        return false
    }

    private static var usesWorkspaceCompatibilityMove: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion > 14
            || (version.majorVersion == 14 && version.minorVersion >= 5)
    }
}
