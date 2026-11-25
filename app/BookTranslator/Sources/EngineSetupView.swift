import SwiftUI

/// Shown over the window until the built-in engine's Python environment exists.
struct EngineSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(Loc.self) private var loc

    var body: some View {
        let setup = model.engineSetup
        VStack(spacing: 16) {
            Image(systemName: setup.state == .noPython ? "exclamationmark.triangle.fill" : "shippingbox.fill")
                .font(.system(size: 40)).foregroundStyle(setup.state == .noPython ? Theme.warnIcon : Theme.accent)
            Text(loc.t("setup.title")).font(.system(size: 20, weight: .semibold))
            switch setup.state {
            case .working:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.regular)
                    Text(loc.t("setup.working", setup.stepsDone)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    if !setup.progress.isEmpty {
                        Text(setup.progress).font(.system(size: 11).monospaced()).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                    }
                }
            case .noPython:
                Text(loc.t("setup.noPython")).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                HStack {
                    Text("brew install python@3.13").font(.system(size: 12).monospaced()).textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.neutralBg, in: RoundedRectangle(cornerRadius: 7))
                    Button(loc.t("setup.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install python@3.13", forType: .string)
                    }.buttonStyle(GhostButtonStyle())
                }
                Button(loc.t("setup.checkAgain")) { model.runSetup() }.buttonStyle(PrimaryButtonStyle(radius: 8))
            case .failed(let message):
                Text(loc.t("setup.failed", message)).font(.system(size: 12)).foregroundStyle(.red).multilineTextAlignment(.center).lineLimit(5)
                Button(loc.t("setup.retry")) { model.runSetup() }.buttonStyle(PrimaryButtonStyle(radius: 8))
            default:
                Text(loc.t("setup.body")).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button(loc.t("setup.start")) { model.runSetup() }.buttonStyle(PrimaryButtonStyle(radius: 8))
            }
            if setup.state != .working {
                Button(loc.t("setup.useFolder")) { model.chooseDeveloperFolder() }.buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(32).frame(width: 480)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window.opacity(0.96))
    }
}
