import Foundation
#if canImport(AppKit)
import AppKit
import CoreGraphics
#endif

/// Harvest front browser tab title + URL (best-effort, never throws).
///
/// Strategy:
/// 1. CGWindowList window name (no TCC for title alone)
/// 2. AppleScript for Safari / Chrome / Brave / Edge URL (may prompt Automation)
///
/// Failures degrade to empty context so Cmd+D still maps by app bundle.
public enum BrowserPageProbe {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.safari",
        "com.google.chrome",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "company.thebrowser.browser", // Arc
        "org.mozilla.firefox",
        "com.operasoftware.opera",
        "company.thebrowser.dia",
    ]

    public static func isBrowser(bundleID: String?) -> Bool {
        guard let bid = bundleID?.lowercased() else { return false }
        if browserBundleIDs.contains(bid) { return true }
        // Chromium forks often share prefixes
        if bid.contains("chrome") || bid.contains("chromium") || bid.contains("brave") {
            return true
        }
        return false
    }

    /// Probe the given app (or last non-Shannon frontmost).
    public static func probe(bundleID: String?, appName: String?) -> BrowserPageContext {
        #if canImport(AppKit)
        let bid = (bundleID ?? "").lowercased()
        var title = windowTitle(forBundleID: bid)
        var url = ""

        if bid.contains("safari") || (appName ?? "").lowercased().contains("safari") {
            if let page = appleScriptSafari() {
                if !page.title.isEmpty { title = page.title }
                url = page.url
            }
        } else if bid.contains("chrome") || bid.contains("brave") || bid.contains("edgemac")
                    || bid.contains("chromium")
                    || (appName ?? "").lowercased().contains("chrome")
                    || (appName ?? "").lowercased().contains("brave")
                    || (appName ?? "").lowercased().contains("edge") {
            let app = chromeLikeAppName(bundleID: bid, appName: appName)
            if let page = appleScriptChromeFamily(appName: app) {
                if !page.title.isEmpty { title = page.title }
                url = page.url
            }
        } else if bid.contains("thebrowser") || (appName ?? "").lowercased().contains("arc") {
            // Arc is Chromium; AppleScript dictionary is flaky — title only.
            if title.isEmpty { title = windowTitle(forBundleID: bid) }
        }

        return BrowserPageContext(title: title, url: url)
        #else
        return BrowserPageContext()
        #endif
    }

    #if canImport(AppKit)
    private static func chromeLikeAppName(bundleID: String, appName: String?) -> String {
        if bundleID.contains("brave") { return "Brave Browser" }
        if bundleID.contains("edgemac") { return "Microsoft Edge" }
        if let appName, !appName.isEmpty { return appName }
        return "Google Chrome"
    }

    private static func windowTitle(forBundleID bid: String) -> String {
        guard !bid.isEmpty else { return "" }
        let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return ""
        }
        // Prefer the frontmost layer-0 window owned by this bundle's PID set.
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        let pids = Set(apps.map(\.processIdentifier))
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else {
                continue
            }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
        }
        return ""
    }

    private static func appleScriptSafari() -> BrowserPageContext? {
        let src = """
        tell application "Safari"
          if (count of windows) is 0 then return "\\t"
          set t to name of current tab of front window
          set u to URL of current tab of front window
          return t & "\\t" & u
        end tell
        """
        return runAppleScript(src)
    }

    private static func appleScriptChromeFamily(appName: String) -> BrowserPageContext? {
        // Escape quotes in app name
        let app = appName.replacingOccurrences(of: "\"", with: "")
        let src = """
        tell application "\(app)"
          if (count of windows) is 0 then return "\\t"
          set t to title of active tab of front window
          set u to URL of active tab of front window
          return t & "\\t" & u
        end tell
        """
        return runAppleScript(src)
    }

    private static func runAppleScript(_ source: String) -> BrowserPageContext? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let raw = result.stringValue ?? ""
        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.count > 0 ? String(parts[0]) : ""
        let url = parts.count > 1 ? String(parts[1]) : ""
        return BrowserPageContext(title: title, url: url)
    }
    #endif
}
