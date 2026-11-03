import SwiftUI

// The chat components live in Views/Chat/. This file keeps small helpers
// other views share.

// MARK: - ChatHelpers

enum ChatHelpers {
    static func menuRow(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    static func scopeLabel(_ scope: ChatBarViewModel.ContextScope) -> String {
        switch scope {
        case .selectedMeeting: "Meeting"
        case .allMeetings: "All"
        case .myNotes: "Notes"
        }
    }
}
