import SwiftUI

/// What floats at the foot of the page while Zap is on: what mode this is,
/// how many things are gone from the site, and the two ways out of a
/// mistake — Undo, and Done.
struct ZapBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var curtain = Shared.curtain

    private var count: Int { curtain.veils(on: browser.hereHost).count }
    /// Remove All pressed once: pressed again in the next few seconds, every
    /// zap on the site goes. Once is too easy to do by mistake for something
    /// Undo can't bring back.
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(white: 0.09))
                    .frame(width: 22, height: 22)
                    .background(Color.white, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Zap")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(count == 0 ? "Click anything to choose it" : (count == 1 ? "1 zap on this site" : "\(count) zaps on this site"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.numericText())
                        .animation(Motion.quick, value: count)
                }
            }
            .padding(.trailing, 6)

            Text("↑ ↓ bigger or smaller")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))

            button("Undo", icon: "arrow.uturn.backward", filled: false) { browser.undoHiding() }
                .disabled(count == 0)
                .opacity(count == 0 ? 0.4 : 1)
            button(confirming ? "Remove all \(count)?" : "Remove All", icon: confirming ? nil : "trash", filled: false,
                   tint: confirming ? Color(red: 1, green: 0.27, blue: 0.23) : nil) {
                if confirming {
                    confirming = false
                    browser.restoreAll()
                } else {
                    withAnimation(Motion.quick) { confirming = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation(Motion.quick) { confirming = false }
                    }
                }
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
            .help("Bring back everything zapped on this site")
            button("Done", icon: nil, filled: true) { browser.toggleHiding() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(Color(white: 0.09).opacity(0.94))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private func button(_ title: String, icon: String?, filled: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(filled ? Color(white: 0.09) : .white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(filled ? AnyShapeStyle(Color.white) : (tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color.white.opacity(0.12))), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

