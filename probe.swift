import Foundation
import RealityKit
import Metal

// Report whether Apple's photogrammetry pipeline will actually run here.
let device = MTLCreateSystemDefaultDevice()
print("Metal device        : \(device?.name ?? "NONE")")
if let d = device {
    print("  low-power         : \(d.isLowPower)")
    print("  removable         : \(d.isRemovable)")
    print("  unified memory    : \(d.hasUnifiedMemory)")
    print("  max buffer length : \(d.maxBufferLength / (1024 * 1024)) MB")
}

let ram = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
print("Physical RAM        : \(ram) GB")

if #available(macOS 12.0, *) {
    print("isSupported         : \(PhotogrammetrySession.isSupported)")
    if !PhotogrammetrySession.isSupported {
        print(">>> VERDICT: runner CANNOT run HelloPhotogrammetry.")
        exit(1)
    }
    print(">>> VERDICT: runner CAN run HelloPhotogrammetry.")
} else {
    print(">>> VERDICT: macOS too old.")
    exit(1)
}
