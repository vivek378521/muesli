import SwiftUI

struct LiveMeetingPanel: View {
    let appState: AppState
    let controller: MuesliController
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if appState.liveTranscriptLines.isEmpty {
                waitingState
            } else {
                LiveMeetingTranscriptView(lines: appState.liveTranscriptLines)
            }
        }
        .background(MuesliTheme.backgroundBase)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(MuesliTheme.accent.opacity(0.3), lineWidth: 1)
        )
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)

            Text(appState.liveMeetingTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)

            Text(formatElapsed(elapsedSeconds))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MuesliTheme.textTertiary)

            Spacer()

            Button {
                controller.stopMeetingRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
    }

    private var waitingState: some View {
        HStack {
            Spacer()
            Text("Listening...")
                .font(.system(size: 13))
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer()
        }
        .frame(height: 80)
    }

    private func startTimer() {
        updateElapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            updateElapsed()
        }
    }

    private func updateElapsed() {
        guard let start = appState.liveMeetingStartTime else { return }
        elapsedSeconds = Int(Date().timeIntervalSince(start))
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct LiveMeetingTranscriptView: View {
    let lines: [LiveTranscriptLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatTimestamp(line.timestamp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .frame(width: 52, alignment: .trailing)

                            Text(line.speaker)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(line.speaker == "You" ? MuesliTheme.accent : MuesliTheme.textSecondary)
                                .frame(width: 50, alignment: .leading)

                            Text(line.text)
                                .font(.system(size: 13))
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                }
                .padding(MuesliTheme.spacing12)
            }
            .frame(maxHeight: 300)
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
