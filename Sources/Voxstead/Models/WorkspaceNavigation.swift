import Foundation

enum WorkspaceDestination: Hashable {
    case home, practice, libraryAssistant, actionItems, coach
    case session(UUID)
}

enum NavigationDirection {
    case backward, forward
}

enum SessionSection: String, CaseIterable {
    case transcript = "Transcript"
    case debrief = "Debrief"
    case assistant = "Assistant"
}

struct WorkspaceNavigation {
    private var trail: [WorkspaceDestination]
    private var index = 0

    init(_ destination: WorkspaceDestination = .home) {
        trail = [destination]
    }

    var destination: WorkspaceDestination { trail[index] }

    mutating func visit(_ next: WorkspaceDestination) {
        guard next != destination else { return }
        trail.removeSubrange((index + 1)..<trail.count)
        trail.append(next)
        index = trail.count - 1
    }

    func target(_ direction: NavigationDirection, keeping isAvailable: (WorkspaceDestination) -> Bool) -> Int? {
        let eligible: (Int) -> Bool = { trail[$0] != destination && isAvailable(trail[$0]) }
        switch direction {
        case .backward: return trail.indices.prefix(index).last(where: eligible)
        case .forward: return trail.indices.dropFirst(index + 1).first(where: eligible)
        }
    }

    mutating func move(to target: Int) { index = target }
}
