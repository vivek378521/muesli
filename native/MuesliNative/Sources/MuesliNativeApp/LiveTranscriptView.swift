// Purpose: Scrolling live transcript view with auto-scroll during active meetings
// Created: 2026-05-22

import SwiftUI

private struct LiveTranscriptGroup: Identifiable {
    let id: UUID = UUID()
    let speaker: String?
    let isUser: Bool
    let lines: [String]
    let timestamp: String?

    static func grouped(from messages: [TranscriptChatMessage]) -> [LiveTranscriptGroup] {
        var groups: [LiveTranscriptGroup] = []
        for msg in messages {
            if let last = groups.last, last.speaker == msg.speaker {
                let updated = LiveTranscriptGroup(
                    speaker: last.speaker,
                    isUser: last.isUser,
                    lines: last.lines + [msg.text],
                    timestamp: last.timestamp
                )
                groups[groups.count - 1] = updated
            } else {
                groups.append(LiveTranscriptGroup(
                    speaker: msg.speaker,
                    isUser: msg.isUser,
                    lines: [msg.text],
                    timestamp: msg.timestamp
                ))
            }
        }
        return groups
    }
}

struct LiveTranscriptView: View {
    let transcript: String
    @State private var groups: [LiveTranscriptGroup] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if groups.isEmpty {
                        Text("Waiting for speech…")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(MuesliTheme.spacing16)
                    } else {
                        ForEach(groups) { group in
                            liveBubble(for: group)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("liveTranscriptBottom")
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
            }
            .onChange(of: transcript) { _, newTranscript in
                groups = LiveTranscriptGroup.grouped(
                    from: TranscriptChatMessage.messages(from: newTranscript)
                )
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                    }
                }
            }
            .onAppear {
                groups = LiveTranscriptGroup.grouped(
                    from: TranscriptChatMessage.messages(from: transcript)
                )
                DispatchQueue.main.async {
                    proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func liveBubble(for group: LiveTranscriptGroup) -> some View {
        let isUser = group.isUser
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = group.speaker {
                    Text(speaker + (group.timestamp.map { "  \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isUser ? MuesliTheme.accent.opacity(0.15) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        isUser ? MuesliTheme.accent.opacity(0.2) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
