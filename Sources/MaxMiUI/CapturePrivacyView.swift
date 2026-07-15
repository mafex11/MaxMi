import SwiftUI

public struct CapturePrivacyView: View {
    @Bindable private var viewModel: CapturePrivacyViewModel

    public init(viewModel: CapturePrivacyViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("Capture & Privacy").sectionTitle()
            Text("Control what MaxMi records and where it goes.")
                .font(.caption).foregroundColor(Theme.tertiaryText)
            pauseCard
            Divider().background(Theme.divider)
            domainCard
            Divider().background(Theme.divider)
            blockedSources
            Divider().background(Theme.divider)
            retentionCard
            Divider().background(Theme.divider)
            disclosureCard
            if let message = viewModel.message {
                Text(message).font(.caption).foregroundColor(Theme.secondaryText)
            }
        }
    }

    private var pauseCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Label(viewModel.snapshot.pauseDescription,
                  systemImage: viewModel.snapshot.isPaused ? "pause.circle.fill" : "record.circle")
                .foregroundColor(viewModel.snapshot.isPaused ? Theme.warning : Theme.accent)
            FlowLayout(spacing: Theme.spacing1) {
                Button("15 min") { Task { await viewModel.setPause(.minutes(15)) } }
                Button("1 hour") { Task { await viewModel.setPause(.minutes(60)) } }
                Button("Until tomorrow") { Task { await viewModel.setPause(.untilTomorrow) } }
                Button("Indefinitely") { Task { await viewModel.setPause(.indefinite) } }
                if viewModel.snapshot.isPaused {
                    Button("Resume") { Task { await viewModel.setPause(.resume) } }
                        .buttonStyle(.borderedProminent)
                }
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var domainCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Never capture these websites").font(.subheadline).foregroundColor(Theme.text)
            HStack {
                TextField("example.com", text: $viewModel.newDomain).textFieldStyle(.roundedBorder)
                Button("Block") { Task { await viewModel.addDomain() } }.buttonStyle(.bordered)
            }
            ForEach(viewModel.snapshot.blockedDomains, id: \.self) { domain in
                HStack {
                    Image(systemName: "globe.badge.chevron.backward").foregroundColor(Theme.warning)
                    Text(domain).foregroundColor(Theme.text)
                    Spacer()
                    Button("Allow") { Task { await viewModel.removeDomain(domain) } }.buttonStyle(.link)
                }
            }
            if viewModel.snapshot.blockedDomains.isEmpty {
                Text("No user-blocked domains").font(.caption).foregroundColor(Theme.secondaryText)
            }
        }
    }

    private var blockedSources: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Paused apps & conversations").font(.subheadline).foregroundColor(Theme.text)
            ForEach(viewModel.snapshot.blockedApps) { app in
                sourceRow(icon: "app.badge", title: app.name, subtitle: app.id) {
                    Task { await viewModel.resumeApp(app.id) }
                }
            }
            ForEach(viewModel.snapshot.pausedThreads) { thread in
                sourceRow(icon: "text.bubble", title: thread.label, subtitle: thread.sourceApp) {
                    Task { await viewModel.resumeThread(thread.id) }
                }
            }
            ForEach(viewModel.snapshot.localOnlySources, id: \.self) { source in
                sourceRow(icon: "icloud.slash", title: source, subtitle: "Local only") {
                    Task { await viewModel.allowCloudSource(source) }
                }
            }
            if viewModel.snapshot.blockedApps.isEmpty && viewModel.snapshot.pausedThreads.isEmpty
                && viewModel.snapshot.localOnlySources.isEmpty {
                Text("No paused apps or threads").font(.caption).foregroundColor(Theme.secondaryText)
            }
            Text("Pause an app or the current thread from the tray's right-click menu.")
                .font(.caption2).foregroundColor(Theme.tertiaryText)
        }
    }

    private func sourceRow(icon: String, title: String, subtitle: String, resume: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(Theme.warning)
            VStack(alignment: .leading) {
                Text(title).foregroundColor(Theme.text)
                Text(subtitle).font(.caption2).foregroundColor(Theme.tertiaryText)
            }
            Spacer()
            Button("Resume") { resume() }.buttonStyle(.link)
        }
    }

    private var retentionCard: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("How long to keep memories").font(.subheadline).foregroundColor(Theme.text)
                Text("Older memories are removed when you run cleanup in Data Controls.").font(.caption).foregroundColor(Theme.secondaryText)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { viewModel.snapshot.retentionDays ?? 0 },
                set: { value in Task { await viewModel.setRetention(value == 0 ? nil : value) } }
            )) {
                Text("Forever").tag(0)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }.frame(width: 130)
        }
    }

    private var disclosureCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingHalf) {
            Label("What leaves your Mac", systemImage: "cloud")
                .font(.subheadline).foregroundColor(Theme.text)
            Text("Your captures are stored encrypted on this Mac. When AI features run (summaries, meeting transcripts, timeline, and search), the relevant text is sent to Google's Gemini to process it. Plain tray search stays fully on-device.")
                .font(.caption).foregroundColor(Theme.secondaryText)
        }
    }
}
