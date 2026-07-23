enum StableSessionSelection {
    static func resolvedName(
        selectedName: String?,
        oldOrder: [String],
        newOrder: [String]
    ) -> String? {
        guard !newOrder.isEmpty else { return nil }
        if let selectedName, newOrder.contains(selectedName) { return selectedName }
        let previousIndex = selectedName.flatMap { oldOrder.firstIndex(of: $0) } ?? 0
        return newOrder[min(previousIndex, newOrder.count - 1)]
    }
}
