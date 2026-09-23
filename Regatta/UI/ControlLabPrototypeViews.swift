// PROTOTYPE for "Steering and boat-handling controls" (issue #13). Throwaway: see ControlLabPrototype.swift.

import RegattaCore
import SwiftUI

/// The variant switcher. Yellow so it's obviously not part of the design being judged.
struct ControlLabBar: View {
    let lab: ControlLab

    var body: some View {
        HStack(spacing: 10) {
            Button { lab.steer = lab.steer.cycled(by: -1) } label: { Image(systemName: "chevron.left") }
            Text(lab.steer.label).frame(minWidth: 80)
            Button { lab.steer = lab.steer.cycled(by: 1) } label: { Image(systemName: "chevron.right") }
            separator
            Button(lab.camera.label) { lab.camera = lab.camera.cycled(by: 1) }
            separator
            Button(lab.zoom.label) { lab.zoom = lab.zoom.cycled(by: 1) }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow, in: .capsule)
        .shadow(radius: 4)
    }

    private var separator: some View {
        Rectangle().fill(.black.opacity(0.3)).frame(width: 1, height: 14)
    }
}

/// A button that reports while it's held down.
struct HoldButton: View {
    let title: String
    let onChange: (Bool) -> Void
    @State private var isHeld = false

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.heavy))
            .tracking(1)
            .frame(width: 76, height: 44)
            .background(isHeld ? Color.white.opacity(0.55) : Color.black.opacity(0.35), in: .capsule)
            .foregroundStyle(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHeld else { return }
                        isHeld = true
                        onChange(true)
                    }
                    .onEnded { _ in
                        isHeld = false
                        onChange(false)
                    }
            )
    }
}

struct SpinButton: View {
    let lab: ControlLab

    var body: some View {
        Button { lab.isSpinning.toggle() } label: {
            Text(lab.isSpinning ? "STOP" : "SPIN")
                .font(.subheadline.weight(.heavy))
                .tracking(1)
                .frame(width: 76, height: 44)
                .background(Color.white, in: .capsule)
                .foregroundStyle(.black)
        }
    }
}

/// Rudder position for every scheme, plus the held angle for wind lock.
struct RudderGauge: View {
    let lab: ControlLab

    var body: some View {
        VStack(spacing: 4) {
            if lab.steer == .windLock, let angle = lab.lockedWindAngle {
                Text("\(Int(rad2deg(abs(angle)).rounded()))° \(angle >= 0 ? "STBD" : "PORT")")
                    .font(.caption.weight(.heavy).monospacedDigit())
            }
            GeometryReader { geometry in
                ZStack {
                    Capsule().fill(.white.opacity(0.2))
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .offset(x: CGFloat(lab.rudder) * (geometry.size.width / 2 - 5))
                }
            }
            .frame(width: 76, height: 10)
            Text("Rudder").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(width: 80)
        .allowsHitTesting(false)
    }
}

/// Scheme C. Drag on the ring to set the heading the boat steers to. The shaded wedge is the
/// no-go zone either side of the wind, the needle is the boat's heading, the dot is the target.
struct HeadingDial: View {
    let lab: ControlLab
    let heading: Double
    let windDirection: Double
    private let size: CGFloat = 140

    var body: some View {
        let top = lab.viewHeading
        ZStack {
            Circle().fill(.black.opacity(0.35))
            NoGoWedge(center: windDirection - top, halfWidth: deg2rad(38)).fill(.white.opacity(0.2))
            Circle().stroke(.white.opacity(0.5), lineWidth: 2)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .offset(y: -size / 2 - 10)
                .rotationEffect(.radians(windDirection - top))
            Capsule().fill(.white)
                .frame(width: 3, height: size / 2 - 16)
                .offset(y: -(size / 2 - 16) / 2)
                .rotationEffect(.radians(heading - top))
            if let target = lab.dialHeading {
                Circle().fill(Color(uiColor: Palette.startLine))
                    .frame(width: 16, height: 16)
                    .offset(y: -size / 2 + 9)
                    .rotationEffect(.radians(target - top))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                let dx = Double(value.location.x - size / 2)
                let dy = Double(value.location.y - size / 2)
                guard dx * dx + dy * dy > 100 else { return }
                lab.dialHeading = wrapAngle(atan2(dx, -dy) + lab.viewHeading)
            }
        )
    }
}

private struct NoGoWedge: Shape {
    let center: Double
    let halfWidth: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: c)
        path.addArc(center: c, radius: rect.width / 2,
                    startAngle: .radians(center - halfWidth - .pi / 2),
                    endAngle: .radians(center + halfWidth - .pi / 2),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Scheme B. A track under the touch-down point and a knob under the finger.
struct TillerIndicator: View {
    let lab: ControlLab

    var body: some View {
        ZStack {
            if lab.steer == .tiller, let origin = lab.dragOrigin, let point = lab.dragPoint {
                Capsule().fill(.black.opacity(0.3)).frame(width: 172, height: 10).position(origin)
                Circle().stroke(.white.opacity(0.6), lineWidth: 2).frame(width: 18, height: 18).position(origin)
                Circle().fill(.white.opacity(0.9)).frame(width: 26, height: 26)
                    .position(x: origin.x + (point.x - origin.x).clamped(to: -80...80), y: origin.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
