import os
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class GoogleCalendarMonitor {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "GoogleCalendarMonitor")
    /// Enough for a busy week of daily recurring meetings across calendars
    /// (Coming up lists every one); 50 cut weeks short.
    static let weekEventLimit = 250

    var upcomingEvents: [GoogleCalendarClient.CalendarEvent] = []
    var weekEvents: [GoogleCalendarClient.CalendarEvent] = []
    var isSignedIn = false
    var isLoading = false
    var error: String?

    private var pollTask: Task<Void, Never>?
    private var oauth: GoogleOAuth?
    private var eventColors: [String: String] = [:]
    /// Read for the calendars switched off in Settings › Calendars.
    private weak var settings: AppSettings?

    private var hiddenCalendarIDs: [String] { settings?.hiddenCalendarIDs ?? [] }

    /// Sets up the OAuth client: the one from Settings → Advanced if the user
    /// entered one, else the one bundled in Info.plist. Call at app startup and
    /// before signing in.
    func configure(settings: AppSettings) {
        self.settings = settings
        guard let credentials = GoogleOAuthCredentials.resolve(settings: settings) else {
            oauth = nil
            return
        }
        let oauth = GoogleOAuth(credentials: credentials)
        self.oauth = oauth

        Task {
            self.isSignedIn = await oauth.isSignedIn
            if self.isSignedIn {
                startPolling(settings: settings)
            }
        }
    }

    /// Sign in via browser OAuth flow
    func signIn(settings: AppSettings) async {
        guard let oauth else {
            error = "Google sign-in isn't available in this build."
            return
        }
        do {
            try await oauth.authorize()
            isSignedIn = await oauth.isSignedIn
            error = nil
            // Auto-enable after successful sign-in
            settings.googleCalendarEnabled = true
            startPolling(settings: settings)
        } catch {
            self.error = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    /// Sign out and clear tokens
    func signOut() async {
        stopPolling()
        if let oauth {
            await oauth.signOut()
        }
        isSignedIn = false
        upcomingEvents = []
    }

    // MARK: - Polling

    func startPolling(settings: AppSettings) {
        stopPolling()
        self.settings = settings
        guard settings.googleCalendarEnabled,
              let oauth,
              isSignedIn else {
            Self.logger.debug("Polling not started: enabled=\(settings.googleCalendarEnabled), oauth=\(self.oauth != nil), signedIn=\(self.isSignedIn)")
            return
        }
        Self.logger.info("Starting polling")

        pollTask = Task {
            while !Task.isCancelled {
                await refresh(oauth: oauth, settings: settings)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func fetchWeek(containing date: Date) async {
        guard let oauth else { return }
        let calendar = Calendar.current
        // Find Monday of the week containing `date`
        let weekday = calendar.component(.weekday, from: date)
        let daysToMonday = (weekday == 1) ? -6 : (2 - weekday) // Sunday=1 → -6, Mon=2 → 0, etc.
        guard let monday = calendar.date(byAdding: .day, value: daysToMonday, to: calendar.startOfDay(for: date)),
              let fridayEnd = calendar.date(byAdding: .day, value: 5, to: monday) else { return }

        do {
            let client = GoogleCalendarClient(oauth: oauth)
            // Fetch colors if not cached yet
            if eventColors.isEmpty {
                eventColors = (try? await client.fetchEventColors()) ?? [:]
            }
            weekEvents = CalendarVisibility.visibleGoogleEvents(
                try await client.listEventsForDateRange(from: monday, to: fridayEnd, maxResults: Self.weekEventLimit, colorMap: eventColors),
                hidden: hiddenCalendarIDs
            )
            Self.logger.info("Fetched \(self.weekEvents.count) week events")
        } catch {
            Self.logger.error("Error fetching week: \(error)")
        }
    }

    private func refresh(oauth: GoogleOAuth, settings: AppSettings) async {
        isLoading = true
        error = nil
        do {
            let client = GoogleCalendarClient(oauth: oauth)
            // Fetch colors on first successful refresh
            if eventColors.isEmpty {
                eventColors = (try? await client.fetchEventColors()) ?? [:]
            }
            let hidden = settings.hiddenCalendarIDs
            upcomingEvents = CalendarVisibility.visibleGoogleEvents(
                try await client.listUpcomingEvents(maxResults: 10).filter { $0.end >= Date() },
                hidden: hidden
            )
            Self.logger.info("Fetched \(self.upcomingEvents.count) events")

            // Also refresh week events for the Home "Coming up" view
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            if let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) {
                weekEvents = CalendarVisibility.visibleGoogleEvents(
                    try await client.listEventsForDateRange(from: Date(), to: weekEnd, maxResults: Self.weekEventLimit, colorMap: eventColors),
                    hidden: hidden
                )
                Self.logger.info("Refreshed \(self.weekEvents.count) week events")
            }

            // Pre-meeting prompts are owned by ProactiveScheduler (deduped
            // against Apple Calendar, one prompt per meeting).
        } catch {
            Self.logger.error("Error fetching events: \(error)")
            self.error = error.localizedDescription
            // If refresh token is invalid, mark as signed out
            if let oauthError = error as? GoogleOAuth.OAuthError,
               case .noRefreshToken = oauthError {
                isSignedIn = false
            }
        }
        isLoading = false
    }
}
