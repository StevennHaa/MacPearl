import SwiftUI

struct EnrollmentGuidanceView: View {
    let pose: FaceCapturePose
    let completed: Int
    let guidance: EnrollmentGuidance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Array(FaceCapturePose.allCases.enumerated()), id: \.element) { index, item in
                    HStack(spacing: 5) {
                        Image(systemName: index < completed ? "checkmark.circle.fill" : "circle.fill")
                        Text(title(item))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(index < completed ? Color.green : (item == pose ? Color.primary : Color.secondary))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(item == pose ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
                    .accessibilityLabel("\(title(item)), \(index < completed ? "complete" : (item == pose ? "current pose" : "next pose"))")
                }
            }
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(guidance.holdProgress == nil ? Color.cyan.opacity(0.12) : Color.green.opacity(0.12))
                    if let progress = guidance.holdProgress {
                        Circle().trim(from: 0, to: progress)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: progress >= 1 ? "checkmark" : "face.smiling")
                            .font(.title2.weight(.semibold)).foregroundStyle(.green)
                    } else {
                        Image(systemName: guidance.direction?.symbol ?? "viewfinder")
                            .font(.title2.weight(.semibold)).foregroundStyle(.cyan)
                            .symbolEffect(.pulse, isActive: guidance.direction != nil && !reduceMotion)
                    }
                }
                .frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(guidance.message).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(guidance.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let position = guidance.position {
                VStack(spacing: 7) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.cyan.opacity(0.4))
                            .frame(width: width * (guidance.target.upperBound - guidance.target.lowerBound))
                            .offset(x: width * guidance.target.lowerBound)
                        Circle().fill(guidance.holdProgress == nil ? Color.primary : Color.green)
                            .frame(width: 14, height: 14)
                            .offset(x: min(max(width * position - 7, 0), max(width - 14, 0)), y: -3)
                    }
                    .frame(height: 8).accessibilityHidden(true)
                    Text("Bring the dot into the highlighted area, then hold still.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func title(_ pose: FaceCapturePose) -> String {
        switch pose {
        case .forward: "Face forward"
        case .left: "Turn left"
        case .right: "Turn right"
        }
    }
}
