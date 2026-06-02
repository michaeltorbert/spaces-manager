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

@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: CGSConnectionID,
                                  _ windowIDs: CFArray,
                                  _ space: CGSSpaceID)

@_silgen_name("SLSSpaceSetCompatID")
func SLSSpaceSetCompatID(_ cid: CGSConnectionID,
                         _ space: CGSSpaceID,
                         _ workspace: Int32) -> CGError

@_silgen_name("SLSSetWindowListWorkspace")
func SLSSetWindowListWorkspace(_ cid: CGSConnectionID,
                               _ windowIDs: UnsafeMutablePointer<UInt32>,
                               _ count: Int32,
                               _ workspace: Int32) -> CGError
