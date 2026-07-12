import SwiftUI

/// Aurora — the design system's canonical shell direction: the icon's
/// world enters the app in controlled doses (`--aurora-*` in
/// `docs/design/ds/tokens/colors.css`). The doses exist in the DARK
/// appearance only — the brand's world is dark; light stays native macOS.
///
/// The fourth token (`--aurora-selection`, a gradient list selection) is
/// deliberately NOT adopted: macOS draws sidebar selection natively and
/// repainting it fights the platform; the DS's indigo stance is already
/// covered by the compiled `AccentColor` asset.
enum Aurora {
    /// `--aurora-window` stop 0: the slate-violet corner the gradient
    /// rises from.
    static let slateViolet = Color(red: 0x1C / 255, green: 0x1A / 255, blue: 0x2E / 255)
    /// `--aurora-window` stops 45–100%: the DS dark window base.
    static let darkBase = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255)
}

/// The detail pane's Aurora: the window gradient plus the violet header
/// radial bleeding in from above the top-leading corner (the glow's
/// center sits off-screen, so only its soft tail reaches the content).
struct AuroraDetailBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(
                        stops: [
                            .init(color: Aurora.slateViolet, location: 0),
                            .init(color: Aurora.darkBase, location: 0.45),
                            .init(color: Aurora.darkBase, location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                    EllipticalGradient(
                        stops: [
                            .init(color: PVDesign.brandViolet.opacity(0.5), location: 0),
                            .init(color: .clear, location: 0.7)
                        ])
                        .frame(width: 1400, height: 520)
                        .position(x: geo.size.width * 0.2, y: -104)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .ignoresSafeArea()
        }
    }
}

/// The sidebar's Aurora: deep slate glass — the brand ground at 0.6 over
/// the native vibrancy material, so the desktop still breathes through.
struct AuroraSidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            PVDesign.brandSlate.opacity(0.6).ignoresSafeArea()
        }
    }
}
