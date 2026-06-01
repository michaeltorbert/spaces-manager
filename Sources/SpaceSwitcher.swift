import AppKit
import Foundation

// MARK: - Space switching

enum SpaceSwitchResult {
    case switched
    case alreadyActive
    case needsAccessibility
    case unavailable
}

/// Switches spaces by posting synthetic Dock swipe gestures. The direct
/// `(CGS|SLS)ManagedDisplaySetCurrentSpace` path is intentionally avoided:
/// on Tahoe it only changes WindowServer bookkeeping and can surface the
/// target space windows over the current desktop without moving spaces.
enum SpaceSwitcher {
    private enum Field {
        static let eventType = CGEventField(rawValue: 55)!
        static let gestureHIDType = CGEventField(rawValue: 110)!
        static let gestureScrollY = CGEventField(rawValue: 119)!
        static let gestureSwipeMotion = CGEventField(rawValue: 123)!
        static let gestureSwipeProgress = CGEventField(rawValue: 124)!
        static let gestureSwipeVelocityX = CGEventField(rawValue: 129)!
        static let gestureSwipeVelocityY = CGEventField(rawValue: 130)!
        static let gesturePhase = CGEventField(rawValue: 132)!
        static let scrollGestureFlagBits = CGEventField(rawValue: 135)!
        static let gestureZoomDeltaX = CGEventField(rawValue: 139)!
    }

    private enum EventType {
        static let gesture: Int64 = 29
        static let dockControl: Int64 = 30
    }

    private enum Phase {
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
    }

    private static let hidTypeDockSwipe: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    private static let swipeVelocity = 400.0
    private static let swipeProgress = 2.0
    private static let settlePollInterval: TimeInterval = 0.08
    private static let settleTimeout: TimeInterval = 1.5
    private static let postTransitionDelay: TimeInterval = 0.30
    private static let droppedSwipeRetryDelay: TimeInterval = 0.30
    private static var pendingSwipeWorkItems: [DispatchWorkItem] = []
    private static var swipeSequenceID = 0

    static func switchTo(space target: Space, in snapshot: Snapshot) -> SpaceSwitchResult {
        guard let currentKey = snapshot.currentKeysByDisplay[target.displayID]
            ?? snapshot.activeKey
        else { return .unavailable }
        guard currentKey != target.key else { return .alreadyActive }
        guard AXIsProcessTrusted() else { return .needsAccessibility }

        let displaySpaces = snapshot.spaces.filter { $0.displayID == target.displayID }
        let regularSpaces = displaySpaces.filter { !$0.isFullscreen }
        let currentIndex = displaySpaces.firstIndex(where: { $0.key == currentKey })
        let targetIndex = displaySpaces.firstIndex(where: { $0.key == target.key })
        let regularCurrentIndex = regularSpaces.firstIndex(where: { $0.key == currentKey })
        let regularTargetIndex = regularSpaces.firstIndex(where: { $0.key == target.key })

        let goRight: Bool
        let minimumSteps: Int
        if let currentIndex, let targetIndex {
            let delta = targetIndex - currentIndex
            guard delta != 0 else { return .alreadyActive }
            goRight = delta > 0
            minimumSteps = abs(delta)
        } else if let regularCurrentIndex, let regularTargetIndex {
            let delta = regularTargetIndex - regularCurrentIndex
            guard delta != 0 else { return .alreadyActive }
            goRight = delta > 0
            minimumSteps = abs(delta)
        } else {
            // A Dock swipe operates on the focused display. If macOS does not
            // report a current space for the target display, avoid guessing
            // which display will receive the synthetic gesture.
            return .unavailable
        }

        let maxAttempts = max(minimumSteps + 3, displaySpaces.count + 2)
        postSwipeSequence(
            targetKey: target.key,
            displayID: target.displayID,
            maxAttempts: maxAttempts,
            initialGoRight: goRight)
        return .switched
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func postSwipeSequence(targetKey: String,
                                          displayID: String,
                                          maxAttempts: Int,
                                          initialGoRight: Bool) {
        cancelPendingSwipeSequence()
        swipeSequenceID += 1
        let sequenceID = swipeSequenceID
        advanceSwipeSequence(
            sequenceID: sequenceID,
            targetKey: targetKey,
            displayID: displayID,
            attemptsRemaining: maxAttempts,
            fallbackGoRight: initialGoRight)
    }

    private static func advanceSwipeSequence(sequenceID: Int,
                                             targetKey: String,
                                             displayID: String,
                                             attemptsRemaining: Int,
                                             fallbackGoRight: Bool) {
        guard sequenceID == swipeSequenceID else { return }
        guard attemptsRemaining > 0 else {
            finishSwipeSequence(sequenceID: sequenceID)
            return
        }

        let snapshot = SpacesProvider.snapshot()
        guard let currentKey = snapshot.currentKeysByDisplay[displayID]
            ?? snapshot.activeKey
        else {
            finishSwipeSequence(sequenceID: sequenceID)
            return
        }
        guard currentKey != targetKey else {
            finishSwipeSequence(sequenceID: sequenceID)
            return
        }

        let displaySpaces = snapshot.spaces.filter { $0.displayID == displayID }
        let goRight: Bool
        if let currentIndex = displaySpaces.firstIndex(where: { $0.key == currentKey }),
           let targetIndex = displaySpaces.firstIndex(where: { $0.key == targetKey }),
           currentIndex != targetIndex {
            goRight = targetIndex > currentIndex
        } else {
            goRight = fallbackGoRight
        }

        postSwipeGesture(goRight: goRight)
        waitForSpaceTransition(
            sequenceID: sequenceID,
            previousKey: currentKey,
            targetKey: targetKey,
            displayID: displayID,
            attemptsRemaining: attemptsRemaining - 1,
            fallbackGoRight: goRight,
            startedAt: Date())
    }

    private static func waitForSpaceTransition(sequenceID: Int,
                                               previousKey: String,
                                               targetKey: String,
                                               displayID: String,
                                               attemptsRemaining: Int,
                                               fallbackGoRight: Bool,
                                               startedAt: Date) {
        scheduleSwipeWork(after: settlePollInterval) {
            guard sequenceID == swipeSequenceID else { return }

            let snapshot = SpacesProvider.snapshot()
            let currentKey = snapshot.currentKeysByDisplay[displayID]
                ?? snapshot.activeKey
            if currentKey == targetKey {
                finishSwipeSequence(sequenceID: sequenceID)
                return
            }

            if let currentKey, currentKey != previousKey {
                scheduleSwipeWork(after: postTransitionDelay) {
                    advanceSwipeSequence(
                        sequenceID: sequenceID,
                        targetKey: targetKey,
                        displayID: displayID,
                        attemptsRemaining: attemptsRemaining,
                        fallbackGoRight: fallbackGoRight)
                }
                return
            }

            if Date().timeIntervalSince(startedAt) >= settleTimeout {
                scheduleSwipeWork(after: droppedSwipeRetryDelay) {
                    advanceSwipeSequence(
                        sequenceID: sequenceID,
                        targetKey: targetKey,
                        displayID: displayID,
                        attemptsRemaining: attemptsRemaining,
                        fallbackGoRight: fallbackGoRight)
                }
                return
            }

            waitForSpaceTransition(
                sequenceID: sequenceID,
                previousKey: previousKey,
                targetKey: targetKey,
                displayID: displayID,
                attemptsRemaining: attemptsRemaining,
                fallbackGoRight: fallbackGoRight,
                startedAt: startedAt)
        }
    }

    private static func scheduleSwipeWork(after delay: TimeInterval,
                                          _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        pendingSwipeWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func cancelPendingSwipeSequence() {
        pendingSwipeWorkItems.forEach { $0.cancel() }
        pendingSwipeWorkItems = []
    }

    private static func finishSwipeSequence(sequenceID: Int) {
        guard sequenceID == swipeSequenceID else { return }
        cancelPendingSwipeSequence()
        swipeSequenceID += 1
    }

    private static func postSwipeGesture(goRight: Bool) {
        let flagDirection: Int64 = goRight ? 1 : 0
        let progress = goRight ? swipeProgress : -swipeProgress
        let velocity = goRight ? swipeVelocity : -swipeVelocity

        guard let beginGesture = CGEvent(source: nil),
              let beginDock = CGEvent(source: nil)
        else { return }

        beginGesture.type = CGEventType(rawValue: UInt32(EventType.gesture))!
        beginGesture.setIntegerValueField(Field.eventType, value: EventType.gesture)

        beginDock.type = CGEventType(rawValue: UInt32(EventType.dockControl))!
        beginDock.setIntegerValueField(Field.eventType, value: EventType.dockControl)
        beginDock.setIntegerValueField(Field.gestureHIDType, value: hidTypeDockSwipe)
        beginDock.setIntegerValueField(Field.gesturePhase, value: Phase.began)
        beginDock.setIntegerValueField(Field.scrollGestureFlagBits, value: flagDirection)
        beginDock.setIntegerValueField(Field.gestureSwipeMotion, value: horizontalMotion)
        beginDock.setDoubleValueField(Field.gestureScrollY, value: 0)
        beginDock.setDoubleValueField(Field.gestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        beginDock.post(tap: .cgSessionEventTap)
        beginGesture.post(tap: .cgSessionEventTap)

        guard let changeGesture = CGEvent(source: nil),
              let changeDock = CGEvent(source: nil)
        else { return }

        changeGesture.type = CGEventType(rawValue: UInt32(EventType.gesture))!
        changeGesture.setIntegerValueField(Field.eventType, value: EventType.gesture)

        changeDock.type = CGEventType(rawValue: UInt32(EventType.dockControl))!
        changeDock.setIntegerValueField(Field.eventType, value: EventType.dockControl)
        changeDock.setIntegerValueField(Field.gestureHIDType, value: hidTypeDockSwipe)
        changeDock.setIntegerValueField(Field.gesturePhase, value: Phase.changed)
        changeDock.setDoubleValueField(Field.gestureSwipeProgress, value: progress / 2)
        changeDock.setIntegerValueField(Field.scrollGestureFlagBits, value: flagDirection)
        changeDock.setIntegerValueField(Field.gestureSwipeMotion, value: horizontalMotion)
        changeDock.setDoubleValueField(Field.gestureScrollY, value: 0)
        changeDock.setDoubleValueField(Field.gestureSwipeVelocityX, value: velocity)
        changeDock.setDoubleValueField(Field.gestureSwipeVelocityY, value: 0)
        changeDock.setDoubleValueField(Field.gestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        changeDock.post(tap: .cgSessionEventTap)
        changeGesture.post(tap: .cgSessionEventTap)

        guard let endGesture = CGEvent(source: nil),
              let endDock = CGEvent(source: nil)
        else { return }

        endGesture.type = CGEventType(rawValue: UInt32(EventType.gesture))!
        endGesture.setIntegerValueField(Field.eventType, value: EventType.gesture)

        endDock.type = CGEventType(rawValue: UInt32(EventType.dockControl))!
        endDock.setIntegerValueField(Field.eventType, value: EventType.dockControl)
        endDock.setIntegerValueField(Field.gestureHIDType, value: hidTypeDockSwipe)
        endDock.setIntegerValueField(Field.gesturePhase, value: Phase.ended)
        endDock.setDoubleValueField(Field.gestureSwipeProgress, value: progress)
        endDock.setIntegerValueField(Field.scrollGestureFlagBits, value: flagDirection)
        endDock.setIntegerValueField(Field.gestureSwipeMotion, value: horizontalMotion)
        endDock.setDoubleValueField(Field.gestureScrollY, value: 0)
        endDock.setDoubleValueField(Field.gestureSwipeVelocityX, value: velocity)
        endDock.setDoubleValueField(Field.gestureSwipeVelocityY, value: 0)
        endDock.setDoubleValueField(Field.gestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        endDock.post(tap: .cgSessionEventTap)
        endGesture.post(tap: .cgSessionEventTap)
    }
}
