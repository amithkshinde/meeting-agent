import Foundation
import Darwin

/// A one-line picture of how hard the app is working, written to the log while recording,
/// so a slow Mac can be traced to its cause instead of guessed at.
enum Performance {
    private static var previous: (wall: Date, cpu: Double)?

    private static func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "cool"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "very hot"
        @unknown default: return "unknown"
        }
    }

    /// For example "app CPU 135% of one core, memory 1.9 GB, Mac is warm". Call about once a minute.
    static func line(now: Date = Date()) -> String {
        let cpu = cpuSeconds()
        defer { previous = (now, cpu) }
        var share = "app CPU n/a"
        if let previous {
            let wall = now.timeIntervalSince(previous.wall)
            if wall > 1 { share = "app CPU \(Int(((cpu - previous.cpu) / wall * 100).rounded()))% of one core" }
        }
        let memory = footprintMB()
        let size = memory >= 1024 ? String(format: "%.1f GB", memory / 1024) : String(format: "%.0f MB", memory)
        return "\(share), memory \(size), Mac is \(thermal)"
    }
}
