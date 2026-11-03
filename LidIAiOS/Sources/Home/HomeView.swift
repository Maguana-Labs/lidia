import LidIAKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @Environment(SyncCoordinator.self) private var sync
    @Environment(CalendarService.self) private var calendar
    @Environment(\.modelContext) private var context

    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted }) private var openItems: [ActionItem]

    private var recent: [Meeting] {
        Array(meetings.filter { $0.status != .recording && $0.date <= .now }.prefix(4))
    }

    private var topItems: [ActionItem] {
        Array(openItems.sorted { lhs, rhs in
            if lhs.due != rhs.due { return lhs.due < rhs.due }
            return (lhs.deadlineDate ?? .distantFuture) < (rhs.deadlineDate ?? .distantFuture)
        }.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                greeting
                NowNextCard()
                ForYouSection(meetings: meetings, openItems: openItems)
                recentSection
                actionsSection
                privacyFooter
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Surface.background)
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .refreshable {
            calendar.refresh()
            await sync.syncNow()
        }
    }

    // MARK: - Header

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(greetingText)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return settings.firstName.isEmpty ? part : "\(part), \(settings.firstName)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                router.showSettings = true
            } label: {
                PersonAvatar(name: settings.displayName.isEmpty ? "Me" : settings.displayName, size: 32)
            }
            .accessibilityLabel("Settings")
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                router.askSheet = .init()
            } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel("Ask LidIA")
            Button {
                router.tab = .meetings
                router.meetingsSearchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search meetings")
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Haptics.firm()
                router.showRecorder = true
            } label: {
                Image(systemName: "mic.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.record)
            .accessibilityLabel("Record a meeting")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent meetings", actionTitle: recent.isEmpty ? nil : "See all") {
                router.tab = .meetings
            }
            Card {
                if recent.isEmpty {
                    CardEmptyState(
                        symbol: "waveform",
                        title: "No meetings yet",
                        message: "Record one here, or turn on sync to see the meetings from your Mac."
                    )
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, meeting in
                        Button {
                            router.open(meeting.id)
                        } label: {
                            MeetingRow(meeting: meeting)
                        }
                        .buttonStyle(PressableStyle())
                        if index < recent.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Action items",
                subtitle: openItems.isEmpty ? nil : "\(openItems.count) open",
                actionTitle: openItems.isEmpty ? nil : "See all"
            ) {
                router.tab = .actions
            }
            Card {
                if topItems.isEmpty {
                    CardEmptyState(symbol: "checkmark.circle", title: "All clear", message: "Commitments from your meetings show up here.")
                } else {
                    ForEach(Array(topItems.enumerated()), id: \.element.id) { index, item in
                        ActionItemRow(item: item) {
                            ActionItemActions.toggle(item, context: context, toasts: toasts, sync: sync)
                        }
                        .onTapGesture { router.actionItemDetail = .init(id: item.id) }
                        if index < topItems.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }

    private var privacyFooter: some View {
        Label("Transcribed and summarised on this iPhone", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}
