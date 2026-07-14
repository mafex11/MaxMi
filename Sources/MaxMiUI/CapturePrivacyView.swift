import SwiftUI

public struct CapturePrivacyView: View {
    @Bindable private var viewModel: CapturePrivacyViewModel

    public init(viewModel: CapturePrivacyViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("Capture & Privacy").font(.headline).foregroundColor(Theme.text)
            pauseCard
            domainCard
            blockedSources
            retentionCard
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
            HStack {
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
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }

    private var domainCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Blocked domains").font(.subheadline).foregroundColor(Theme.text)
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
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }

    private var blockedSources: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Paused sources").font(.subheadline).foregroundColor(Theme.text)
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
            if viewModel.snapshot.blockedApps.isEmpty && viewModel.snapshot.pausedThreads.isEmpty {
                Text("No paused apps or threads").font(.caption).foregroundColor(Theme.secondaryText)
            }
            Text("Pause an app or the current thread from the tray's right-click menu.")
                .font(.caption2).foregroundColor(Theme.tertiaryText)
        }
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
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
                Text("Memory retention").font(.subheadline).foregroundColor(Theme.text)
                Text("Cleanup is applied from Data Controls.").font(.caption).foregroundColor(Theme.secondaryText)
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
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }

    private var disclosureCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingHalf) {
            Label("Cloud processing", systemImage: "cloud")
                .font(.subheadline).foregroundColor(Theme.text)
            Text("Captured text is encrypted locally. New versions, meeting transcripts, display summaries, activity summaries, and semantic-search queries may be sent in plaintext to Google's Gemini API when those features run. Local tray search and MCP latest-context reads do not use Gemini.")
                .font(.caption).foregroundColor(Theme.secondaryText)
        }
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }
}

