import AppKit
import SwiftUI

private enum SoundLibrarySource: String, CaseIterable {
    case all = "All"
    case factory = "Factory"
    case personal = "My Sounds"
}

/// A persistent audition browser: loading a patch deliberately keeps it open.
struct SoundLibraryBrowser: View {
    @EnvironmentObject private var model: SynthModel
    @State private var search = ""
    @State private var source = SoundLibrarySource.all
    @FocusState private var searchFocused: Bool

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPatches: [Patch] {
        model.patches.filter { patch in
            let matchesSource = source == .all
                || (source == .factory && patch.isFactory)
                || (source == .personal && !patch.isFactory)
            let matchesSearch = query.isEmpty
                || patch.name.localizedStandardContains(query)
                || patch.category.localizedStandardContains(query)
            return matchesSource && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            if filteredPatches.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(filteredPatches) { patch in
                            soundRow(patch)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .frame(width: 380, height: 496)
        .background(Palette.panel)
        .foregroundStyle(Palette.ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sound library")
                    .font(.system(size: 21, weight: .medium, design: .serif))
                Spacer()
                Text("\(filteredPatches.count) \(filteredPatches.count == 1 ? "sound" : "sounds")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("soundLibraryCount")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                TextField("Search sounds or categories", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredPatches.first { load(first) }
                    }
                    .accessibilityLabel("Search sounds or categories")
                    .accessibilityIdentifier("soundLibrarySearch")
                if !search.isEmpty {
                    Button {
                        search = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear sound search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 33)
            .background(Palette.cream.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(searchFocused ? Palette.orange.opacity(0.8) : Palette.line, lineWidth: 1))
            HStack(spacing: 4) {
                ForEach(SoundLibrarySource.allCases, id: \.self) { option in
                    Button {
                        source = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(source == option ? Palette.panel : Palette.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 27)
                            .background(source == option ? Palette.ink : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.rawValue) sounds")
                    .accessibilityAddTraits(source == option ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Palette.cream.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 18)
        .padding(.top, 17)
        .padding(.bottom, 14)
    }

    private func soundRow(_ patch: Patch) -> some View {
        let selected = model.selectedID == patch.id
        return Button {
            load(patch)
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(selected ? Palette.orange : Palette.line.opacity(0.65))
                    .frame(width: 3, height: 29)
                VStack(alignment: .leading, spacing: 4) {
                    Text(patch.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(patch.category.isEmpty ? (patch.isFactory ? "Factory sound" : "My sound") : patch.category)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.orange)
                } else if !patch.isFactory {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 49)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.orange.opacity(0.09) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(SoundLibraryRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(patch.name), \(patch.category), \(patch.isFactory ? "factory sound" : "my sound")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("soundLibraryRow-\(patch.id.uuidString)")
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: query.isEmpty ? "square.stack" : "magnifyingglass")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Palette.secondary.opacity(0.7))
            Text(query.isEmpty && source == .personal ? "No saved sounds yet" : "No matching sounds")
                .font(.system(size: 14, weight: .medium))
            Text(query.isEmpty && source == .personal
                 ? "Save a sound you create and find it here."
                 : "Try another name, category, or source.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Button("Show all sounds") {
                search = ""
                source = .all
                releaseSearchFocus()
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Palette.orange)
            .padding(.top, 4)
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "pianokeys").font(.system(size: 12))
            Text("Select a sound, then play to compare.")
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, 18)
        .frame(height: 35)
        .background(Palette.cream.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func load(_ patch: Patch) {
        model.select(patch)
        releaseSearchFocus()
    }

    private func releaseSearchFocus() {
        searchFocused = false
        // A popover has its own window. Resign its field editor explicitly so
        // the app's local keyboard monitor can immediately play notes again.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct SoundLibraryRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.ink.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.04 : 0)),
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}
