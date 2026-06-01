import Foundation

// MARK: - Space model

struct Space {
    let key: String          // uuid if non-empty, else "<displayID>:desktop:<regularIndex>"
    let uuid: String         // raw, may be empty
    let id64: CGSSpaceID     // CGS internal
    let managedID: Int       // ManagedSpaceID from plist; -1 if missing
    let displayID: String
    let regularIndex: Int    // 1-based within display, 0 for fullscreen tiles
    let isFullscreen: Bool

    var defaultName: String {
        isFullscreen ? "Full Screen" : "Desktop \(regularIndex)"
    }
}

struct Snapshot {
    let spaces: [Space]
    let activeKey: String?
    let currentKeysByDisplay: [String: String]
    let displayNamesByID: [String: String]
}


// MARK: - Snapshot provider

enum SpacesProvider {
    static func snapshot() -> Snapshot {
        let cid = CGSMainConnectionID()
        let displays = (CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]]) ?? plistFallback()
        let activeID = CGSGetActiveSpace(cid)

        var spaces: [Space] = []
        var displayIDs: [String] = []
        var activeByID64: String?
        var activeByPlistCurrent: String?
        var currentKeysByDisplay: [String: String] = [:]

        for display in displays {
            let displayID = (display["Display Identifier"] as? String) ?? ""
            guard let list = display["Spaces"] as? [[String: Any]] else { continue }
            if !displayIDs.contains(displayID) {
                displayIDs.append(displayID)
            }

            let currentInfo = display["Current Space"] as? [String: Any]
            let currentManaged = (currentInfo?["ManagedSpaceID"] as? NSNumber)?.intValue
            let currentUUID = currentInfo?["uuid"] as? String

            var regular = 0
            for sp in list {
                let fullscreen = (sp["TileLayoutManager"] != nil)
                    || ((sp["type"] as? NSNumber)?.intValue == 4)
                if !fullscreen { regular += 1 }

                let uuid = (sp["uuid"] as? String) ?? ""
                let id64 = (sp["id64"] as? NSNumber)?.uint64Value ?? 0
                let managed = (sp["ManagedSpaceID"] as? NSNumber)?.intValue ?? -1
                let fallbackKey: String
                if fullscreen {
                    let stableID = managed >= 0
                        ? String(managed)
                        : (id64 != 0 ? String(id64) : String(spaces.count))
                    fallbackKey = "\(displayID):fullscreen:\(stableID)"
                } else {
                    fallbackKey = "\(displayID):desktop:\(regular)"
                }
                let key = !uuid.isEmpty ? uuid : fallbackKey

                let space = Space(
                    key: key, uuid: uuid, id64: id64, managedID: managed,
                    displayID: displayID,
                    regularIndex: fullscreen ? 0 : regular,
                    isFullscreen: fullscreen
                )
                spaces.append(space)

                if activeByID64 == nil, id64 != 0, id64 == activeID {
                    activeByID64 = key
                }
                if id64 != 0, id64 == activeID {
                    currentKeysByDisplay[displayID] = key
                }
                let plistHit = (currentManaged.map { $0 == managed } ?? false)
                    || (currentUUID.map { !$0.isEmpty && $0 == uuid } ?? false)
                if activeByPlistCurrent == nil, plistHit {
                    activeByPlistCurrent = key
                }
                if plistHit {
                    currentKeysByDisplay[displayID] = key
                }
            }
        }
        return Snapshot(
            spaces: spaces,
            activeKey: activeByID64 ?? activeByPlistCurrent,
            currentKeysByDisplay: currentKeysByDisplay,
            displayNamesByID: DisplayNameResolver.names(for: displayIDs))
    }

    private static func plistFallback() -> [[String: Any]] {
        let path = ("~/Library/Preferences/com.apple.spaces.plist" as NSString)
            .expandingTildeInPath
        guard let root = NSDictionary(contentsOfFile: path),
              let monitors = root.value(forKeyPath:
                "SpacesDisplayConfiguration.Management Data.Monitors") as? [[String: Any]]
        else { return [] }
        return monitors
    }
}
