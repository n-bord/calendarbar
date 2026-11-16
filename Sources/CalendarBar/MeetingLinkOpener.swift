import AppKit
import SwiftUI
import CalendarCore
import OSLog

@MainActor
enum MeetingLinkOpener {
    private static let logger = Logger(subsystem: CalendarBarIdentity.identifier, category: "Calls")

    static func open(_ url: URL, inBrowser: Bool = false) {
        guard !CalendarBarIdentity.isDemo, MeetingLinks.isUsableMeetingURL(url) else { return }
        let workspace = NSWorkspace.shared
        guard !inBrowser, let deepLink = MeetingLinks.telemostDesktopURL(for: url),
              let application = workspace.urlForApplication(toOpen: deepLink) else {
            openInBrowser(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([deepLink], withApplicationAt: application, configuration: configuration) { _, error in
            Task { @MainActor in
                if error != nil {
                    logger.notice("Desktop handoff failed, opening in browser")
                    openInBrowser(url)
                } else {
                    logger.info("Desktop handoff succeeded")
                }
            }
        }
    }

    private static func openInBrowser(_ url: URL) {
        let success = NSWorkspace.shared.open(MeetingLinks.browserURL(for: url))
        if success { logger.info("Browser handoff succeeded") }
        else { logger.error("Browser handoff failed") }
    }
}

struct JoinMeetingButton: View {
    let url: URL?
    var compact = false
    var symbolOnly = false
    var title: String? = nil
    var body: some View {
        let actionTitle = title ?? (compact ? "Подключиться" : "Подключиться к встрече")
        Button {
            if let url { MeetingLinkOpener.open(url) }
        } label: {
            if symbolOnly { Image(systemName: "video") }
            else { Label(actionTitle, systemImage: "video") }
        }
        .disabled(url == nil)
        .accessibilityLabel(title ?? "Подключиться к встрече")
        .help(url?.absoluteString ?? "В событии нет ссылки на конференцию")
        .contextMenu {
            if let url { Button("Открыть в браузере") { MeetingLinkOpener.open(url, inBrowser: true) } }
        }
    }
}
