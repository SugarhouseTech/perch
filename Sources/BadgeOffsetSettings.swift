import AppKit
import SwiftUI

/// The apps whose pin button sits at a distance of their own: see
/// `BadgeOffsets`. A row per app with a slider, and a menu of the running
/// apps to add one.
struct BadgeOffsetSettings: View {

    /// A copy of what is stored, so the rows redraw as it changes.
    @State private var offsets = BadgeOffsets.all()
    @State private var onlyWhenPinned = BadgeOffsets.onlyWhenPinned()

    var body: some View {
        Section("Pin Button Position") {
            LabeledContent {
                addMenu
            } label: {
                Text("Position by app")
                Text("The pin button moves left of any buttons it finds at the right of a title bar. Where it lands in the wrong place, add the app and set the button's distance from the window's right edge. Or show it only on the app's pinned windows, where it says a window is pinned. A change shows the next time you switch to the app.")
            }
            ForEach(Self.byName(offsets.keys), id: \.self) { id in
                row(id)
            }
        }
    }

    private func row(_ id: String) -> some View {
        let app = Self.app(id)
        return LabeledContent {
            HStack {
                Slider(value: Binding(
                    get: { offsets[id] ?? BadgeOffsets.range.lowerBound },
                    // Whole points. Not a step on the slider, which draws a
                    // tick mark for every one.
                    set: { value in
                        offsets[id] = value.rounded()
                        BadgeOffsets.set(value.rounded(), for: id)
                    }
                ), in: BadgeOffsets.range)
                .frame(minWidth: 140)
                Text("\(Int(offsets[id] ?? 0)) pt")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                Button {
                    BadgeOffsets.remove(id)
                    offsets = BadgeOffsets.all()
                    onlyWhenPinned = BadgeOffsets.onlyWhenPinned()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Place the button automatically again, on every window")
                .accessibilityLabel("Remove \(app.name)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(app.name)
                } icon: {
                    Image(nsImage: app.icon)
                }
                // The distance still counts with this on: a pinned window
                // shows its button there.
                // The box before its words, as a checkbox is everywhere else:
                // a form lays a toggle's own label out first.
                HStack(spacing: 6) {
                    Toggle("Only when pinned", isOn: Binding(
                        get: { onlyWhenPinned.contains(id) },
                        set: { on in
                            BadgeOffsets.setOnlyWhenPinned(on, for: id)
                            onlyWhenPinned = BadgeOffsets.onlyWhenPinned()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Text("Only when pinned")
                }
                .help("Show the button only on this app's pinned windows, to say they are pinned")
            }
        }
    }

    private var addMenu: some View {
        Menu("Add an App") {
            let candidates = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    && $0.bundleIdentifier.map { offsets[$0] == nil } == true
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
            if candidates.isEmpty {
                Text("No other apps are running")
            }
            ForEach(candidates, id: \.processIdentifier) { running in
                Button {
                    guard let id = running.bundleIdentifier else { return }
                    BadgeOffsets.set(BadgeOffsets.starting(for: id), for: id)
                    offsets = BadgeOffsets.all()
                } label: {
                    Label {
                        Text(running.localizedName ?? running.bundleIdentifier ?? "")
                    } icon: {
                        Image(nsImage: Self.small(running.icon))
                    }
                }
            }
        }
        .fixedSize()
    }

    // MARK: - Apps

    private struct App {
        let name: String
        let icon: NSImage
    }

    /// Looked up once each: the rows redraw on every step of a slider.
    private static var apps: [String: App] = [:]

    /// An app's name and icon, whether it is running or not.
    private static func app(_ id: String) -> App {
        if let known = apps[id] { return known }
        let found = lookUp(id)
        apps[id] = found
        return found
    }

    private static func lookUp(_ id: String) -> App {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return App(name: running.localizedName ?? id, icon: small(running.icon))
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            return App(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                       icon: small(NSWorkspace.shared.icon(forFile: url.path)))
        }
        return App(name: id, icon: small(nil))
    }

    private static func small(_ icon: NSImage?) -> NSImage {
        let image = (icon ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func byName(_ ids: Dictionary<String, Double>.Keys) -> [String] {
        ids.sorted { app($0).name.localizedStandardCompare(app($1).name) == .orderedAscending }
    }
}
