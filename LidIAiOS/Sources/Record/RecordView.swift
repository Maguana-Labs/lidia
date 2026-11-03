import LidIAKit
import SwiftUI

/// Recording, full screen: one big button, a live view worth looking at,
/// then the notes being written in front of you.
struct RecordView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(MeetingProcessor.self) private var processor
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(Intelligence.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    var body: some View {
        ZStack {
            Brand.night.ignoresSafeArea()
            AmbientGlow(level: Double(recorder.levels.last ?? 0), active: recorder.phase == .recording)
                .ignoresSafeArea()

            switch recorder.phase {
            case .idle, .preparing, .failed:
                ReadyStage(confirmClose: { close() })
            case .recording, .paused:
                LiveStage(minimize: { dismiss() }, discard: { confirmDiscard = true })
            case .finishing, .processing:
                ProcessingStage(done: { finish(open: false) }, open: { finish(open: true) })
            }
        }
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.45), value: recorder.phase)
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                recorder.discard()
                dismiss()
            }
        } message: {
            Text("The audio and transcript so far are deleted from this iPhone.")
        }
    }

    private func close() {
        if case .failed = recorder.phase { recorder.reset() }
        if recorder.phase == .idle { recorder.draft = .init() }
        dismiss()
    }

    private func finish(open: Bool) {
        let id = recorder.meetingID
        recorder.reset()
        dismiss()
        if open, let id {
            router.tab = .home
            router.open(id)
        }
    }
}

// MARK: - Ready

private struct ReadyStage: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(AppSettings.self) private var settings
    let confirmClose: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        @Bindable var recorder = recorder
        VStack(spacing: 0) {
            HStack {
                CircleButton(symbol: "xmark", label: "Close", action: confirmClose)
                Spacer()
                Label("On this iPhone", systemImage: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            VStack(spacing: 10) {
                TextField("", text: $recorder.draft.title, prompt: Text("Untitled meeting").foregroundStyle(.white.opacity(0.45)), axis: .vertical)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .lineLimit(1...2)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .padding(.horizontal, 32)
                if !recorder.draft.attendees.isEmpty {
                    HStack(spacing: 8) {
                        AvatarStack(names: recorder.draft.attendees, size: 26, ring: Color(hex: 0x160E44))
                        Text(recorder.draft.attendees.map(Format.displayName).prefix(3).joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    Text("Name it now or let LidIA name it after")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.top, 56)

            Spacer()

            BigRecordButton(isPreparing: recorder.phase == .preparing) {
                titleFocused = false
                Task { await recorder.start() }
            }

            VStack(spacing: 6) {
                Text(recorder.phase == .preparing ? "Getting the microphone ready…" : "Tap to record")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Transcribed live on this iPhone. Keeps recording when the screen locks.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.top, 28)

            Spacer()

            if case .failed(let message) = recorder.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else if settings.consentReminder {
                Label("Let everyone know you’re recording.", systemImage: "hand.wave.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.bottom, 20)
            }
        }
    }
}

private struct BigRecordButton: View {
    var isPreparing: Bool
    let action: () -> Void
    @State private var breathe = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Brand.mark, lineWidth: 3)
                    .frame(width: 168, height: 168)
                    .opacity(0.55)
                    .scaleEffect(breathe ? 1.06 : 0.98)
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 148, height: 148)
                Circle()
                    .fill(Brand.record.gradient)
                    .frame(width: 112, height: 112)
                    .shadow(color: Brand.record.opacity(0.6), radius: 24)
                if isPreparing {
                    ProgressView().tint(.white).controlSize(.large)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(isPreparing)
        .accessibilityLabel("Start recording")
        .sensoryFeedback(.impact(weight: .heavy), trigger: isPreparing)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: - Live

private struct LiveStage: View {
    @Environment(RecordingController.self) private var recorder
    let minimize: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleButton(symbol: "chevron.down", label: "Minimize", action: minimize)
                Spacer()
                Menu {
                    Button("Discard recording", systemImage: "trash", role: .destructive, action: discard)
                } label: {
                    HStack(spacing: 8) {
                        PulsingDot(active: recorder.phase == .recording, size: 8)
                        Text(recorder.phase == .paused ? "Paused" : "Recording")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Format.clock(recorder.elapsed(at: context.date)))
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(recorder.phase == .paused ? 0.5 : 1))
                    .contentTransition(.numericText())
            }
            .padding(.top, 20)
            .accessibilityLabel("Elapsed time")

            Text(recorder.displayTitle)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 32)

            LiveWaveform(levels: recorder.levels, paused: recorder.phase == .paused)
                .frame(height: 96)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

            LiveTranscriptPanel()
                .padding(.horizontal, 16)

            controls
                .padding(.top, 18)
                .padding(.bottom, 12)
        }
    }

    private var controls: some View {
        HStack(spacing: 34) {
            VStack(spacing: 6) {
                CircleButton(symbol: "bookmark.fill", label: "Mark this moment", size: 60) { recorder.markMoment() }
                    .frame(height: 84)
                Text(recorder.moments.isEmpty ? "Mark" : "\(recorder.moments.count) marked")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.numericText())
            }
            VStack(spacing: 6) {
                Button {
                    recorder.stop()
                } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.9), lineWidth: 4).frame(width: 84, height: 84)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Brand.record)
                            .frame(width: 34, height: 34)
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Stop and write notes")
                Text("Stop")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            VStack(spacing: 6) {
                CircleButton(
                    symbol: recorder.phase == .paused ? "play.fill" : "pause.fill",
                    label: recorder.phase == .paused ? "Resume" : "Pause",
                    size: 60
                ) {
                    recorder.phase == .paused ? recorder.resume() : recorder.pause()
                }
                .frame(height: 84)
                Text(recorder.phase == .paused ? "Resume" : "Pause")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

private struct LiveTranscriptPanel: View {
    @Environment(RecordingController.self) private var recorder

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if recorder.segments.isEmpty && recorder.volatileText.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white.opacity(0.7))
                            Text(recorder.transcriberNote ?? "Listening…")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.top, 4)
                    }
                    ForEach(Array(recorder.segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment.text)
                            .foregroundStyle(.white.opacity(index >= recorder.segments.count - 2 ? 0.95 : 0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if !recorder.volatileText.isEmpty {
                        Text(recorder.volatileText)
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let note = recorder.transcriberNote, !recorder.segments.isEmpty {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .font(.system(.title3, design: .default).weight(.medium))
                .lineSpacing(4)
                .padding(20)
                .animation(.smooth, value: recorder.segments.count)
            }
            .scrollIndicators(.hidden)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .onChange(of: recorder.segments.count) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: recorder.volatileText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 28, style: .continuous))
    }
}

/// Mirrored bars in the brand's mark gradient, newest on the right.
struct LiveWaveform: View {
    let levels: [Float]
    var paused: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let spacing: CGFloat = 3
            let width = (size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let mid = size.height / 2
            for (index, level) in levels.enumerated() {
                let amplitude = max(0.04, CGFloat(paused ? 0.04 : level))
                let height = max(width, size.height * amplitude)
                let x = CGFloat(index) * (width + spacing)
                let rect = CGRect(x: x, y: mid - height / 2, width: width, height: height)
                let fade = 0.35 + 0.65 * Double(index) / Double(count)
                context.opacity = fade
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .linearGradient(
                    Gradient(colors: [Brand.coral, Brand.rose, Brand.ivory]),
                    startPoint: CGPoint(x: 0, y: mid),
                    endPoint: CGPoint(x: size.width, y: mid)
                ))
            }
        }
        .animation(.linear(duration: 0.09), value: levels)
        .accessibilityHidden(true)
    }
}

/// Soft color that swells with the voice.
private struct AmbientGlow: View {
    let level: Double
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.coral.opacity(active ? 0.22 + level * 0.25 : 0.14))
                .frame(width: 360, height: 360)
                .blur(radius: 110)
                .offset(x: -110, y: -260)
            Circle()
                .fill(Color(hex: Brand.Hex.red).opacity(active ? 0.24 + level * 0.2 : 0.16))
                .frame(width: 380, height: 380)
                .blur(radius: 120)
                .offset(x: 140, y: 280)
        }
        .animation(.smooth(duration: 0.4), value: level)
        .allowsHitTesting(false)
    }
}

// MARK: - Processing

private struct ProcessingStage: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(MeetingProcessor.self) private var processor
    @Environment(Intelligence.self) private var intelligence
    let done: () -> Void
    let open: () -> Void

    private var progress: MeetingProcessor.Progress? {
        recorder.meetingID.flatMap { processor.progress[$0] }
    }

    private var phase: MeetingProcessor.Phase {
        recorder.phase == .finishing ? .waiting : (progress?.phase ?? .waiting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CircleButton(symbol: "xmark", label: "Close", action: done)
                Spacer()
                Label(intelligence.isOnDevice ? "On this iPhone" : "Cloud", systemImage: intelligence.isOnDevice ? "lock.fill" : "cloud")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(phase == .done ? "Your notes are ready" : "Writing your notes")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                Text("\(recorder.meeting?.displayTitle ?? recorder.displayTitle) · \(Format.duration(recorder.elapsed()))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.top, 28)

            StageStepper(phase: phase, wordCount: recorder.segments.reduce(0) { $0 + $1.text.split(separator: " ").count })
                .padding(.top, 24)

            ScrollView {
                Group {
                    if let text = progress?.text, !text.isEmpty {
                        NotesMarkdownView(markdown: text, hidesNextSteps: false)
                    } else if case .failed(let message) = phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        ShimmerLines()
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 28, style: .continuous))
            .padding(.top, 20)

            Button(action: open) {
                Text(phase == .done ? "Open notes" : "Open meeting")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(phase == .done ? Brand.red : .white.opacity(0.2))
            .padding(.top, 16)
            .padding(.bottom, 8)
            .sensoryFeedback(.success, trigger: phase == .done)
        }
        .padding(.horizontal, 20)
    }
}

private struct StageStepper: View {
    let phase: MeetingProcessor.Phase
    let wordCount: Int

    private enum StepState { case done, active, pending, failed }

    private var steps: [(title: String, detail: String, state: StepState)] {
        let failed: Bool = { if case .failed = phase { return true } else { return false } }()
        let notesState: StepState = {
            switch phase {
            case .waiting: return .pending
            case .condensing, .writing: return .active
            case .extracting, .done: return .done
            case .failed: return .failed
            }
        }()
        let itemsState: StepState = {
            switch phase {
            case .extracting: return .active
            case .done: return .done
            case .failed: return .failed
            default: return .pending
            }
        }()
        return [
            ("Saved", "Audio on this iPhone", .done),
            ("Transcript", "\(wordCount.formatted()) words", phase == .waiting && !failed ? .active : .done),
            ("Notes", phase == .writing || { if case .condensing = phase { return true } else { return false } }() ? phase.label : "Summary and decisions", notesState),
            ("Action items", "Who does what, by when", itemsState),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        icon(step.state)
                            .frame(width: 26, height: 26)
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(step.state == .done ? 0.5 : 0.15))
                                .frame(width: 2, height: 18)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(step.state == .pending ? 0.5 : 1))
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                }
            }
        }
        .animation(.smooth, value: phase)
    }

    @ViewBuilder
    private func icon(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Brand.crimson)
                .frame(width: 26, height: 26)
                .background(Brand.ivory, in: .circle)
                .transition(.scale.combined(with: .opacity))
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.12), in: .circle)
        case .pending:
            Circle()
                .strokeBorder(.white.opacity(0.3), lineWidth: 2)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.orange, in: .circle)
        }
    }
}

// MARK: - Pieces

private struct CircleButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}
