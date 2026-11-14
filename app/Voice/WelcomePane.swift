import KeyboardShortcuts
import SwiftUI

/// The first thing a Mac sees until it is activated, including an install that just updated.
/// Everything after the button happens on the website, so it can change without an update.
struct WelcomePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Dictate is free during early access.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Activate once with your email. It opens in your browser.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(FirstLaunch.menuBarLine(shortcut: KeyboardShortcuts.getShortcut(for: .dictate)?.description))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let problem = model.activationProblem {
                Text(problem)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Activate in Browser") { model.beginActivation() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
