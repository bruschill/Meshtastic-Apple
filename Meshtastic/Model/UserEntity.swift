//
//  UserEntity.swift
//  Meshtastic
//
//  SwiftData model for user information.
//

import Foundation
import SwiftData

@Model
final class UserEntity {
	// Note: no `#Index` on `searchIndex` — `#Index` requires iOS 18 (app targets iOS 17), and a B-tree
	// index cannot serve a leading-wildcard `LIKE '%term%'` substring search anyway. The win is the
	// denormalized column + predicate pushdown, not an index.

	var hwDisplayName: String?
	var hwModel: String?
	var hwModelId: Int32 = 0
	var isLicensed: Bool = false
	var keyMatch: Bool = true
	var lastMessage: Date?
	var longName: String?
	var mute: Bool = false
	var newPublicKey: Data?
	@Attribute(.unique) var num: Int64 = 0
	var numString: String?
	var pkiEncrypted: Bool = false
	var publicKey: Data?
	var role: Int32 = 0
	/// Lowercased, separator-joined concatenation of the node's searchable fields (userId, num,
	/// hwModel, hwDisplayName, longName, shortName). Denormalized so the node-list search can push a
	/// single `searchIndex.contains(term)` into a SwiftData `#Predicate` (SQLite `LIKE`) instead of
	/// faulting every user's relationship and running per-field `localizedCaseInsensitiveContains` in
	/// Swift. Maintained by `updateSearchIndex()` at every user write site; backfilled once for
	/// pre-existing rows by `SearchIndexBackfiller`.
	var searchIndex: String = ""
	var shortName: String?
	var unmessagable: Bool = false
	var userId: String?

	@Relationship(inverse: \MessageEntity.fromUser)
	var sentMessages: [MessageEntity] = []

	@Relationship(inverse: \MessageEntity.toUser)
	var receivedMessages: [MessageEntity] = []

	var userNode: NodeInfoEntity?

	init() {}
}

extension UserEntity {
	/// The single definition of "searchable form", used by BOTH the stored `searchIndex` and the query
	/// term so they can never drift. Uses locale-independent `.lowercased()` (Unicode default case
	/// folding), NOT the old `localizedCaseInsensitiveContains`: a denormalized, persisted index must
	/// fold identically no matter the device locale at write time vs. search time, so it cannot be
	/// locale-sensitive. This matches the old case-insensitive, diacritic-sensitive behavior for
	/// effectively all input; it diverges only for locale-specific casing (e.g. Turkish dotted-`İ`),
	/// an acceptable trade for an index that stays valid across locale changes.
	static func normalizeForSearch(_ text: String) -> String {
		text.lowercased()
	}

	/// Builds the denormalized search string. `String(num)` is always included so decimal-number
	/// search works even on freshly-heard nodes whose `numString` isn't set yet. Fields are joined by
	/// a unit separator so a match can't span two fields.
	static func makeSearchIndex(
		num: Int64,
		userId: String?,
		numString: String?,
		hwModel: String?,
		hwDisplayName: String?,
		longName: String?,
		shortName: String?
	) -> String {
		normalizeForSearch(
			[userId, numString, String(num), hwModel, hwDisplayName, longName, shortName]
				.compactMap { $0 }
				.joined(separator: "\u{1F}")
		)
	}

	/// Recomputes `searchIndex` from this user's current fields. Call after the last searchable-field
	/// assignment in every write path. Touches only this entity's own stored properties, so it is safe
	/// on any context/actor.
	func updateSearchIndex() {
		searchIndex = Self.makeSearchIndex(
			num: num,
			userId: userId,
			numString: numString,
			hwModel: hwModel,
			hwDisplayName: hwDisplayName,
			longName: longName,
			shortName: shortName
		)
	}
}
