import AppKit

// MARK: - Frontmost window relocation

enum SpaceWindowMoveResult {
    case moved
    case alreadyThere
    case noFrontmostApp
    case noWindow
    case unsupportedSpace
}

enum SpaceWindowMover {
    private static let allSpacesMask: UInt32 = 0x7
    private static let userSpaceType: Int32 = 0
    private static let compatWorkspaceID: Int32 = 0x79616265
    private static let minimumWindowDimension: CGFloat = 40

    static func moveFrontmostWindow(to space: Space) -> SpaceWindowMoveResult {
        guard !space.isFullscreen, space.id64 != 0 else {
            return .unsupportedSpace
        }

        let cid = CGSMainConnectionID()
        guard SLSSpaceGetType(cid, space.id64) == userSpaceType else {
            return .unsupportedSpace
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != getpid()
        else {
            return .noFrontmostApp
        }

        guard let windowID = frontmostWindowID(for: app.processIdentifier) else {
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
        return .moved
    }

    private static func frontmostWindowID(for pid: pid_t) -> UInt32? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var seenWindowIDs = Set<UInt32>()
        for info in windowInfo {
            guard let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  seenWindowIDs.insert(windowID).inserted,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  isSubstantialWindow(info)
            else { continue }

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

    private static var usesWorkspaceCompatibilityMove: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion > 14
            || (version.majorVersion == 14 && version.minorVersion >= 5)
    }
}
