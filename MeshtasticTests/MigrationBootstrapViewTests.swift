import Foundation
import Testing
@testable import Meshtastic

@Suite("Migration bootstrap view")
struct MigrationBootstrapViewTests {
	@Test("Migration states provide localized VoiceOver announcements")
	func accessibilityAnnouncements() {
		#expect(
			MigrationBootstrapState.migrating.accessibilityAnnouncement ==
				String(localized: "Updating local data. This may take a minute. Keep Meshtastic open.")
		)
		#expect(
			MigrationBootstrapState.failed("details").accessibilityAnnouncement ==
				String(localized: "Local data update failed. Retry is available.")
		)
	}
}
