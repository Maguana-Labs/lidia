import LidIAKit
import SwiftUI

/// The hero: what's happening now or next, with the one action that matters.
struct NowNextCard: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(CalendarService.self) private var calendar
    @Environment(MeetingProcessor.self) private var processor
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .background(HeroBackground())
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .shadow(color: Brand.crimson.opacity(0.3), radius: 18, y: 10)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if recorder.isLive {
            liveContent(now: now)
        } else if recorder.phase == .processing || recorder.phase == .finishing, let id = recorder.meetingID {
            processingContent(id: id)
        } else if let event = calendar.next {
            eventContent(event, now: now)
        } else {
            idleContent
        }
    }

    // MARK: - States

    private func liveContent(now: Date) -> some View {
        HeroLayout(
            eyebrow: recorder.phase == .paused ? "Paused" : "Recording",
            eyebrowDot: recorder.phase == .recording,
            headline: Format.clock(recorder.elapsed(at: now)),
            detail: recorder.displayTitle,
            footnote: recorder.lastLine.isEmpty ? "Listening…" : "“\(recorder.lastLine)”",
            menu: {
                Button("Stop and write notes", systemImage: "stop.fill") { recorder.stop(); router.showRecorder = true }
                Button("Mark this moment", systemImage: "bookmark") { recorder.markMoment() }
            }
        ) {
            Button {
                recorder.phase == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Label(recorder.phase == .paused ? "Resume" : "Pause", systemImage: recorder.phase == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(HeroPillStyle(prominent: true))
            Button {
                router.showRecorder = true
            } label: {
                Label("Open", systemImage: "waveform")
            }
            .buttonStyle(HeroPillStyle(prominent: false))
        }
    }

    private func processingContent(id: UUID) -> some View {
        let progress = processor.progress[id]
        return HeroLayout(
            eyebrow: "Just recorded",
            headline: progress?.phase == .done ? "Notes ready" : "Writing notes",
            detail: recorder.displayTitle,
            footnote: progress?.phase.label ?? "Getting ready",
            menu: { EmptyView() }
        ) {
            Button {
                router.showRecorder = true
            } label: {
                Label("Watch", systemImage: "sparkles")
            }
            .buttonStyle(HeroPillStyle(prominent: true))
        }
    }

    private func eventContent(_ event: UpcomingEvent, now: Date) -> some View {
        let isNow = event.start <= now
        let names = event.attendees.map(Format.displayName)
        return HeroLayout(
            eyebrow: isNow ? "Happening now" : "Next meeting",
            eyebrowDot: false,
            headline: isNow ? "Now" : Format.countdown(to: event.start, now: now).replacingOccurrences(of: "in ", with: ""),
            headlinePrefix: isNow ? nil : "in",
            detail: event.title,
            footnote: "\(Format.time(event.start)) – \(Format.time(event.end))" + (names.isEmpty ? "" : " · " + names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " +\(names.count - 2)" : "")),
            attendees: names,
            menu: {
                if let url = event.joinURL {
                    Button("Join without recording", systemImage: "video") { openURL(url) }
                }
                Button("Open Calendar", systemImage: "calendar") {
                    if let url = URL(string: "calshow:\(event.start.timeIntervalSinceReferenceDate)") { openURL(url) }
                }
            }
        ) {
            Button {
                record(event, startNow: true)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(HeroPillStyle(prominent: true))
            if let url = event.joinURL {
                Button {
                    record(event, startNow: true)
                    openURL(url)
                } label: {
                    Label("Join & record", systemImage: "video.fill")
                }
                .buttonStyle(HeroPillStyle(prominent: false))
            } else {
                Button {
                    router.askSheet = .init(meetingID: nil, meetingTitle: event.title)
                } label: {
                    Label("Prep", systemImage: "sparkles")
                }
                .buttonStyle(HeroPillStyle(prominent: false))
            }
        }
    }

    private var idleContent: some View {
        HeroLayout(
            eyebrow: calendar.authorized ? "Nothing else today" : "Ready when you are",
            headline: "Record",
            detail: "Tap once. LidIA writes the notes.",
            footnote: "Transcribed on this iPhone, even with the screen locked.",
            menu: { EmptyView() }
        ) {
            Button {
                router.showRecorder = true
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(HeroPillStyle(prominent: true))
            if calendar.canAsk {
                Button {
                    Task { await calendar.requestAccess() }
                } label: {
                    Label("Connect calendar", systemImage: "calendar")
                }
                .buttonStyle(HeroPillStyle(prominent: false))
            } else {
                Button {
                    router.askSheet = .init()
                } label: {
                    Label("Ask", systemImage: "sparkles")
                }
                .buttonStyle(HeroPillStyle(prominent: false))
            }
        }
    }

    /// One tap: the hero's Record starts recording, named after the event.
    private func record(_ event: UpcomingEvent, startNow: Bool) {
        recorder.draft = .init(title: event.title, attendees: event.attendees, calendarEventID: event.id, joinURL: event.joinURL)
        router.showRecorder = true
        if startNow { Task { await recorder.start() } }
    }
}

// MARK: - Layout

private struct HeroLayout<Menu: View, Actions: View>: View {
    let eyebrow: String
    var eyebrowDot = false
    let headline: String
    var headlinePrefix: String?
    let detail: String
    let footnote: String
    var attendees: [String] = []
    let menu: Menu
    let actions: Actions

    init(
        eyebrow: String, eyebrowDot: Bool = false, headline: String, headlinePrefix: String? = nil,
        detail: String, footnote: String, attendees: [String] = [],
        @ViewBuilder menu: () -> Menu, @ViewBuilder actions: () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.eyebrowDot = eyebrowDot
        self.headline = headline
        self.headlinePrefix = headlinePrefix
        self.detail = detail
        self.footnote = footnote
        self.attendees = attendees
        self.menu = menu()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 7) {
                    if eyebrowDot { PulsingDot(active: true, size: 8, color: Brand.ivory) }
                    Text(eyebrow)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ivory.opacity(0.94))
                }
                Spacer()
                if Menu.self != EmptyView.self {
                    SwiftUI.Menu {
                        menu
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Brand.ivory)
                            .frame(width: 34, height: 34)
                            .background(Brand.ivory.opacity(0.16), in: .circle)
                    }
                    .accessibilityLabel("More")
                }
            }
            .frame(minHeight: 34)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let headlinePrefix {
                    Text(headlinePrefix)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Brand.ivory.opacity(0.82))
                }
                Text(headline)
                    .font(.system(size: 50, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Brand.ivory)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.top, 10)

            Text(detail)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.ivory)
                .lineLimit(2)
                .padding(.top, 2)

            HStack(spacing: 8) {
                if !attendees.isEmpty {
                    AvatarStack(names: attendees, size: 22, ring: Brand.crimson, limit: 3)
                }
                Text(footnote)
                    .font(.subheadline)
                    .foregroundStyle(Brand.ivory.opacity(0.94))
                    .lineLimit(2)
            }
            .padding(.top, 8)

            HStack(spacing: 10) {
                actions
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The brand field, like the icon's glass: crimson into her red, a soft coral
/// glow where the light catches it, with the waveform mark drawn across it.
struct HeroBackground: View {
    var body: some View {
        ZStack {
            Brand.field
            Circle()
                .fill(Brand.coral.opacity(0.42))
                .frame(width: 220, height: 220)
                .blur(radius: 60)
                .offset(x: 140, y: -90)
            Circle()
                .fill(Brand.crimson.opacity(0.55))
                .frame(width: 200, height: 200)
                .blur(radius: 70)
                .offset(x: -120, y: 120)
            GeometryReader { proxy in
                WaveMark(amplitude: 0.3)
                    .stroke(Brand.mark, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .opacity(0.45)
                    .frame(width: proxy.size.width * 0.55, height: 70)
                    .position(x: proxy.size.width * 0.8, y: 92)
            }
        }
        .accessibilityHidden(true)
    }
}
