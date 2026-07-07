//
//  SearchIndexBackfiller.swift
//  Meshtastic
//
//  Populates UserEntity.searchIndex for rows created before the denormalized search index existed.
//

import Foundation
import SwiftData
import OSLog

/// One-time migration that fills in `UserEntity.searchIndex` for rows persisted before the column
/// existed. The additive lightweight migration lands those rows with the default `""`, which would
/// make them invisible to the node-list search (which now pushes a `searchIndex.contains(term)`
/// predicate into SQLite). New writes keep the index current via `updateSearchIndex()` at each write
/// site; this actor closes the gap for the pre-existing back catalog so those nodes are searchable
/// without waiting to be re-heard over the mesh.
///
/// Runs off the main actor on its own `ModelContext`, paging through users so a large store never
/// blocks a save behind one giant transaction. Idempotent: it only touches rows whose index is still
/// empty, and a populated index is never `""` (`makeSearchIndex` always includes `String(num)`).
@ModelActor
actor SearchIndexBackfiller {

	/// UserDefaults marker so the sweep runs at most once per install (until a perf-seed reset clears
	/// it). Internal bookkeeping, not a user-facing setting, so it lives outside `UserDefaults.Keys`.
	static let didBackfillDefaultsKey = "nodeSearchIndexBackfilledV1"

	/// Launches the backfill in the background if it hasn't completed yet. Safe to call on every
	/// launch — a no-op once the marker is set. Skips under XCTest so unit tests keep a clean store.
	static func backfillIfNeeded(container: ModelContainer) {
		guard NSClassFromString("XCTestCase") == nil,
			  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
		guard !UserDefaults.standard.bool(forKey: didBackfillDefaultsKey) else { return }

		Task.detached(priority: .utility) {
			let backfiller = SearchIndexBackfiller(modelContainer: container)
			do {
				let updated = try await backfiller.backfill()
				// Only mark complete on success; a thrown fetch/save leaves the marker unset so the
				// next launch retries rather than silently leaving rows unsearchable.
				UserDefaults.standard.set(true, forKey: didBackfillDefaultsKey)
				Logger.data.info("🔎 [SearchIndexBackfill] Completed — indexed \(updated, privacy: .public) user(s)")
			} catch {
				Logger.data.error("🔎 [SearchIndexBackfill] Failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	/// Clears the completion marker so the next launch re-runs the backfill. Call after wiping the
	/// store (e.g. a perf-seed reset) so a fresh store is swept again instead of being skipped.
	static func resetCompletionMarker() {
		UserDefaults.standard.removeObject(forKey: didBackfillDefaultsKey)
	}

	/// Computes `searchIndex` for every `UserEntity` that still has the empty default, in batches.
	/// Returns the number of rows updated.
	///
	/// Each iteration uses a fresh, short-lived `ModelContext` to fetch up to `batchSize` rows that
	/// *currently* match `searchIndex == ""`, indexes them, and saves. Driving off the predicate (rather
	/// than a fixed `fetchOffset`) means concurrent inserts/deletes by the live mesh writer can't shift
	/// a window and skip an un-indexed row, and the loop terminates naturally once no empty rows remain
	/// — `updateSearchIndex()` always yields a non-empty string (`String(num)` is always included), so
	/// an indexed row can never re-match the predicate and loop forever. Discarding each batch's context
	/// releases its fetched objects, so peak memory stays flat regardless of store size.
	///
	/// Residual: a row the live writer indexes between this fetch and save could be re-written here from
	/// a slightly stale snapshot; that self-heals on the node's next write (`updateSearchIndex()` at the
	/// write site / the `savePendingChanges` sweep), and the window is small since this runs once at
	/// launch.
	func backfill(batchSize: Int = 500) throws -> Int {
		var totalUpdated = 0
		while true {
			let context = ModelContext(modelContainer)
			var descriptor = FetchDescriptor<UserEntity>(predicate: #Predicate { $0.searchIndex == "" })
			descriptor.fetchLimit = batchSize
			let batch = try context.fetch(descriptor)
			if batch.isEmpty { break }

			for user in batch {
				user.updateSearchIndex()
				totalUpdated += 1
			}
			try context.save()
		}
		return totalUpdated
	}
}
