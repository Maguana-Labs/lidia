import AVFoundation
import AppIntents
import LidIAAppIntents
import LidIAIntelligence
import LidIAKit
import SwiftData
import SwiftUI

/// One meeting: hero, quick actions, notes / my notes / transcript, action
/// items and details, with Ask docked at the bottom.
struct MeetingDetailView: View {
    let meetingID: UUID

    @Query private var matches: [Meeting]

    init(meetingID: UUID) {
        self.meetingID = meetingID
        _matches = Query(filter: #Predicate<Meeting> { $0.id == meetingID })
    }

    var body: some View {
        if let meeting = matches.first {
            MeetingDetailContent(meeting: meeting)
                // Onscreen context: "summarize this", "what did they ask me to do here?"
                .siriEntity(EntityIdentifier(for: MeetingEntity.self, identifier: meeting.id))
                .onAppear { SiriDonations.openedMeeting(meeting) }
        } else {
            ContentUnavailableView("Meeting not found", systemImage: "rectangle.stack", description: Text("It may have been deleted on another device."))
        }
    }
}

private struct MeetingDetailContent: View {
    @Bindable var meeting: Meeting

    enum Pane: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case notes = "My notes"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    @Environment(AppRouter.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(SyncCoordinator.self) private var sync
    @Environment(MeetingProcessor.self) private var processor
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pane: Pane = .summary
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var addingItem = false
    @State private var newItemTitle = ""
    @State private var notesSaveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                tiles
                Picker("Show", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: pane)

                switch pane {
                case .summary: summaryPane
                case .notes: notesPane
                case .transcript: TranscriptPane(meeting: meeting)
                }

                if pane == .summary {
                    actionItemsCard
                    detailsCard
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .background(Surface.background)
        .navigationTitle(meeting.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { askBar }
        .alert("Rename meeting", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                meeting.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                save(push: true)
                toasts.show("Renamed")
            }
        }
        .alert("New action item", isPresented: $addingItem) {
            TextField("What needs doing?", text: $newItemTitle)
            Button("Cancel", role: .cancel) {}
            Button("Add") { addItem() }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Meeting", role: .destructive) { deleteMeeting() }
        } message: {
            Text("Its notes, transcript and recording are removed from this iPhone.")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let tint = meeting.tint
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: meeting.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.2), in: .rect(cornerRadius: 14, style: .continuous))
                Spacer()
                if let folder = meeting.folder, !folder.isEmpty {
                    Label(folder, systemImage: "folder.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.2), in: .capsule)
                }
            }
            Text(meeting.displayTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if !meeting.attendeeNames.isEmpty {
                    AvatarStack(names: meeting.attendeeNames, size: 26, ring: tint.mix(with: .black, by: 0.15))
                }
                Text(heroLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [tint, tint.mix(with: Brand.ink, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { proxy in
                    WaveMark(amplitude: 0.3)
                        .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: proxy.size.width * 0.42, height: 56)
                        .position(x: proxy.size.width * 0.6, y: 50)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 26, style: .continuous))
        .shadow(color: tint.opacity(0.25), radius: 16, y: 8)
        .padding(.top, 8)
    }

    private var heroLine: String {
        var parts = [meeting.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())]
        if meeting.duration > 0 { parts.append(Format.duration(meeting.duration)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            ActionTile(title: "Copy notes", symbol: "doc.on.doc") {
                UIPasteboard.general.string = shareText
                toasts.show("Notes copied to clipboard")
            }
            ShareLink(item: shareText, subject: Text(meeting.displayTitle)) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.13), in: .circle)
                    Text("Share")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.card, in: .rect(cornerRadius: Metrics.tileRadius, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
    }

    private var shareText: String {
        var text = "# \(meeting.displayTitle)\n\(heroLine)\n\n"
        text += meeting.summaryText
        let open = meeting.openItems
        if !open.isEmpty, !meeting.summaryText.lowercased().contains("next steps") {
            text += "\n\n### Action items\n" + open.map { "- " + ($0.assignee.map { "\($0): " } ?? "") + $0.title }.joined(separator: "\n")
        }
        return text
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryPane: some View {
        let progress = processor.progress[meeting.id]
        Card(padding: 20) {
            switch meeting.status {
            case .processing, .queued, .recording:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress?.phase.label ?? "Writing notes")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let text = progress?.text, !text.isEmpty {
                        NotesMarkdownView(markdown: text, hidesNextSteps: false)
                    } else {
                        ShimmerLines()
                    }
                }
            case .failed:
                VStack(alignment: .leading, spacing: 12) {
                    Label("Notes didn’t finish", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(meeting.processingError ?? "Something went wrong while writing the notes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        processor.process(meeting, in: context)
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                }
            case .complete:
                if meeting.summaryText.isEmpty {
                    CardEmptyState(symbol: "text.alignleft", title: "No notes", message: "This meeting has no summary yet.")
                } else {
                    NotesMarkdownView(markdown: meeting.summaryText)
                }
            }
        }
    }

    // MARK: - My notes

    private var notesPane: some View {
        Card(padding: 16) {
            ZStack(alignment: .topLeading) {
                if meeting.notes.isEmpty {
                    Text("Jot down anything. Your notes sync with the Mac and are merged into the summary there.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $meeting.notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .onChange(of: meeting.notes) { _, _ in
                        notesSaveTask?.cancel()
                        notesSaveTask = Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            guard !Task.isCancelled else { return }
                            save(push: true)
                        }
                    }
            }
        }
    }

    // MARK: - Action items

    private var actionItemsCard: some View {
        let items = meeting.actionItems.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            return (lhs.deadlineDate ?? .distantFuture) < (rhs.deadlineDate ?? .distantFuture)
        }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Action items", subtitle: items.isEmpty ? nil : "\(meeting.openItems.count) of \(items.count) open", actionTitle: "Add") {
                newItemTitle = ""
                addingItem = true
            }
            Card {
                if items.isEmpty {
                    CardEmptyState(symbol: "checklist", title: "No commitments", message: "Nobody took on a task in this meeting.")
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ActionItemRow(item: item, showsMeeting: false) {
                            ActionItemActions.toggle(item, context: context, toasts: toasts, sync: sync)
                        }
                        .onTapGesture { router.actionItemDetail = .init(id: item.id) }
                        if index < items.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Details")
            Card {
                DetailRow(label: "Date", value: meeting.date.formatted(date: .complete, time: .shortened))
                RowDivider(leading: 16)
                DetailRow(label: "Length", value: meeting.duration > 0 ? Format.duration(meeting.duration) : "—")
                if !meeting.attendeeNames.isEmpty {
                    RowDivider(leading: 16)
                    DetailRow(label: "People", value: meeting.attendeeNames.joined(separator: ", "), actionTitle: "Copy") {
                        UIPasteboard.general.string = meeting.attendeeNames.joined(separator: ", ")
                        toasts.show("Names copied to clipboard")
                    }
                }
                RowDivider(leading: 16)
                DetailRow(label: "Recorded", value: meeting.recordedOnThisDevice ? "On this iPhone" : "On your Mac")
                let words = meeting.transcriptText.split(whereSeparator: \.isWhitespace).count
                if words > 0 {
                    RowDivider(leading: 16)
                    DetailRow(label: "Transcript", value: "\(words.formatted()) words")
                }
            }
        }
    }

    // MARK: - Toolbar & Ask

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newTitle = meeting.title
                    renaming = true
                }
                Button("Write notes again", systemImage: "arrow.clockwise") {
                    processor.process(meeting, in: context)
                    pane = .summary
                }
                .disabled(meeting.transcriptText.isEmpty || processor.isProcessing(meeting.id))
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private var askBar: some View {
        Button {
            router.askSheet = .init(meetingID: meeting.id, meetingTitle: meeting.displayTitle)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.markOnPaper)
                Text("Ask about this meeting")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 52)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 6)
    }

    // MARK: - Actions

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let item = ActionItem(title: title)
        item.meeting = meeting
        context.insert(item)
        meeting.actionItems.append(item)
        try? context.save()
        sync.push(item)
        toasts.show("Action item added")
    }

    private func save(push: Bool) {
        try? context.save()
        if push { sync.push(meeting) }
    }

    private func deleteMeeting() {
        if let url = meeting.audioURL { try? FileManager.default.removeItem(at: url) }
        for item in meeting.actionItems { sync.deleteActionItem(id: item.id) }
        sync.deleteMeeting(id: meeting.id)
        context.delete(meeting)
        try? context.save()
        dismiss()
        toasts.show("Meeting deleted", symbol: "trash.fill", style: .info)
    }
}

/// Placeholder lines while the first words of the notes arrive.
struct ShimmerLines: View {
    @State private var phase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([0.55, 0.92, 0.8, 0.88, 0.6], id: \.self) { width in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(phase ? 0.18 : 0.08))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, anchor: .leading)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityLabel("Loading")
    }
}

// MARK: - Transcript

private struct TranscriptPane: View {
    let meeting: Meeting
    @State private var player = TranscriptPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = meeting.audioURL {
                AudioBar(player: player, url: url, duration: meeting.duration)
            }
            Card(padding: 20) {
                let text = meeting.transcriptText
                if text.isEmpty {
                    CardEmptyState(symbol: "text.quote", title: "No transcript", message: "This meeting doesn’t have a transcript.")
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.body)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .onDisappear { player.stop() }
    }
}

@MainActor
@Observable
final class TranscriptPlayer {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private var timer: Timer?

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            timer?.invalidate()
            return
        }
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
        }
        player?.play()
        isPlaying = player?.isPlaying ?? false
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying { self.isPlaying = false }
            }
        }
    }

    func skip(_ seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.currentTime + seconds))
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
    }
}

private struct AudioBar: View {
    let player: TranscriptPlayer
    let url: URL
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.tap()
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: player.progress)
                    .tint(.accentColor)
                HStack {
                    Text(Format.clock(duration * player.progress))
                    Spacer()
                    Text(Format.clock(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Button {
                player.skip(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back 15 seconds")
        }
        .padding(14)
        .background(Surface.card, in: .rect(cornerRadius: Metrics.tileRadius, style: .continuous))
    }
}

private extension View {
    /// SwiftUI's `appEntityIdentifier(_:)` is new in the 27 SDKs (Swift 6.4);
    /// older Xcodes build without it.
    @ViewBuilder
    func siriEntity(_ identifier: EntityIdentifier) -> some View {
        #if compiler(>=6.4)
        appEntityIdentifier(identifier)
        #else
        self
        #endif
    }
}
