import DriftwallCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppController.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let steps: [(symbol: String, title: String, text: String)] = [
        ("square.grid.2x2", "Pick a wallpaper", "Browse the included originals on Home and Explore, or import your own .mov, .mp4 or .m4v videos."),
        ("play.desktopcomputer", "Set it live", "Choose “Set as Wallpaper”. The video plays behind your windows on every Space, and pauses automatically when the Mac sleeps or the screen locks."),
        ("display.2", "Make it yours", "Give each display its own wallpaper, build playlists that rotate on a schedule, put your video on the lock screen, and control everything from the menu bar."),
    ]

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(Theme.accent)
                Text("Welcome to Driftwall")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Live video wallpapers for your Mac. Everything stays on this Mac — no account required.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(steps, id: \.title) { step in
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(.headline)
                                .foregroundStyle(Theme.primaryText)
                            Text(step.text)
                                .font(.callout)
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 460)
            HStack {
                Button("Import a Video…") {
                    finish()
                    app.presentImportPanel()
                }
                Spacer()
                Button("Get Started") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .frame(maxWidth: 460)
        }
        .padding(36)
        .frame(width: 560)
        .background(Theme.background)
    }

    private func finish() {
        app.settings.hasCompletedOnboarding = true
        dismiss()
    }
}
