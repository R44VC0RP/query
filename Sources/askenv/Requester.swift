import Darwin
import Foundation

private func processName(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
}

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let parent = info.kp_eproc.e_ppid
    return parent > 1 ? parent : nil
}

/// Name of the first ancestor that is not a shell or wrapper, such as `opencode` or `claude`.
func requesterName() -> String {
    let wrappers: Set<String> = [
        "sh", "zsh", "bash", "fish", "dash", "nu", "env", "sudo", "login",
        "timeout", "gtimeout", "xargs", "nohup", "script", "tmux", "screen",
    ]
    var pid = getppid()
    for _ in 0..<10 {
        guard let name = processName(pid) else { break }
        if !wrappers.contains(name) { return name }
        guard let parent = parentPID(of: pid) else { break }
        pid = parent
    }
    return "An agent"
}

func abbreviatedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
