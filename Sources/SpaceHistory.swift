// MARK: - Space history

struct SpaceHistory {
    private var keys: [String] = []
    private let maxDepth = 50

    mutating func recordTransition(from previousKey: String?,
                                   to activeKey: String?,
                                   validKeys: Set<String>) {
        guard let previousKey, let activeKey,
              previousKey != activeKey,
              validKeys.contains(previousKey)
        else { return }

        keys.removeAll { !validKeys.contains($0) }
        keys.append(previousKey)
        trimToDepth()
    }

    mutating func popPreviousSpace(in snapshot: Snapshot) -> Space? {
        while let key = keys.popLast() {
            guard key != snapshot.activeKey,
                  let space = snapshot.spaces.first(where: { $0.key == key }),
                  !space.displayID.isEmpty,
                  space.id64 != 0
            else { continue }
            return space
        }
        return nil
    }

    mutating func restore(_ key: String) {
        keys.append(key)
        trimToDepth()
    }

    private mutating func trimToDepth() {
        if keys.count > maxDepth {
            keys.removeFirst(keys.count - maxDepth)
        }
    }
}
