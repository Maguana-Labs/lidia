import AppKit
import Combine
import EventKit
import SwiftUI

struct CalendarsPane: View {
    @Bindable var settings: AppSettings
    @Environment(GoogleCalendarMonitor.self) private var googleCalendarMonitor
    @Environment(EventKitManager.self) private var eventKitManager
    @State private var isSigningIn = false
    @State private var isConnectingMacAccount = false
    @State private var calendarAccessDenied = false
    @State private var groups: [EventKitManager.CalendarGroup] = []
    @State private var authorization: EKAuthorizationStatus = .notDetermined

    private static let internetAccountsURL = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!
    private static let calendarPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    private static let googleBlue = Color(red: 0.26, green: 0.52, blue: 0.96)

    var body: some View {
        SettingsPage(pane: .calendars) {
            Section {
                MeetingReminderPicker(
                    settings: settings,
                    title: "Remind me before meetings",
                    detail: "One alert per meeting. More options in Notifications."
                )
                .settingsAnchor(.calendarReminder)
            }

            googleSection
            appleSection

            if !googleCalendarMonitor.isSignedIn && (!hasBundledGoogleClient || hasCustomGoogleClient) {
                SettingsAdvancedSection(pane: .calendars) {
                    LabeledContent {
                        TextField("Client ID", text: $settings.googleClientID)
                            .labelsHidden()
                            .frame(maxWidth: 260)
                    } label: {
                        Text("Google client ID")
                        Text("Only if you made your own Google Cloud desktop client.")
                    }
                    .settingsAnchor(.googleOAuth)
                    LabeledContent("Google client secret") {
                        SecureField("Client secret", text: $settings.googleClientSecret)
                            .labelsHidden()
                            .frame(maxWidth: 260)
                    }
                    if hasCustomGoogleClient {
                        HStack {
                            Spacer()
                            signInWithGoogleButton
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: pick up a newly added account or permission.
            reload()
        }
        // EventKit posts this on a background queue; the handler is main-actor isolated
        // and traps there, so hop to the main queue first.
        .onReceive(
            NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)
        ) { _ in reload() }
        .onChange(of: settings.calendarEnabled) { _, _ in reload() }
        .onChange(of: settings.hiddenCalendarIDs) { _, _ in
            Task { await eventKitManager.refresh(settings: settings) }
            if googleCalendarMonitor.isSignedIn, settings.googleCalendarEnabled {
                googleCalendarMonitor.startPolling(settings: settings)
            }
        }
    }

    private func reload() {
        eventKitManager.refreshGoogleAccountStatus()
        authorization = eventKitManager.calendarAuthorizationStatus
        groups = eventKitManager.calendarGroups()
    }

    // MARK: - Google

    private var hasBundledGoogleClient: Bool { GoogleOAuthCredentials.hasBundledClient() }

    private var hasCustomGoogleClient: Bool {
        !settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var googleCalendarsViaMacOS: Int { eventKitManager.googleCalendarCountViaMacOS }

    private var isConnectedThroughMacOS: Bool {
        settings.calendarEnabled && googleCalendarsViaMacOS > 0
    }

    @ViewBuilder
    private var googleSection: some View {
        Section {
            if googleCalendarMonitor.isSignedIn {
                LabeledContent {
                    Button("Sign Out") {
                        Task { await googleCalendarMonitor.signOut() }
                    }
                } label: {
                    Text("Google account")
                    Text("Signed in. LidIA reads your events and never changes them.")
                }
                .settingsAnchor(.googleCalendar)

                calendarToggle(
                    title: "Primary calendar",
                    color: Self.googleBlue,
                    isOn: Binding(
                        get: {
                            settings.googleCalendarEnabled
                                && CalendarVisibility.isVisible(CalendarVisibility.googlePrimaryID, hidden: settings.hiddenCalendarIDs)
                        },
                        set: { on in
                            settings.hiddenCalendarIDs = CalendarVisibility.setting(
                                CalendarVisibility.googlePrimaryID, visible: on, in: settings.hiddenCalendarIDs
                            )
                            if on, !settings.googleCalendarEnabled {
                                settings.googleCalendarEnabled = true
                                googleCalendarMonitor.startPolling(settings: settings)
                            }
                        }
                    )
                )
            } else if isConnectedThroughMacOS {
                LabeledContent {
                    Button("Manage") { NSWorkspace.shared.open(Self.internetAccountsURL) }
                } label: {
                    Text("Google Calendar")
                    Text(Self.macOSConnectedText(calendarCount: googleCalendarsViaMacOS))
                }
                .settingsAnchor(.googleCalendar)
            } else if hasBundledGoogleClient {
                LabeledContent {
                    signInWithGoogleButton
                } label: {
                    Text("Google Calendar")
                    Text("Sign in to see your Google meetings. Read-only.")
                }
                .settingsAnchor(.googleCalendar)
            } else {
                LabeledContent {
                    useMacAccountButton
                } label: {
                    Text("Google Calendar")
                    if calendarAccessDenied {
                        Text("LidIA can't see your calendars yet. Allow it in Privacy & Security.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Add Google in System Settings › Internet Accounts. LidIA reads it through Apple Calendar.")
                    }
                }
                .settingsAnchor(.googleCalendar)
            }

            if let error = googleCalendarMonitor.error {
                InlineNote(text: error, kind: .error)
            }
        } header: {
            Text("Google")
        }
    }

    private var signInWithGoogleButton: some View {
        Button {
            isSigningIn = true
            Task {
                googleCalendarMonitor.configure(settings: settings)
                await googleCalendarMonitor.signIn(settings: settings)
                isSigningIn = false
            }
        } label: {
            if isSigningIn {
                ProgressView().controlSize(.small)
            } else {
                Text("Sign in with Google")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSigningIn)
    }

    private var useMacAccountButton: some View {
        Button {
            connectMacGoogleAccount()
        } label: {
            if isConnectingMacAccount {
                ProgressView().controlSize(.small)
            } else {
                Text(calendarAccessDenied ? "Open Privacy Settings" : "Use the Google Account on This Mac")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isConnectingMacAccount)
    }

    static func macOSConnectedText(calendarCount: Int) -> String {
        let noun = calendarCount == 1 ? "calendar" : "calendars"
        return "Google Calendar connected through macOS (\(calendarCount) \(noun))"
    }

    /// Turns on Apple Calendar, asks for calendar access the same way polling
    /// does, then opens Internet Accounts if no Google calendar shows up yet.
    private func connectMacGoogleAccount() {
        if calendarAccessDenied {
            NSWorkspace.shared.open(Self.calendarPrivacyURL)
            return
        }
        isConnectingMacAccount = true
        settings.calendarEnabled = true
        Task {
            if !eventKitManager.calendarAccessGranted {
                await eventKitManager.requestCalendarAccess()
            }
            eventKitManager.refreshGoogleAccountStatus()
            calendarAccessDenied = EKEventStore.authorizationStatus(for: .event) != .fullAccess
            if calendarAccessDenied {
                NSWorkspace.shared.open(Self.calendarPrivacyURL)
            } else if eventKitManager.googleCalendarCountViaMacOS == 0 {
                NSWorkspace.shared.open(Self.internetAccountsURL)
            }
            reload()
            isConnectingMacAccount = false
        }
    }

    // MARK: - Apple Calendar

    @ViewBuilder
    private var appleSection: some View {
        Section {
            Toggle(isOn: $settings.calendarEnabled) {
                Text("Use Apple Calendar")
                Text("iCloud, Exchange and every account added to this Mac.")
            }
            .settingsAnchor(.appleCalendar)

            if settings.calendarEnabled && authorization != .fullAccess {
                LabeledContent {
                    Button(authorization == .notDetermined ? "Allow Access" : "Open Privacy Settings") {
                        requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                } label: {
                    Text("Calendar access not granted")
                    Text("LidIA needs permission to read your calendars.")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("This Mac")
        } footer: {
            if settings.calendarEnabled && authorization == .fullAccess {
                HStack {
                    Spacer()
                    Button("Manage in Calendar \u{2197}") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                    }
                    .buttonStyle(.accentLink)
                }
            }
        }

        if settings.calendarEnabled && authorization == .fullAccess {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.calendars) { calendar in
                        calendarToggle(
                            title: calendar.title,
                            color: calendar.color.map { Color(cgColor: $0) } ?? .secondary,
                            isOn: Binding(
                                get: { CalendarVisibility.isVisible(calendar.id, hidden: settings.hiddenCalendarIDs) },
                                set: { on in
                                    settings.hiddenCalendarIDs = CalendarVisibility.setting(
                                        calendar.id, visible: on, in: settings.hiddenCalendarIDs
                                    )
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    private func requestAccess() {
        if authorization == .notDetermined {
            Task {
                await eventKitManager.requestCalendarAccess()
                reload()
                if eventKitManager.calendarAccessGranted {
                    eventKitManager.startPolling(settings: settings)
                }
            }
        } else {
            NSWorkspace.shared.open(Self.calendarPrivacyURL)
        }
    }

    private func calendarToggle(title: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(title)
            }
        }
        .accessibilityLabel(title)
    }
}
