import AppKit

if CommandLine.arguments.contains("--dump") {
    // Prints both values and exits. Token comes from the Keychain, or NOTION_TOKEN_DUMP for ad-hoc runs.
    Task {
        do {
            let deadlines = try await Notion.fetchDeadlines()
            for d in deadlines.sorted(by: { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }) {
                print("deadline\t\(d.label)\t\(d.timeLeft)\t\(d.percent)\t\(d.due.map { "\($0)" } ?? "-")")
            }
            let daily = try await Notion.fetchDaily()
            print("daily\t\(daily.timeLeft)\t\(daily.percent)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
