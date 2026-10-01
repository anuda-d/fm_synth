import SwiftUI
import AppKit

enum Palette {
    static let cream = Color(hex: 0xECE6D6)
    static let panel = Color(hex: 0xF6F1E6)
    static let ink = Color(hex: 0x353B36)
    static let secondary = Color(hex: 0x75766B)
    static let line = Color(hex: 0xCCC7B7)
    static let orange = Color(hex: 0xB65D32)
    static let amber = Color(hex: 0xD8AB65)
    static let screen = Color(hex: 0x283C36)
    static let screenText = Color(hex: 0xD9DEC1)
    static let wood = Color(hex: 0x775039)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

extension View {
    @ViewBuilder func hint(_ text: String, enabled: Bool) -> some View {
        if enabled { self.help(text) } else { self }
    }
    func etchedPanel() -> some View {
        self.padding(16)
            .background(Palette.panel.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
    }
}

struct InstrumentButtonStyle: ButtonStyle {
    var accent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(accent ? Palette.panel : Palette.ink)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(accent ? Palette.orange : Palette.panel, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent ? Palette.orange.opacity(0.7) : Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.09), radius: 0, x: 0, y: 2)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

struct Knob: View {
    let title: String
    let parameter: Parameter
    @Binding var value: Double
    var diameter: CGFloat = 56
    var hints = true
    @State private var startValue: Double?
    @State private var lastTranslation: CGFloat = 0
    @State private var editing = false
    @State private var entry = ""
    @FocusState private var focused: Bool

    private var normalized: Double {
        if parameter.isLogarithmic {
            return log(value / parameter.range.lowerBound) / log(parameter.range.upperBound / parameter.range.lowerBound)
        }
        return (value - parameter.range.lowerBound) / (parameter.range.upperBound - parameter.range.lowerBound)
    }
    private func setNormalized(_ proposed: Double) {
        let n = min(1, max(0, proposed))
        if parameter.isLogarithmic { value = parameter.range.lowerBound * pow(parameter.range.upperBound / parameter.range.lowerBound, n) }
        else { value = parameter.range.lowerBound + n * (parameter.range.upperBound - parameter.range.lowerBound) }
    }
    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Palette.secondary)
            ZStack {
                ArcTrack(progress: 1).stroke(Palette.line, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ArcTrack(progress: normalized).stroke(Palette.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle().fill(.black.opacity(0.15)).padding(7).offset(y: 3).blur(radius: 1.5)
                Circle().fill(LinearGradient(colors: [Color(hex: 0x55594F), Color(hex: 0x252D29)], startPoint: .topLeading, endPoint: .bottomTrailing)).padding(7)
                Circle().stroke(.white.opacity(0.16), lineWidth: 1).padding(8)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.panel)
                    .frame(width: 2.5, height: diameter * 0.21)
                    .offset(y: -diameter * 0.20)
                    .rotationEffect(.degrees(-135 + normalized * 270))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                if startValue == nil { startValue = normalized; lastTranslation = 0 }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.15 : 1.0
                let delta = event.translation.height - lastTranslation
                if delta != 0 { setNormalized(normalized - delta / 150 * fine) }
                lastTranslation = event.translation.height
            }.onEnded { _ in startValue = nil })
            .onTapGesture(count: 2) { value = parameter.defaultValue }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(Circle().stroke(focused ? Palette.orange.opacity(0.65) : .clear, lineWidth: 1))
            .onKeyPress(.upArrow) { setNormalized(normalized + 0.01); return .handled }
            .onKeyPress(.downArrow) { setNormalized(normalized - 0.01); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parameter.accessibilityName)
            .accessibilityValue(parameter.display(value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setNormalized(normalized + 0.025)
                case .decrement: setNormalized(normalized - 0.025)
                @unknown default: break
                }
            }
            Button {
                entry = String(format: "%.3f", value)
                editing = true
            } label: {
                Text(parameter.display(value))
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Palette.ink).frame(minWidth: 50)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(parameter.accessibilityName) value")
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(parameter.isLogarithmic && parameter != .chorusRate && parameter != .phaserRate ? "Enter seconds" : "Range: \(parameter.range.lowerBound.formatted()) to \(parameter.range.upperBound.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Value", text: $entry).textFieldStyle(.roundedBorder).onSubmit { commitEntry() }
                    HStack {
                        Button("Reset") { value = parameter.defaultValue; editing = false }
                        Spacer()
                        Button("Apply") { commitEntry() }.keyboardShortcut(.defaultAction)
                    }
                }.padding(18).frame(width: 210)
            }
        }
        .frame(minWidth: diameter + 8)
        .hint(parameter.explanation + " Drag vertically; hold Shift for precision. Click the value to type it, or double-click the knob to reset.", enabled: hints)
    }
    private func commitEntry() {
        if let proposed = Double(entry), proposed.isFinite {
            value = min(parameter.range.upperBound, max(parameter.range.lowerBound, proposed))
            editing = false
        }
    }
}

struct ArcTrack: Shape {
    var progress: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - 2,
                    startAngle: .degrees(135), endAngle: .degrees(135 + 270 * min(1, max(0, progress))), clockwise: false)
        return path
    }
}

struct EnvelopeDisplay: View {
    let attack: Double
    let decay: Double
    let sustain: Double
    let release: Double
    var color = Palette.orange
    var body: some View {
        Canvas { context, size in
            let baseline = size.height - 7
            let top: CGFloat = 6
            let total = sqrt(attack) + sqrt(decay) + sqrt(release) + 1.2
            let width = size.width - 10
            let a = CGFloat(sqrt(attack) / total) * width + 5
            let d = a + CGFloat(sqrt(decay) / total) * width
            let s = d + CGFloat(1.2 / total) * width
            let level = baseline - CGFloat(sustain) * (baseline - top)
            var grid = Path()
            for fraction in [0.0, 0.5, 1.0] {
                let y = top + CGFloat(fraction) * (baseline - top)
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(Palette.line.opacity(0.55)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            var path = Path()
            path.move(to: CGPoint(x: 5, y: baseline))
            path.addLine(to: CGPoint(x: a, y: top))
            for step in 1...30 {
                let t = Double(step) / 30
                let amplitude = sustain + (1 - sustain) * pow(0.001, t)
                path.addLine(to: CGPoint(x: a + (d - a) * t, y: baseline - amplitude * (baseline - top)))
            }
            path.addLine(to: CGPoint(x: s, y: level))
            for step in 1...30 {
                let t = Double(step) / 30
                let amplitude = sustain * pow(0.0001, t)
                path.addLine(to: CGPoint(x: s + (width + 5 - s) * t, y: baseline - amplitude * (baseline - top)))
            }
            path.addLine(to: CGPoint(x: width + 5, y: baseline))
            var fill = path
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.17), color.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
        .accessibilityLabel("Envelope: attack \(attack.formatted()) seconds, decay \(decay.formatted()) seconds, sustain \(Int(sustain * 100)) percent, release \(release.formatted()) seconds")
    }
}

struct WoodRail: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(hex: 0x8A6246), Palette.wood, Color(hex: 0x62432F)], startPoint: .leading, endPoint: .trailing)
                Path { path in
                    for i in 0..<8 {
                        let x = CGFloat(i) * 3.7
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addCurve(to: CGPoint(x: x + 2, y: proxy.size.height), control1: CGPoint(x: x - 6, y: proxy.size.height * 0.35), control2: CGPoint(x: x + 5, y: proxy.size.height * 0.7))
                    }
                }.stroke(.black.opacity(0.08), lineWidth: 0.6)
            }
        }.frame(width: 18)
    }
}

struct Screw: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xC3BEAE), Color(hex: 0x9B988B)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Capsule().fill(Palette.ink.opacity(0.6)).frame(width: 6, height: 1).rotationEffect(.degrees(-35))
        }.frame(width: 10, height: 10).overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
