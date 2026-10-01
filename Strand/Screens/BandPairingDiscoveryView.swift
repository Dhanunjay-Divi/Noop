import SwiftUI
import StrandDesign

enum BandPairingDiscoveryState: Equatable {
    case ready
    case searching
    case connected
}

struct BandPairingDiscoveryView: View {
    let state: BandPairingDiscoveryState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0

    var body: some View {
        VStack(spacing: 12) {
            discoveryMark
            statusCopy
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .onAppear(perform: updateMotion)
        .onChangeCompat(of: state) { _ in updateMotion() }
        .onChangeCompat(of: reduceMotion) { _ in updateMotion() }
        .onDisappear(perform: resetMotion)
    }

    private var discoveryMark: some View {
        ZStack {
            Circle()
                .stroke(
                    StrandPalette.hairline,
                    style: StrokeStyle(lineWidth: 1)
                )
                .frame(width: 132, height: 132)

            discoveryArc(
                diameter: 132,
                trim: 0.04...0.34,
                opacity: state == .searching ? 0.90 : 0.42,
                width: 2,
                rotation: sweep
            )
            discoveryArc(
                diameter: 102,
                trim: 0.10...0.54,
                opacity: state == .searching ? 0.52 : 0.28,
                width: 1.5,
                rotation: 110 - sweep * 0.68
            )
            discoveryArc(
                diameter: 76,
                trim: 0.14...0.70,
                opacity: state == .searching ? 0.32 : 0.18,
                width: 1.25,
                rotation: 230 + sweep * 0.42
            )

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .frame(width: 58, height: 58)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 18,
                        style: .continuous
                    )
                    .stroke(StrandPalette.hairline, lineWidth: 1)
                }
                .overlay {
                    Image(systemName: centerSymbol)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(centerTint)
                        .accessibilityHidden(true)
                }
        }
        .frame(height: 140)
    }

    private func discoveryArc(
        diameter: CGFloat,
        trim: ClosedRange<CGFloat>,
        opacity: Double,
        width: CGFloat,
        rotation: Double
    ) -> some View {
        Circle()
            .trim(from: trim.lowerBound, to: trim.upperBound)
            .stroke(
                centerTint.opacity(opacity),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(rotation))
    }

    @ViewBuilder private var statusCopy: some View {
        VStack(spacing: 4) {
            Group {
                switch state {
                case .ready:
                    Text("appwide.onboarding.device_wizard.idle")
                case .searching:
                    Text("appwide.onboarding.device_wizard.searching")
                case .connected:
                    Text("appwide.onboarding.device_ready_title")
                }
            }
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)

            Group {
                switch state {
                case .ready:
                    Text("appwide.onboarding.device_wizard.add_body")
                case .searching:
                    Text("Make sure it's awake and not connected elsewhere.")
                case .connected:
                    Text("appwide.onboarding.device_ready_body")
                }
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var centerSymbol: String {
        state == .connected
            ? "checkmark.circle.fill"
            : "applewatch.side.right"
    }

    private var centerTint: Color {
        state == .connected
            ? StrandPalette.statusPositive
            : StrandPalette.accent
    }

    private func updateMotion() {
        resetMotion()
        guard state == .searching, !reduceMotion else { return }
        withAnimation(
            .linear(duration: 3.2)
                .repeatForever(autoreverses: false)
        ) {
            sweep = 360
        }
    }

    private func resetMotion() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sweep = 0
        }
    }
}

struct BandPairingOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let enabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(StrandFont.title2)
                    .foregroundStyle(
                        enabled
                            ? StrandPalette.accent
                            : StrandPalette.textTertiary
                    )
                    .frame(width: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(
                            enabled
                                ? StrandPalette.textPrimary
                                : StrandPalette.textSecondary
                        )
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(
                            enabled
                                ? StrandPalette.textTertiary
                                : StrandPalette.statusWarning
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(
                    systemName:
                        enabled ? "chevron.right" : "exclamationmark.circle"
                )
                .font(StrandFont.subhead)
                .foregroundStyle(
                    enabled
                        ? StrandPalette.textTertiary
                        : StrandPalette.statusWarning
                )
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityValue(
            enabled ? String(localized: "Available") : subtitle
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct BandPairingOptionDivider: View {
    var body: some View {
        Divider()
            .overlay(StrandPalette.hairline)
            .padding(.leading, 58)
    }
}
