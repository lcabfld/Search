import SwiftUI

/// The address, always in sight at the top of the column: a soft rounded
/// bar under the traffic lights and the three doors, above the pins, with
/// the site's name in it and nothing else. A click makes the bar itself the
/// field, the whole address selected and the list of places under it as
/// you type (the same field a tab's own row edits in); under the pointer, a
/// link button at its far end copies the address and a bolt starts Zap
/// (Zap.swift) — a bolt that stays, filled in, while Zap is on.
struct AddressPill: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Bar(browser: browser, tab: tab)
        } else {
            Bar.shape(hovering: false, greys: .white) {
                Bar.placeholder
            }
        }
    }

    static let height: CGFloat = 34

    private struct Bar: View {
        @ObservedObject var browser: Browser
        @ObservedObject var tab: Tab
        @Environment(\.greys) private var greys
        @State private var hovering = false
        @State private var copied = false

        private var typing: Bool { browser.inBar && browser.editingTab == tab.id }

        var body: some View {
            Bar.shape(hovering: hovering || typing, greys: greys) {
                HStack(spacing: 6) {
                    if typing {
                        TabAddressField(browser: browser)
                            .frame(height: 18)
                    } else if let host = Bar.host(of: tab.shownURL) {
                        Text(host)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Bar.placeholder
                    }
                    Spacer(minLength: 0)
                    if !typing, tab.isWeb, hovering || browser.veiling {
                        Button { browser.toggleHiding() } label: {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(browser.veiling ? Palette.ground : Palette.muted)
                                .frame(width: 22, height: 22)
                                .background {
                                    if browser.veiling { Circle().fill(Palette.ink) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(browser.veiling ? "Stop Zapping" : "Zap Elements on This Page")
                        .transition(.opacity)
                    }
                    if hovering, !typing, !tab.isBlank {
                        Button {
                            browser.copyAddress()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "link")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy Link")
                        .transition(.opacity)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !typing { browser.beginBarEdit() } }
            .onHover { over in
                withAnimation(Motion.quick) { hovering = over }
            }
            .help(tab.shownURL?.absoluteString ?? "")
        }

        static var placeholder: some View {
            Text("Search or enter address")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }

        static func shape<Content: View>(hovering: Bool, greys: Greys, @ViewBuilder _ content: () -> Content) -> some View {
            content()
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: AddressPill.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hovering ? greys.wash : greys.tile)
                )
        }

        /// The site, as a person would say it: the host without "www.".
        /// Search's own pages and files say what they are instead.
        static func host(of url: URL?) -> String? {
            guard let url else { return nil }
            if url.isFileURL { return url.lastPathComponent }
            guard var host = url.host(), !host.isEmpty else {
                return url.scheme == InternalPage.scheme ? "Search" : nil
            }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
    }
}
