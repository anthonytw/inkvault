import Foundation
import Sempere

/// "Recently Recognized" (notes "Recognize All Notes" read in the last 7
/// days) and recent searches, remembered per vault on this device
/// (`RecentActivity`, sealed under the vault secret).
extension AppModel {
    /// Reads what this device remembers of the open, unlocked vault.
    func loadActivity() {
        guard let vault, vault.canRead else { return }
        activity = RecentActivity.load(root: activityRoot, vault: vault, now: activityNow())
    }

    /// Stores `activity` for the open vault.
    func saveActivity() {
        guard let vault, vault.canRead else { return }
        activity.save(root: activityRoot, vault: vault)
    }

    /// Live notes recognised in the last 7 days, newest first: the sidebar
    /// shows "Recently Recognized" only while there are some.
    var recentlyRecognizedNotes: [NoteSummary] {
        let byID = Dictionary(notes.filter { !$0.deleted }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return activity.recognized.recent(now: activityNow()).compactMap { byID[$0.id] }
    }

    /// What "Recognize All" read in note `id`, while it is recent.
    func recognizedEntry(for id: UUID) -> RecognizedEntry? {
        activity.recognized.entry(for: id, now: activityNow())
    }

    /// Remembers notes a run just recognised.
    func recordRecognized(_ notes: [RecognizedNote]) {
        guard !notes.isEmpty else { return }
        activity.recognized.record(notes, at: activityNow())
        saveActivity()
    }

    /// Leaves "Recently Recognized" for All Notes once it has nothing to show
    /// (the sidebar row is gone).
    func leaveEmptyRecognizedSection() {
        if sidebarSelection == .recentlyRecognized, recentlyRecognizedNotes.isEmpty { sidebarSelection = .allNotes }
    }

    // MARK: - Recent searches

    /// The recent searches, newest first.
    var recentSearches: [String] { activity.searches.queries }

    /// Remembers the current query (submitted, or a hit opened from it).
    func recordSearch() {
        let before = activity.searches
        activity.searches.record(searchText)
        if activity.searches != before { saveActivity() }
    }

    /// Searches `query` again.
    func rerunSearch(_ query: String) {
        searchText = query
        recordSearch()
    }

    /// Forgets the recent searches ("Clear").
    func clearRecentSearches() {
        activity.searches.clear()
        saveActivity()
    }
}
