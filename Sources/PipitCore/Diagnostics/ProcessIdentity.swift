#if canImport(Darwin)
    import Darwin
    import Foundation
    import MachO

    /// What the kernel and dyld say about this process, for the launch record.
    ///
    /// Kept apart from the rest of diagnostics, which is plain Foundation and
    /// tested off the Mac. None of these can be faked in a test, so they are
    /// read only here and passed in everywhere else.
    public enum ProcessIdentity {
        /// `kern.bootsessionuuid`, which changes at every boot. Two launch
        /// records with different values were separated by a restart.
        public static func bootSessionUUID() -> String? {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let text = String(decoding: bytes, as: UTF8.self)
            return text.isEmpty ? nil : text
        }

        /// The LC_UUID of the main executable, lowercase: the UUID a crash
        /// report names it by and the one its dSYM must carry. Image 0 is the
        /// executable dyld launched.
        public static func mainBinaryUUID() -> String? {
            guard let header = _dyld_get_image_header(0) else { return nil }
            let start = UnsafeRawPointer(header)
            guard header.pointee.magic == UInt32(MH_MAGIC_64) else { return nil }
            let commandCount = start.loadUnaligned(as: mach_header_64.self).ncmds
            var command = start.advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<commandCount {
                let load = command.loadUnaligned(as: load_command.self)
                if load.cmd == UInt32(LC_UUID) {
                    let uuid = command.loadUnaligned(as: uuid_command.self).uuid
                    return UUID(uuid: uuid).uuidString.lowercased()
                }
                guard load.cmdsize > 0 else { return nil }
                command = command.advanced(by: Int(load.cmdsize))
            }
            return nil
        }

        /// When the process `pid` started, as the kernel recorded it. This is
        /// the time a crash report gives as `procLaunch`.
        public static func startTime(of pid: pid_t = getpid()) -> Date? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let start = info.kp_proc.p_un.__p_starttime
            guard start.tv_sec > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        }
    }
#endif
