import SwiftUI
import SwiftData

struct PeopleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @State private var relationshipStore = RelationshipStore()
    @State private var profiles: [RelationshipStore.PersonProfile] = []
    @State private var companies: [Company] = []
    @State private var hoveredPersonID: String?
    @State private var showCompanies = true
    @Binding var selectedMeeting: Meeting?

    private var favoriteProfiles: [RelationshipStore.PersonProfile] {
        profiles.filter { settings.favoritePersonIDs.contains($0.id) }
    }

    private var everyoneProfiles: [RelationshipStore.PersonProfile] {
        profiles.filter { !settings.favoritePersonIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "No People Yet",
                    systemImage: "person.2",
                    description: Text("Everyone you meet shows up here, grouped by company, once a meeting has attendees from your calendar or an import.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !companies.isEmpty {
                        Section("Companies") {
                            ForEach(companies) { company in
                                DisclosureGroup {
                                    ForEach(companyAttendeeProfiles(for: company), id: \.id) { profile in
                                        NavigationLink(value: profile.id) {
                                            PersonRow(profile: profile, isFavorite: settings.favoritePersonIDs.contains(profile.id)) {
                                                toggleFavorite(profile.id)
                                            }
                                        }
                                    }
                                    if companyAttendeeProfiles(for: company).isEmpty {
                                        Text("No profiles found for this company")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } label: {
                                    CompanyRow(company: company)
                                }
                            }
                        }
                    }

                    if !favoriteProfiles.isEmpty {
                        Section("Favorites") {
                            ForEach(favoriteProfiles) { profile in
                                NavigationLink(value: profile.id) {
                                    PersonRow(profile: profile, isFavorite: true) {
                                        toggleFavorite(profile.id)
                                    }
                                }
                                .background {
                                    if hoveredPersonID == profile.id {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(.clear)
                                            .glassEffect(.regular, in: .rect(cornerRadius: 8))
                                    }
                                }
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        hoveredPersonID = hovering ? profile.id : nil
                                    }
                                }
                            }
                        }
                    }

                    Section("Everyone") {
                        ForEach(everyoneProfiles) { profile in
                            NavigationLink(value: profile.id) {
                                PersonRow(profile: profile, isFavorite: false) {
                                    toggleFavorite(profile.id)
                                }
                            }
                            .background {
                                if hoveredPersonID == profile.id {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.clear)
                                        .glassEffect(.regular, in: .rect(cornerRadius: 8))
                                }
                            }
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    hoveredPersonID = hovering ? profile.id : nil
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .navigationDestination(for: String.self) { profileID in
                    if let profile = profiles.first(where: { $0.id == profileID }) {
                        PersonDetailView(
                            profile: profile,
                            selectedMeeting: $selectedMeeting
                        )
                    }
                }
            }
        }
        .onAppear { refresh() }
        // Rebuild after any save (this window, sync, MCP inbox, voice) so the
        // profiles never point at deleted meetings or action items.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { _ in
            refresh()
        }
        .navigationTitle("People")
    }

    private func refresh() {
        profiles = relationshipStore.buildProfiles(modelContext: modelContext, currentUserName: settings.displayName)

        // Build companies from all meetings
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let allMeetings = (try? modelContext.fetch(descriptor)) ?? []
        companies = relationshipStore.companies(from: allMeetings, currentUserName: settings.displayName)
    }

    private func companyAttendeeProfiles(for company: Company) -> [RelationshipStore.PersonProfile] {
        profiles.filter { profile in
            if let email = profile.email {
                return company.attendeeEmails.contains(email)
            }
            return false
        }
    }

    private func toggleFavorite(_ id: String) {
        if settings.favoritePersonIDs.contains(id) {
            settings.favoritePersonIDs.remove(id)
        } else {
            settings.favoritePersonIDs.insert(id)
        }
    }
}

// MARK: - Company Row

private struct CompanyRow: View {
    let company: Company

    var body: some View {
        HStack(spacing: 12) {
            // Local monogram by default; never sends company domains to a favicon proxy.
            CompanyLogoView(domain: company.domain, name: company.name)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(company.name)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if company.openActionItems > 0 {
                Text("\(company.openActionItems) open")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [
            "\(company.attendeeEmails.count) \(company.attendeeEmails.count == 1 ? "person" : "people")",
            "\(company.meetingCount) meeting\(company.meetingCount == 1 ? "" : "s")",
        ]
        if let last = company.lastMeetingDate { parts.append("last met \(MeetingRowFormat.relativeDay(last, timeForToday: false))") }
        return parts.joined(separator: " · ")
    }
}
