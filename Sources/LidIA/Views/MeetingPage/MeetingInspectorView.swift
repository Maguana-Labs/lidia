import SwiftUI

enum MeetingInspectorTab: String, CaseIterable, Identifiable {
    case transcript
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .ask: "Ask"
        }
    }
}

/// Right-hand inspector of the meeting page: Transcript or Ask.
struct MeetingInspectorView: View {
    let meeting: Meeting
    @Binding var tab: MeetingInspectorTab
    var liveWords: [TranscriptWord]?
    var player: TranscriptAudioPlayer
    var askViewModel: ChatBarViewModel
    var onEditTranscript: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(MeetingInspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .transcript:
                TranscriptInspectorView(
                    meeting: meeting,
                    liveWords: liveWords,
                    player: player,
                    onEditTranscript: onEditTranscript
                )
            case .ask:
                MeetingChatView(meeting: meeting, viewModel: askViewModel)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
