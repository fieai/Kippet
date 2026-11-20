enum ShelfGuideLaunch: Equatable, Sendable {
    case skip, markCompleted, show

    init(isCompleted: Bool, hasHistory: Bool) {
        if isCompleted {
            self = .skip
        } else {
            self = hasHistory ? .markCompleted : .show
        }
    }
}
