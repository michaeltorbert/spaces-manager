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

@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
func SLSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID,
                                       _ owner: UInt32,
                                       _ spaces: CFArray,
                                       _ options: UInt32,
                                       _ setTags: UnsafeMutablePointer<UInt64>,
                                       _ clearTags: UnsafeMutablePointer<UInt64>) -> CFArray?

// Returns the owner's WindowServer connection ID (not a PID), via the out param.
@_silgen_name("SLSGetWindowOwner")
func SLSGetWindowOwner(_ cid: CGSConnectionID,
                        _ windowID: UInt32,
                        _ ownerConnection: UnsafeMutablePointer<Int32>) -> Int32

// Resolves a WindowServer connection ID to the owning process's PID.
@_silgen_name("SLSConnectionGetPID")
func SLSConnectionGetPID(_ ownerConnection: Int32,
                          _ pid: UnsafeMutablePointer<pid_t>) -> Int32

@_silgen_name("SLSGetWindowLevel")
func SLSGetWindowLevel(_ cid: CGSConnectionID,
                        _ windowID: UInt32,
                        _ level: UnsafeMutablePointer<Int32>) -> Int32
