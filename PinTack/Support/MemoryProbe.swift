#if DEBUG
import AppKit
import Darwin

/// Memory at scale (SPEC.md §17): how much a desk of open notes costs, measured, not guessed.
/// Debug builds only, and only against a throwaway vault:
///
///     PINTACK_VAULT=/tmp/x PINTACK_MEMPROBE=50 build/Debug/PinTack.app/Contents/MacOS/PinTack
///
/// or `scripts/measure-memory.sh 50`. It opens the notes in steps, lets each step settle, and reports
/// the resident memory and footprint of PinTack plus the WebKit helper processes it caused: every
/// WebKit process that did not exist before PinTack opened its first page (WebContent for the note
/// pages, plus GPU and Networking). The WebContent count is cross-checked against the process each
/// note's page reports for itself. A measurement, not a check: it never fails, it just reports.
enum MemoryProbe {

    static var requested: Int? {
        guard let raw = ProcessInfo.processInfo.environment["PINTACK_MEMPROBE"] else { return nil }
        return Int(raw).map { max(1, $0) } ?? 50
    }

    static func runIfRequested() {
        guard let n = requested else { return }
        // Never against the real vault: this creates notes by the dozen.
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("MEMPROBE refused: set PINTACK_VAULT to a throwaway folder")
            exit(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()
        // Notes created on top of the welcome note the fresh vault opens with.
        let steps = Array(Set([0, min(10, n), min(25, n), n])).sorted()
        var lines = ["PinTack memory probe, \(n) notes, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "notes  webcontent  (pages say)  pintack-rss  webkit-rss  total-rss  |  pintack-fp  webkit-fp  total-fp   (MB)"]
        var opened = 0
        func step(_ rest: [Int]) {
            guard let target = rest.first else {
                let report = lines.joined(separator: "\n")
                print(report)
                if let out = ProcessInfo.processInfo.environment["PINTACK_MEMPROBE_OUT"] {
                    try? report.write(toFile: out, atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
                return
            }
            while opened < target {
                let x = 40 + CGFloat(opened % 10) * 70, y = 80 + CGFloat(opened / 10) * 60
                let note = VaultStore.shared.createNote(body: sample(opened),
                                                        frame: NSRect(x: x, y: y, width: 300, height: 250))
                WindowManager.shared.open(note)
                opened += 1
            }
            // Long enough for every page to load its editor and settle; measured twice, the second kept.
            let settle: TimeInterval = target == 0 ? 3 : 6 + Double(target) * 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                _ = measure()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    lines.append(measure().line(notes: WindowManager.shared.openPanels.count))
                    step(Array(rest.dropFirst()))
                }
            }
        }
        step(steps)
    }

    /// A realistic short note: a heading, a checklist, a code block (so a language parser loads).
    private static func sample(_ i: Int) -> String {
        "Note \(i + 1)\n\n- [ ] check the pool\n- [x] drain web0\(i % 9)\n\n```bash\nssh web0\(i % 9) uptime\n```\n"
    }

    struct Sample {
        var webContent = 0, pagesSay = 0
        var appRSS = 0.0, webRSS = 0.0, appFootprint = 0.0, webFootprint = 0.0
        func line(notes: Int) -> String {
            func mb(_ v: Double) -> String { String(format: "%10.0f", v / 1_048_576) }
            return String(format: "%5d  %10d  %11d", notes, webContent, pagesSay)
                + "  " + mb(appRSS) + "  " + mb(webRSS) + " " + mb(appRSS + webRSS)
                + "  |" + mb(appFootprint) + " " + mb(webFootprint) + " " + mb(appFootprint + webFootprint)
        }
    }

    private static var baseline = Set<pid_t>()

    /// Called at launch before any note opens: every WebKit process already running then belongs to
    /// someone else. (The throwaway vault's welcome note opens next, and is counted.)
    static func recordBaseline() {
        guard requested != nil else { return }
        baseline = Set(webKitPIDs().map(\.pid))
    }

    static func measure() -> Sample {
        var s = Sample()
        let (rss, fp) = usage(of: getpid())
        s.appRSS = rss; s.appFootprint = fp
        for (pid, name) in webKitPIDs() where !baseline.contains(pid) {
            let (r, f) = usage(of: pid)
            s.webRSS += r; s.webFootprint += f
            if name.contains("WebContent") { s.webContent += 1 }
        }
        // What each page says its own process is: a private WebKit property, Debug only.
        let pages = WindowManager.shared.openPanels.compactMap {
            ($0.card.editor.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        }
        s.pagesSay = Set(pages.filter { $0 > 0 }).count
        return s
    }

    private static func webKitPIDs() -> [(pid: pid_t, name: String)] {
        allPIDs().compactMap { pid in
            let name = processName(pid)
            return name.hasPrefix("com.apple.WebKit") ? (pid, name) : nil
        }
    }

    private static func usage(of pid: pid_t) -> (rss: Double, footprint: Double) {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return (0, 0) }
        return (Double(info.ri_resident_size), Double(info.ri_phys_footprint))
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, got)))).filter { $0 > 0 }
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return (String(cString: buffer) as NSString).lastPathComponent
    }
}
#endif
