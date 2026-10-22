import ShotsKit
import SwiftUI

/// The one-time offer, shown at the top of the main window until it's answered either way.
struct LaunchAtLoginBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "power.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start Shots when you log in?")
                    .font(.headline)
                Text("Shots files screenshots from the menu bar, so it needs to be running to see them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not Now") { model.loginItem.markOffered() }
                .clickable()
            Button("Launch at Login") { model.loginItem.setOn(true) }
                .buttonStyle(.borderedProminent)
                .clickable()
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

#Preview {
    LaunchAtLoginBanner()
        .environment(AppModel.preview())
}
