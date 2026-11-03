import SwiftUI
import SwiftData

/// The meeting inspector's "Ask" tab: a meeting-scoped chat with the same
/// components as Chats (compact), and starters from this meeting.
///
/// Uses the app's shared chat engine (`ChatBarViewModel`) and thread store, so
/// conversations are persisted like any other chat thread. The view model is
/// owned by the meeting page, so history survives inspector tab switches; the
/// thread is reopened from `MeetingAskThreadIndex` when the meeting is reopened.
struct MeetingChatView: View {
    let meeting: Meeting
    @Bindable var viewModel: ChatBarViewModel

    @Environment(AppSettings.self) private var settings

    var body: some View {
        ChatConversationView(
            viewModel: viewModel,
            placeholder: "Ask about this meeting",
            columnWidth: .infinity,
            horizontalPadding: 16
        ) {
            emptyState
        }
        .environment(\.chatDensity, .compact)
        #if DEBUG
        .task {
            // Snapshot runs show a recorded conversation about this meeting.
            guard let messages = ChatSnapshotFixtures.pendingMeetingAskMessages else { return }
            try? await Task.sleep(for: .milliseconds(200))
            ChatSnapshotFixtures.pendingMeetingAskMessages = nil
            viewModel.showSnapshotMessages(messages)
        }
        #endif
        .overlay(alignment: .topTrailing) {
            if !viewModel.messages.isEmpty {
                ChatIconButton(systemImage: "square.and.pencil", help: "New conversation about this meeting") {
                    viewModel.clearConversation()
                }
                .disabled(viewModel.isStreaming)
                .padding(8)
            }
        }
    }

    private var people: [String] {
        AttendeeParser.parse(meeting.calendarAttendees ?? [], currentUserName: settings.displayName)
            .filter { !$0.isCurrentUser && !$0.name.contains("@") }
            .map(\.name)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ChatPixelLoader(size: 13)
                            Text("Ask about this meeting")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text("Answers use this meeting's transcript, notes and summary, with citations.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 8) {
                        ForEach(ChatStarters.forMeeting(people: people, openItems: meeting.actionItems.filter { !$0.isCompleted }.count)) { starter in
                            ChatStarterCard(starter: starter) {
                                viewModel.inputText = starter.prompt
                                viewModel.send()
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            ChatComposer(viewModel: viewModel, placeholder: "Ask about this meeting")
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }
}

/// Owns and configures the meeting-scoped chat view model.
@MainActor
enum MeetingAskSession {
    static func configure(
        _ viewModel: ChatBarViewModel,
        meeting: Meeting,
        settings: AppSettings,
        modelContext: ModelContext,
        backgroundContext: ModelContext?,
        modelManager: ModelManager,
        index: MeetingAskThreadIndex = MeetingAskThreadIndex()
    ) {
        viewModel.configure(
            settings: settings,
            modelContext: modelContext,
            modelManager: modelManager,
            backgroundContext: backgroundContext
        )
        viewModel.updateSelectedMeeting(meeting)
        if let threadID = index.threadID(for: meeting.id),
           viewModel.threads.contains(where: { $0.id == threadID }) {
            viewModel.openThread(id: threadID)
        } else {
            viewModel.startNewThread(scope: .selectedMeeting)
        }
        viewModel.contextScope = .selectedMeeting
    }
}
