import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps Perch treats specially, one row each: ignore the app entirely, or
/// move its perch button, or show the button only once a window is perched.
/// Built-in rows (`BadgeOffsets.builtIn`) appear like any other.
struct BadgeOffsetSettings: View {

    /// Copies of what is stored, so the rows redraw as it changes.
    @State private var offsets = BadgeOffsets.all()
    @State private var onlyWhenPinned = BadgeOffsets.onlyWhenPinned()
    @State private var ignored = BadgeOffsets.ignored()

    var body: some View {
        Section("Apps") {
            LabeledContent {
                addMenu
            } label: {
                Text("Change how Perch treats an app")
            }
            ForEach(Self.byName(offsets.keys), id: \.self) { id in
                row(id)
            }
        }
    }

    private func row(_ id: String) -> some View {
        let app = Self.app(id)
        let isIgnored = ignored.contains(id)
        let distance = Binding<Double>(
            get: { offsets[id] ?? BadgeOffsets.range.lowerBound },
            set: { value in
                let kept = BadgeOffsets.validated(value)
                offsets[id] = kept
                BadgeOffsets.set(kept, for: id)
            })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon)
                    .frame(width: 16, height: 16)
                Text(app.name).fontWeight(.medium)
                Spacer()
                Button {
                    BadgeOffsets.remove(id)
                    reload()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Forget this app's settings")
                .accessibilityLabel("Remove \(app.name)")
            }
            // Indented under the name, past the icon, as settings of this app.
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { isIgnored },
                    set: { BadgeOffsets.setIgnored($0, for: id); reload() }
                )) {
                    Text("Ignore this app")
                }
                Group {
                    HStack(spacing: 8) {
                        Text("Button position")
                        // Whole points. Not a step on the slider, which would
                        // draw a tick mark for every one.
                        Slider(value: distance, in: BadgeOffsets.range)
                            .frame(minWidth: 120)
                        // Typed, for the same distance in several apps. Both
                        // controls share one binding, so they always agree.
                        TextField("", value: distance, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                            .accessibilityLabel("\(app.name) button position, points from the right edge")
                        Text("pt")
                            .foregroundStyle(.secondary)
                    }
                    .help("Distance of the perch button from the window's right edge")
                    Toggle(isOn: Binding(
                        get: { onlyWhenPinned.contains(id) },
                        set: { BadgeOffsets.setOnlyWhenPinned($0, for: id); reload() }
                    )) {
                        Text("Show the button only when window is perched")
                    }
                }
                .disabled(isIgnored)
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        offsets = BadgeOffsets.all()
        onlyWhenPinned = BadgeOffsets.onlyWhenPinned()
        ignored = BadgeOffsets.ignored()
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
                    BadgeOffsets.set(BadgeOffsets.starting(for: id, automatic: BadgeOffsets.lastAutomatic[id]), for: id)
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
