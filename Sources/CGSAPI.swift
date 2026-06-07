import CoreGraphics
import Foundation

// MARK: - Private CoreGraphics Services bindings (read-only; no injection)

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSSpaceDestroy")
func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: CGSConnectionID,
                              _ mask: UInt32,
                              _ windowIDs: CFArray) -> CFArray?

@_silgen_name("SLSSpaceGetType")
func SLSSpaceGetType(_ cid: CGSConnectionID, _ space: CGSSpaceID) -> Int32
