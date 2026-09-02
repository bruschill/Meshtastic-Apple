import SwiftUI
import UIKit

enum MigrationBootstrapState: Equatable {
	case migrating
	case failed(String)

	var accessibilityAnnouncement: String {
		switch self {
		case .migrating:
			String(localized: "Updating local data. This may take a minute. Keep Meshtastic open.")
		case .failed:
			String(localized: "Local data update failed. Retry is available.")
		}
	}
}

struct MigrationBootstrapView: View {
	let state: MigrationBootstrapState
	let retry: () -> Void

	var body: some View {
		ZStack {
			Color(.systemBackground)
				.ignoresSafeArea()

			VStack {
				switch state {
				case .migrating:
					Image(systemName: "arrow.triangle.2.circlepath")
						.font(.title2)
						.foregroundStyle(.secondary)
						.accessibilityHidden(true)
					Text("Updating local data…")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
						.accessibilityIdentifier("migration-bootstrap-title")
					Text("This may take a minute. Keep Meshtastic open.")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.accessibilityLabel("This may take a minute. Keep Meshtastic open while local data is updated")
						.accessibilityIdentifier("migration-bootstrap-instruction")
				case .failed(let message):
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
						.accessibilityHidden(true)
					Text("Local data update failed")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
						.accessibilityIdentifier("migration-bootstrap-title")
					Text(message)
						.font(.footnote)
						.multilineTextAlignment(.center)
					Button("Retry", action: retry)
						.buttonStyle(.borderedProminent)
						.accessibilityIdentifier("migration-bootstrap-retry")
				}
			}
			.padding()
		}
		.onChange(of: state) { _, newState in
			guard UIAccessibility.isVoiceOverRunning else { return }
			UIAccessibility.post(
				notification: .announcement,
				argument: newState.accessibilityAnnouncement
			)
		}
	}
}
