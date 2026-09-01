//
//  CoreDataMigrationService.swift
//  Meshtastic
//
//  One-time migration from the legacy Core Data store (shipped in 2.7.12 and
//  earlier) into the SwiftData store.
//
//  PersistenceController prepares the store paths, creates the SwiftData container,
//  and runs this migration before publishing normal app content. After a successful
//  run the old store is renamed to `Meshtastic-coredata-backup.sqlite` so the
//  migration never runs again.
//
//  All user-owned V58 entities are copied. Device hardware, hardware-image,
//  hardware-tag, and firmware-release catalog rows are rebuildable caches and
//  are intentionally excluded.
//

import CoreData
import SwiftData
import OSLog
import SQLite3

@globalActor
private actor LegacyMigrationActor {
	static let shared = LegacyMigrationActor()
}

// MARK: - Public API

enum CoreDataMigrationService {

	struct StoreLocations: Sendable {
		let applicationSupportURL: URL

		var candidateStoreURL: URL {
			applicationSupportURL.appendingPathComponent("Meshtastic.sqlite")
		}

		var legacyStoreURL: URL {
			applicationSupportURL.appendingPathComponent("Meshtastic-coredata-legacy.sqlite")
		}

		var backupStoreURL: URL {
			applicationSupportURL.appendingPathComponent("Meshtastic-coredata-backup.sqlite")
		}

		var destinationStoreURL: URL {
			applicationSupportURL.appendingPathComponent("Meshtastic.store")
		}

		var retirementMarkerURL: URL {
			applicationSupportURL.appendingPathComponent("Meshtastic-coredata-retirement-in-progress")
		}

		var replayIndexURL: URL {
			applicationSupportURL.appendingPathComponent("Meshtastic-migration-replay-index.sqlite")
		}

		static var applicationSupport: StoreLocations {
			StoreLocations(
				applicationSupportURL: FileManager.default.urls(
					for: .applicationSupportDirectory,
					in: .userDomainMask
				)[0]
			)
		}
	}

	enum StoreMember: Sendable, Equatable {
		case wal
		case shm
		case main
	}

	enum HistoryKind: Sendable, Equatable {
		case messages
		case positions
		case telemetry
	}

	enum MigrationCheckpoint: Sendable, Equatable {
		case afterPrepareMove(StoreMember)
		case afterParentSave
		case afterHistoryBatch(HistoryKind, index: Int)
		case afterMessageScalarPersistence
		case afterMessageUserLink(nodeNum: Int64)
		case beforeRetirement
		case afterRetirementMove(StoreMember)
	}

	struct MigrationOptions: Sendable {
		var batchSize = 500
		var checkpoint: @Sendable (MigrationCheckpoint) throws -> Void = { _ in }
	}

	typealias MigrationExecutionProbe = @Sendable (Bool) async -> Void

	final class MergeState {
		var preexistingNodeNums = Set<Int64>()
		var preexistingMyInfoNums = Set<Int64>()
	}

	/// Renames the App-Store Core Data store out of the way so that SwiftData
	/// can create a fresh store at the same path without clobbering user data.
	///
	/// Must be called **before** the SwiftData `ModelContainer` is initialised.
	/// Safe to call on every launch — it is a no-op when:
	///   - The candidate file does not exist, or
	///   - The candidate file is not a Core Data store, or
	///   - The renamed legacy file already exists (rename already done).
	static func prepareForMigration(
		locations: StoreLocations = .applicationSupport,
		options: MigrationOptions = MigrationOptions()
	) throws {
		let fm = FileManager.default
		if fm.fileExists(atPath: locations.retirementMarkerURL.path),
		   fm.fileExists(atPath: locations.backupStoreURL.path),
		   !fm.fileExists(atPath: locations.legacyStoreURL.path) {
			try fm.removeItem(at: locations.retirementMarkerURL)
			try? ReplayIndex.removeStale(at: locations.replayIndexURL)
		}
		let candidateExists = fm.fileExists(atPath: locations.candidateStoreURL.path)
		let legacyExists = fm.fileExists(atPath: locations.legacyStoreURL.path)
		let transitionStarted = ["-wal", "-shm"].contains { suffix in
			fm.fileExists(atPath: sidecar(of: locations.legacyStoreURL, suffix: suffix).path)
		}
		guard candidateExists || legacyExists || transitionStarted else { return }

		if candidateExists, !legacyExists,
		   !isCoreDataStore(at: locations.candidateStoreURL) {
			guard !transitionStarted else {
				throw MigrationError.storeFamilyConflict(locations.candidateStoreURL.lastPathComponent)
			}
			return
		}
		if !candidateExists, !legacyExists, transitionStarted {
			throw MigrationError.storeFamilyConflict(locations.legacyStoreURL.lastPathComponent)
		}

		Logger.data.info("⬆️ CoreDataMigrationService: preserving Core Data store before SwiftData init")
		// Move the main file last. Until that succeeds, legacyStoreExists remains
		// false and startup cannot mistake an incomplete family for a migration source.
		let storeMembers: [(suffix: String, member: StoreMember)] = [
			("-wal", .wal),
			("-shm", .shm),
			("", .main)
		]
		for storeMember in storeMembers {
			let src = sidecar(of: locations.candidateStoreURL, suffix: storeMember.suffix)
			let dst = sidecar(of: locations.legacyStoreURL, suffix: storeMember.suffix)
			guard fm.fileExists(atPath: src.path) else { continue }
			if fm.fileExists(atPath: dst.path) {
				guard fm.contentsEqual(atPath: src.path, andPath: dst.path) else {
					throw MigrationError.storeFamilyConflict(dst.lastPathComponent)
				}
				try fm.removeItem(at: src)
			} else {
				try fm.moveItem(at: src, to: dst)
			}
			try options.checkpoint(.afterPrepareMove(storeMember.member))
		}
	}

	/// Returns `true` when a renamed legacy Core Data store exists and has not
	/// yet been migrated into SwiftData.
	static func legacyStoreExists(at locations: StoreLocations = .applicationSupport) -> Bool {
		FileManager.default.fileExists(atPath: locations.legacyStoreURL.path)
	}

	static func protectedStoreIsUnavailable(at locations: StoreLocations = .applicationSupport) -> Bool {
		[locations.candidateStoreURL, locations.legacyStoreURL].contains { url in
			FileManager.default.fileExists(atPath: url.path)
				&& !FileManager.default.isReadableFile(atPath: url.path)
		}
	}

	/// Performs the full Core Data → SwiftData migration.
	///
	/// - Parameter swiftDataContainer: The already-initialised SwiftData
	///   `ModelContainer` that data should be written into.
	/// - Throws: Any error encountered while reading Core Data or writing
	///   SwiftData.  The caller is responsible for surfacing this to the user
	///   rather than silently destroying data.
	@LegacyMigrationActor
	static func migrateOffMain(
		into swiftDataContainer: ModelContainer,
		locations: StoreLocations = .applicationSupport,
		options: MigrationOptions = MigrationOptions(),
		executionProbe: MigrationExecutionProbe? = nil
	) async throws {
		await executionProbe?(migrationExecutorIsMainThread())
		try migrate(into: swiftDataContainer, locations: locations, options: options)
	}

	@LegacyMigrationActor
	private static func migrationExecutorIsMainThread() -> Bool {
		Thread.isMainThread
	}

	@LegacyMigrationActor
	private static func migrate(
		into swiftDataContainer: ModelContainer,
		locations: StoreLocations = .applicationSupport,
		options: MigrationOptions = MigrationOptions()
	) throws {
		precondition(options.batchSize > 0)
		if FileManager.default.fileExists(atPath: locations.retirementMarkerURL.path) {
			Logger.data.notice("⬆️ [MIGRATION] resuming interrupted source retirement")
			try retireLegacyStore(at: locations, options: options)
			try? ReplayIndex.removeStale(at: locations.replayIndexURL)
			return
		}
		let migrationStartedAt = ContinuousClock.now
		Logger.data.notice("⬆️ [MIGRATION] migration begin")

		let state = MergeState()
		try withCoreDataContext(at: locations.legacyStoreURL) { cdContext in
			Logger.data.notice("⬆️ [MIGRATION] legacy store open: \(elapsedSeconds(since: migrationStartedAt), privacy: .public) seconds")
			let parentContext = ModelContext(swiftDataContainer)
			parentContext.autosaveEnabled = false

			// Commit parents, channels, and configs together. This keeps the rescue
			// decision stable if a later history batch is interrupted and retried.
			let nodeMap = try migrateNodes(cdContext: cdContext, sdContext: parentContext, state: state)
			_ = try migrateUsers(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap)
			let infoMap = try migrateMyInfos(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateChannels(cdContext: cdContext, sdContext: parentContext, infoMap: infoMap, state: state)
			try migrateAmbientLightingConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateBluetoothConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateCannedMessageConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateDetectionSensorConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateDeviceConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateDisplayConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateExternalNotifConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateLoRaConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateMQTTConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateNetworkConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migratePaxCounterConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migratePositionConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migratePowerConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateRangeTestConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateRTTTLConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateSecurityConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateSerialConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateStoreForwardConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateTAKConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateTelemetryConfigs(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migrateDeviceMetadata(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap, state: state)
			try migratePaxCounters(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap)
			try migrateRoutes(cdContext: cdContext, sdContext: parentContext)
			try migrateTraceRoutes(cdContext: cdContext, sdContext: parentContext, nodeMap: nodeMap)
			try migrateWaypoints(cdContext: cdContext, sdContext: parentContext)
			try parentContext.save()
			try options.checkpoint(.afterParentSave)
			Logger.data.notice("⬆️ [MIGRATION] parents saved: \(elapsedSeconds(since: migrationStartedAt), privacy: .public) seconds")
		}

		let replayIndex = try ReplayIndex(url: locations.replayIndexURL)
		defer { replayIndex.closeAndRemove() }
		try autoreleasepool {
			try withCoreDataContext(at: locations.legacyStoreURL) { cdContext in
				try migrateMessages(
					cdContext: cdContext,
					container: swiftDataContainer,
					replayIndex: replayIndex,
					options: options
				)
			}
		}
		try autoreleasepool {
			try withCoreDataContext(at: locations.legacyStoreURL) { cdContext in
				try migratePositions(
					cdContext: cdContext,
					container: swiftDataContainer,
					replayIndex: replayIndex,
					options: options
				)
			}
		}
		try autoreleasepool {
			try withCoreDataContext(at: locations.legacyStoreURL) { cdContext in
				try migrateTelemetry(
					cdContext: cdContext,
					container: swiftDataContainer,
					replayIndex: replayIndex,
					options: options
				)
			}
		}
		Logger.data.notice("⬆️ [MIGRATION] source store closed: \(elapsedSeconds(since: migrationStartedAt), privacy: .public) seconds")

		try options.checkpoint(.beforeRetirement)
		try retireLegacyStore(at: locations, options: options)
		Logger.data.notice("⬆️ [MIGRATION] migration complete: \(elapsedSeconds(since: migrationStartedAt), privacy: .public) seconds")
	}
}

// MARK: - Store inspection

private extension CoreDataMigrationService {

	static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
		let components = start.duration(to: .now).components
		return Double(components.seconds) + Double(components.attoseconds) / 1e18
	}

	static func withCoreDataContext<T>(
		at storeURL: URL,
		body: (NSManagedObjectContext) throws -> T
	) throws -> T {
		let container = try makeCoreDataContainer(at: storeURL)
		let context = container.newBackgroundContext()
		context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
		do {
			let result = try context.performAndWait {
				try body(context)
			}
			for store in container.persistentStoreCoordinator.persistentStores {
				try container.persistentStoreCoordinator.remove(store)
			}
			return result
		} catch {
			for store in container.persistentStoreCoordinator.persistentStores {
				try? container.persistentStoreCoordinator.remove(store)
			}
			throw error
		}
	}

	static func sidecar(of storeURL: URL, suffix: String) -> URL {
		storeURL.deletingPathExtension().appendingPathExtension("sqlite\(suffix)")
	}

	/// Returns `true` when the SQLite file at `url` is a Core Data store.
	///
	/// Uses `NSPersistentStoreCoordinator.metadataForPersistentStore` which is
	/// read-only — it does not modify the file.
	static func isCoreDataStore(at url: URL) -> Bool {
		guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
			ofType: NSSQLiteStoreType,
			at: url
		) else {
			// metadataForPersistentStore threw — the file exists but is not a
			// recognized SQLite/Core Data store (e.g. it is a SwiftData store
			// or a corrupt file).  Do not rename it.
			return false
		}
		// NSStoreModelVersionHashesKey is present in every Core Data store that
		// has been opened at least once with a versioned model.  Older stores
		// that predate model versioning may lack it, so fall back to checking
		// NSStoreTypeKey as a secondary signal.
		if metadata[NSStoreModelVersionHashesKey] != nil { return true }
		if let type = metadata[NSStoreTypeKey] as? String, type == NSSQLiteStoreType { return true }
		return false
	}
}

// MARK: - Core Data container bootstrap

private extension CoreDataMigrationService {

	/// Creates an `NSPersistentContainer` that opens the *existing* Core Data
	/// store using the bundled `.xcdatamodeld` model.  Automatic lightweight
	/// migration is enabled so any minor schema drift across device upgrades
	/// is handled transparently.
	static func makeCoreDataContainer(at legacyStoreURL: URL) throws -> NSPersistentContainer {
		guard let momdURL = Bundle.main.url(
			forResource: "Meshtastic",
			withExtension: "momd"
		) else {
			throw MigrationError.modelNotFound
		}

		// Load the V58 model directly by path inside the .momd bundle so this
		// is immune to Xcode resetting .xccurrentversion.  The 2.7.12 App Store
		// wrote stores with MeshtasticDataModelV 58.xcdatamodel — loading it by
		// explicit URL means migration always uses the correct schema regardless
		// of which version .xccurrentversion points to.
		let v58URL = momdURL.appendingPathComponent("MeshtasticDataModelV 58.mom")
		let modelURL: URL
		if FileManager.default.fileExists(atPath: v58URL.path) {
			modelURL = v58URL
		} else {
			// Fallback: let Core Data use whatever .xccurrentversion says.
			modelURL = momdURL
		}

		guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
			throw MigrationError.modelLoadFailed
		}

		let container = NSPersistentContainer(name: "Meshtastic", managedObjectModel: model)

		let storeDescription = NSPersistentStoreDescription(url: legacyStoreURL)
		storeDescription.shouldMigrateStoreAutomatically = true
		storeDescription.shouldInferMappingModelAutomatically = true
		container.persistentStoreDescriptions = [storeDescription]

		var loadError: Error?
		container.loadPersistentStores { _, error in
			loadError = error
		}
		if let loadError {
			throw loadError
		}
		return container
	}
}

// MARK: - Per-entity migration helpers

// Each function returns a dictionary mapping NSManagedObjectID → SwiftData
// entity so that relationships can be wired up in later phases.

private extension CoreDataMigrationService {

	// MARK: NodeInfoEntity

	static func migrateNodes(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		state: MergeState
	) throws -> [NSManagedObjectID: NodeInfoEntity] {
		let request = NSFetchRequest<NSManagedObject>(entityName: "NodeInfoEntity")
		let objects = try cdContext.fetch(request)
		var map = [NSManagedObjectID: NodeInfoEntity]()

		let existingByNum = Dictionary(
			(try sdContext.fetch(FetchDescriptor<NodeInfoEntity>())).map { ($0.num, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		var migrated = 0
		for obj in objects {
			let num = (obj.value(forKey: "num") as? Int64) ?? 0
			if let existing = existingByNum[num] {
				// Rescue merge: keep live values and fill fields the mesh did not re-teach.
				mergeMissingNodeFields(from: obj, into: existing)
				state.preexistingNodeNums.insert(num)
				map[obj.objectID] = existing
				continue
			}
			let sd = NodeInfoEntity()
			sd.bleName = obj.value(forKey: "bleName") as? String
			sd.channel = (obj.value(forKey: "channel") as? Int32) ?? 0
			sd.favorite = (obj.value(forKey: "favorite") as? Bool) ?? false
			sd.firstHeard = obj.value(forKey: "firstHeard") as? Date
			sd.hopsAway = (obj.value(forKey: "hopsAway") as? Int32) ?? 0
			sd.id = (obj.value(forKey: "id") as? Int64) ?? 0
			sd.ignored = (obj.value(forKey: "ignored") as? Bool) ?? false
			sd.lastHeard = obj.value(forKey: "lastHeard") as? Date
			sd.num = num
			sd.peripheralId = obj.value(forKey: "peripheralId") as? String
			sd.rssi = (obj.value(forKey: "rssi") as? Int32) ?? 0
			sd.sessionExpiration = obj.value(forKey: "sessionExpiration") as? Date
			sd.sessionPasskey = obj.value(forKey: "sessionPasskey") as? Data
			sd.snr = (obj.value(forKey: "snr") as? Float) ?? 0
			sd.viaMqtt = (obj.value(forKey: "viaMqtt") as? Bool) ?? false
			sdContext.insert(sd)
			map[obj.objectID] = sd
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(objects.count) NodeInfoEntity records (\(state.preexistingNodeNums.count) already present)")
		return map
	}

	static func mergeMissingNodeFields(from object: NSManagedObject, into node: NodeInfoEntity) {
		node.bleName = node.bleName ?? object.value(forKey: "bleName") as? String
		if node.channel == 0 { node.channel = (object.value(forKey: "channel") as? Int32) ?? 0 }
		node.favorite = node.favorite || ((object.value(forKey: "favorite") as? Bool) ?? false)
		if let legacy = object.value(forKey: "firstHeard") as? Date {
			node.firstHeard = min(node.firstHeard ?? legacy, legacy)
		}
		if node.hopsAway == 0 { node.hopsAway = (object.value(forKey: "hopsAway") as? Int32) ?? 0 }
		if node.id == 0 { node.id = (object.value(forKey: "id") as? Int64) ?? 0 }
		node.ignored = node.ignored || ((object.value(forKey: "ignored") as? Bool) ?? false)
		if let legacy = object.value(forKey: "lastHeard") as? Date {
			node.lastHeard = max(node.lastHeard ?? legacy, legacy)
		}
		node.peripheralId = node.peripheralId ?? object.value(forKey: "peripheralId") as? String
		if node.rssi == 0 { node.rssi = (object.value(forKey: "rssi") as? Int32) ?? 0 }
		if let legacy = object.value(forKey: "sessionExpiration") as? Date {
			node.sessionExpiration = max(node.sessionExpiration ?? legacy, legacy)
		}
		node.sessionPasskey = node.sessionPasskey ?? object.value(forKey: "sessionPasskey") as? Data
		if node.snr == 0 { node.snr = (object.value(forKey: "snr") as? Float) ?? 0 }
		node.viaMqtt = node.viaMqtt || ((object.value(forKey: "viaMqtt") as? Bool) ?? false)
	}

	// MARK: UserEntity

	static func migrateUsers(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws -> [NSManagedObjectID: UserEntity] {
		let request = NSFetchRequest<NSManagedObject>(entityName: "UserEntity")
		let objects = try cdContext.fetch(request)
		var map = [NSManagedObjectID: UserEntity]()

		let existingByNum = Dictionary(
			(try sdContext.fetch(FetchDescriptor<UserEntity>())).map { ($0.num, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		var migrated = 0
		for obj in objects {
			let num = (obj.value(forKey: "num") as? Int64) ?? 0
			if let existing = existingByNum[num] {
				mergeMissingUserFields(from: obj, into: existing)
				if existing.userNode == nil,
				   let cdNode = obj.value(forKey: "userNode") as? NSManagedObject,
				   let sdNode = nodeMap[cdNode.objectID],
				   sdNode.user == nil {
					existing.userNode = sdNode
				}
				map[obj.objectID] = existing
				continue
			}
			let sd = UserEntity()
			sd.hwDisplayName = obj.value(forKey: "hwDisplayName") as? String
			sd.hwModel = obj.value(forKey: "hwModel") as? String
			sd.hwModelId = (obj.value(forKey: "hwModelId") as? Int32) ?? 0
			sd.isLicensed = (obj.value(forKey: "isLicensed") as? Bool) ?? false
			sd.keyMatch = (obj.value(forKey: "keyMatch") as? Bool) ?? true
			sd.lastMessage = obj.value(forKey: "lastMessage") as? Date
			sd.longName = obj.value(forKey: "longName") as? String
			sd.mute = (obj.value(forKey: "mute") as? Bool) ?? false
			sd.newPublicKey = obj.value(forKey: "newPublicKey") as? Data
			sd.num = num
			sd.numString = obj.value(forKey: "numString") as? String
			sd.pkiEncrypted = (obj.value(forKey: "pkiEncrypted") as? Bool) ?? false
			sd.publicKey = obj.value(forKey: "publicKey") as? Data
			sd.role = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.shortName = obj.value(forKey: "shortName") as? String
			sd.unmessagable = (obj.value(forKey: "unmessagable") as? Bool) ?? false
			sd.userId = obj.value(forKey: "userId") as? String

			if let cdNode = obj.value(forKey: "userNode") as? NSManagedObject,
			   let sdNode = nodeMap[cdNode.objectID],
			   sdNode.user == nil {
				// Only claim the node when it has no live user; a preexisting node keeps its
				// (fresher) user rather than being reparented onto the legacy row.
				sd.userNode = sdNode
			}
			sdContext.insert(sd)
			map[obj.objectID] = sd
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(objects.count) UserEntity records")
		return map
	}

	static func mergeMissingUserFields(from object: NSManagedObject, into user: UserEntity) {
		user.hwDisplayName = user.hwDisplayName ?? object.value(forKey: "hwDisplayName") as? String
		user.hwModel = user.hwModel ?? object.value(forKey: "hwModel") as? String
		if user.hwModelId == 0 { user.hwModelId = (object.value(forKey: "hwModelId") as? Int32) ?? 0 }
		user.isLicensed = user.isLicensed || ((object.value(forKey: "isLicensed") as? Bool) ?? false)
		user.keyMatch = user.keyMatch && ((object.value(forKey: "keyMatch") as? Bool) ?? true)
		if let legacy = object.value(forKey: "lastMessage") as? Date {
			user.lastMessage = max(user.lastMessage ?? legacy, legacy)
		}
		user.longName = user.longName ?? object.value(forKey: "longName") as? String
		user.mute = user.mute || ((object.value(forKey: "mute") as? Bool) ?? false)
		user.newPublicKey = user.newPublicKey ?? object.value(forKey: "newPublicKey") as? Data
		user.numString = user.numString ?? object.value(forKey: "numString") as? String
		user.pkiEncrypted = user.pkiEncrypted || ((object.value(forKey: "pkiEncrypted") as? Bool) ?? false)
		user.publicKey = user.publicKey ?? object.value(forKey: "publicKey") as? Data
		if user.role == 0 { user.role = (object.value(forKey: "role") as? Int32) ?? 0 }
		user.shortName = user.shortName ?? object.value(forKey: "shortName") as? String
		user.unmessagable = user.unmessagable || ((object.value(forKey: "unmessagable") as? Bool) ?? false)
		user.userId = user.userId ?? object.value(forKey: "userId") as? String
	}

	// MARK: MyInfoEntity

	static func migrateMyInfos(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws -> [NSManagedObjectID: MyInfoEntity] {
		let request = NSFetchRequest<NSManagedObject>(entityName: "MyInfoEntity")
		let objects = try cdContext.fetch(request)
		var map = [NSManagedObjectID: MyInfoEntity]()

		let existingByNum = Dictionary(
			(try sdContext.fetch(FetchDescriptor<MyInfoEntity>())).map { ($0.myNodeNum, $0) },
			uniquingKeysWith: { first, _ in first }
		)

		var migrated = 0
		for obj in objects {
			let myNodeNum = (obj.value(forKey: "myNodeNum") as? Int64) ?? 0
			if let existing = existingByNum[myNodeNum] {
				mergeMissingMyInfoFields(from: obj, into: existing)
				if existing.myInfoNode == nil,
				   let cdNode = obj.value(forKey: "myInfoNode") as? NSManagedObject,
				   let sdNode = nodeMap[cdNode.objectID],
				   sdNode.myInfo == nil {
					existing.myInfoNode = sdNode
				}
				state.preexistingMyInfoNums.insert(myNodeNum)
				map[obj.objectID] = existing
				continue
			}
			let sd = MyInfoEntity()
			sd.bleName = obj.value(forKey: "bleName") as? String
			sd.deviceId = obj.value(forKey: "deviceId") as? Data
			sd.minAppVersion = (obj.value(forKey: "minAppVersion") as? Int32) ?? 0
			sd.myNodeNum = myNodeNum
			sd.peripheralId = obj.value(forKey: "peripheralId") as? String
			sd.pioEnv = obj.value(forKey: "pioEnv") as? String
			sd.rebootCount = (obj.value(forKey: "rebootCount") as? Int32) ?? 0
			sd.registered = (obj.value(forKey: "registered") as? Bool) ?? false

			if let cdNode = obj.value(forKey: "myInfoNode") as? NSManagedObject,
			   let sdNode = nodeMap[cdNode.objectID] {
				sd.myInfoNode = sdNode
			}
			sdContext.insert(sd)
			map[obj.objectID] = sd
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(objects.count) MyInfoEntity records")
		return map
	}

	static func mergeMissingMyInfoFields(from object: NSManagedObject, into info: MyInfoEntity) {
		info.bleName = info.bleName ?? object.value(forKey: "bleName") as? String
		info.deviceId = info.deviceId ?? object.value(forKey: "deviceId") as? Data
		if info.minAppVersion == 0 { info.minAppVersion = (object.value(forKey: "minAppVersion") as? Int32) ?? 0 }
		info.peripheralId = info.peripheralId ?? object.value(forKey: "peripheralId") as? String
		info.pioEnv = info.pioEnv ?? object.value(forKey: "pioEnv") as? String
		if info.rebootCount == 0 { info.rebootCount = (object.value(forKey: "rebootCount") as? Int32) ?? 0 }
		info.registered = info.registered || ((object.value(forKey: "registered") as? Bool) ?? false)
	}

	// MARK: ChannelEntity

	static func migrateChannels(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		infoMap: [NSManagedObjectID: MyInfoEntity],
		state _: MergeState
	) throws {
		let request = NSFetchRequest<NSManagedObject>(entityName: "ChannelEntity")
		let objects = try cdContext.fetch(request)
		var destinationCounts: [ChannelFingerprint: Int] = [:]
		for channel in try sdContext.fetch(FetchDescriptor<ChannelEntity>()) {
			destinationCounts[ChannelFingerprint(channel), default: 0] += 1
		}
		var sourceCounts: [ChannelFingerprint: Int] = [:]

		var migrated = 0
		for obj in objects {
			let cdInfo = obj.value(forKey: "myInfoChannel") as? NSManagedObject
			let sdInfo = cdInfo.flatMap { infoMap[$0.objectID] }
			let fingerprint = ChannelFingerprint(coreDataObject: obj, myNodeNum: sdInfo?.myNodeNum)
			sourceCounts[fingerprint, default: 0] += 1
			guard sourceCounts[fingerprint, default: 0] > destinationCounts[fingerprint, default: 0] else {
				continue
			}
			let sd = ChannelEntity()
			sd.downlinkEnabled = (obj.value(forKey: "downlinkEnabled") as? Bool) ?? false
			sd.id              = (obj.value(forKey: "id") as? Int32) ?? 0
			sd.index           = (obj.value(forKey: "index") as? Int32) ?? 0
			sd.mute            = (obj.value(forKey: "mute") as? Bool) ?? false
			sd.name            = obj.value(forKey: "name") as? String
			sd.positionPrecision = (obj.value(forKey: "positionPrecision") as? Int32) ?? 32
			sd.psk             = obj.value(forKey: "psk") as? Data
			sd.role            = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.uplinkEnabled   = (obj.value(forKey: "uplinkEnabled") as? Bool) ?? false
			sd.myInfoChannel = sdInfo
			sdContext.insert(sd)
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(objects.count) ChannelEntity records")
	}

	// MARK: MessageEntity

	static func migrateMessages(
		cdContext: NSManagedObjectContext,
		container: ModelContainer,
		replayIndex: ReplayIndex,
		options: MigrationOptions
	) throws {
		let phaseStartedAt = ContinuousClock.now
		let batchSize = options.batchSize
		try seedExistingMessages(in: container, batchSize: batchSize, replayIndex: replayIndex)
		Logger.data.notice("⬆️ [MIGRATION] existing message scan: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds")
		var migrated = 0
		var processed = 0

		try forEachCoreDataBatch(
			entityName: "MessageEntity",
			context: cdContext,
			batchSize: batchSize,
			sortDescriptors: messageSortDescriptors
		) { batchIndex, objects in
			let sdContext = ModelContext(container)
			sdContext.autosaveEnabled = false
			try replayIndex.withTransaction {
				for obj in objects {
					processed += 1
					let messageId = (obj.value(forKey: "messageId") as? Int64) ?? 0
					let claim = try replayIndex.claimSource(kind: .message, key: replayKey(messageId))
					guard claim.sourceSeen == 1 else {
						throw MigrationError.duplicateLegacyMessageId(messageId)
					}
					if claim.destinationCount > 0 {
						var descriptor = FetchDescriptor<MessageEntity>(
							predicate: #Predicate { $0.messageId == messageId }
						)
						descriptor.fetchLimit = 1
						if let destination = try sdContext.fetch(descriptor).first {
							mergeMissingMessageFields(from: obj, into: destination)
						}
						continue
					}

					let sd = MessageEntity()
					sd.ackError = (obj.value(forKey: "ackError") as? Int32) ?? 0
					sd.ackSNR = (obj.value(forKey: "ackSNR") as? Float) ?? 0
					sd.ackTimestamp = (obj.value(forKey: "ackTimestamp") as? Int32) ?? 0
					sd.admin = (obj.value(forKey: "admin") as? Bool) ?? false
					sd.adminDescription = obj.value(forKey: "adminDescription") as? String
					sd.channel = (obj.value(forKey: "channel") as? Int32) ?? 0
					sd.isEmoji = (obj.value(forKey: "isEmoji") as? Bool) ?? false
					sd.messageId = messageId
					sd.messagePayload = obj.value(forKey: "messagePayload") as? String
					sd.messagePayloadMarkdown = obj.value(forKey: "messagePayloadMarkdown") as? String
					sd.messagePayloadTranslated = obj.value(forKey: "messagePayloadTranslated") as? String
					sd.messagePayloadTranslatedMarkdown = obj.value(forKey: "messagePayloadTranslatedMarkdown") as? String
					sd.messageTimestamp = (obj.value(forKey: "messageTimestamp") as? Int32) ?? 0
					sd.pkiEncrypted = (obj.value(forKey: "pkiEncrypted") as? Bool) ?? false
					sd.portNum = (obj.value(forKey: "portNum") as? Int32) ?? 0
					sd.publicKey = obj.value(forKey: "publicKey") as? Data
					sd.read = (obj.value(forKey: "read") as? Bool) ?? false
					sd.realACK = (obj.value(forKey: "realACK") as? Bool) ?? false
					sd.receivedACK = (obj.value(forKey: "receivedACK") as? Bool) ?? false
					sd.relayNode = (obj.value(forKey: "relayNode") as? Int64) ?? 0
					sd.relays = (obj.value(forKey: "relays") as? Int16) ?? 0
					sd.replyID = (obj.value(forKey: "replyID") as? Int64) ?? 0
					sd.rssi = (obj.value(forKey: "rssi") as? Int32) ?? 0
					sd.showTranslatedMessage = (obj.value(forKey: "showTranslatedMessage") as? Bool) ?? false
					sd.snr = (obj.value(forKey: "snr") as? Float) ?? 0
					sdContext.insert(sd)
					migrated += 1
				}
				if sdContext.hasChanges {
					try sdContext.save()
				}
			}
			try options.checkpoint(.afterHistoryBatch(.messages, index: batchIndex))
		}

		try options.checkpoint(.afterMessageScalarPersistence)
		Logger.data.notice("⬆️ [MIGRATION] message scalars saved: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds")
		try forEachCoreDataBatch(
			entityName: "MessageEntity",
			context: cdContext,
			batchSize: batchSize,
			sortDescriptors: messageSortDescriptors,
			relationshipKeyPathsForPrefetching: ["fromUser", "toUser"]
		) { _, objects in
			let messageUserLinks = Dictionary(
				uniqueKeysWithValues: objects.map { object in
					let messageId = (object.value(forKey: "messageId") as? Int64) ?? 0
					return (
						messageId,
						MessageUserLink(
							fromNum: relatedInt64(object, relationship: "fromUser", key: "num"),
							toNum: relatedInt64(object, relationship: "toUser", key: "num")
						)
					)
				}
			)
			try linkMessageUsers(
				messageUserLinks: messageUserLinks,
				container: container,
				options: options
			)
		}
		Logger.data.notice("⬆️ [MIGRATION] messages complete: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds; migrated \(migrated, privacy: .public) of \(processed, privacy: .public)")
	}

	static func mergeMissingMessageFields(from object: NSManagedObject, into message: MessageEntity) {
		if message.ackError == 0 { message.ackError = (object.value(forKey: "ackError") as? Int32) ?? 0 }
		if message.ackSNR == 0 { message.ackSNR = (object.value(forKey: "ackSNR") as? Float) ?? 0 }
		if message.ackTimestamp == 0 { message.ackTimestamp = (object.value(forKey: "ackTimestamp") as? Int32) ?? 0 }
		message.admin = message.admin || ((object.value(forKey: "admin") as? Bool) ?? false)
		message.adminDescription = message.adminDescription ?? object.value(forKey: "adminDescription") as? String
		if message.channel == 0 { message.channel = (object.value(forKey: "channel") as? Int32) ?? 0 }
		message.isEmoji = message.isEmoji || ((object.value(forKey: "isEmoji") as? Bool) ?? false)
		if message.messagePayload?.isEmpty != false { message.messagePayload = object.value(forKey: "messagePayload") as? String }
		message.messagePayloadMarkdown = message.messagePayloadMarkdown ?? object.value(forKey: "messagePayloadMarkdown") as? String
		message.messagePayloadTranslated = message.messagePayloadTranslated ?? object.value(forKey: "messagePayloadTranslated") as? String
		message.messagePayloadTranslatedMarkdown = message.messagePayloadTranslatedMarkdown ?? object.value(forKey: "messagePayloadTranslatedMarkdown") as? String
		if message.messageTimestamp == 0 { message.messageTimestamp = (object.value(forKey: "messageTimestamp") as? Int32) ?? 0 }
		message.pkiEncrypted = message.pkiEncrypted || ((object.value(forKey: "pkiEncrypted") as? Bool) ?? false)
		if message.portNum == 0 { message.portNum = (object.value(forKey: "portNum") as? Int32) ?? 0 }
		message.publicKey = message.publicKey ?? object.value(forKey: "publicKey") as? Data
		message.read = message.read || ((object.value(forKey: "read") as? Bool) ?? false)
		message.realACK = message.realACK || ((object.value(forKey: "realACK") as? Bool) ?? false)
		message.receivedACK = message.receivedACK || ((object.value(forKey: "receivedACK") as? Bool) ?? false)
		if message.relayNode == 0 { message.relayNode = (object.value(forKey: "relayNode") as? Int64) ?? 0 }
		if message.relays == 0 { message.relays = (object.value(forKey: "relays") as? Int16) ?? 0 }
		if message.replyID == 0 { message.replyID = (object.value(forKey: "replyID") as? Int64) ?? 0 }
		if message.rssi == 0 { message.rssi = (object.value(forKey: "rssi") as? Int32) ?? 0 }
		message.showTranslatedMessage = message.showTranslatedMessage || ((object.value(forKey: "showTranslatedMessage") as? Bool) ?? false)
		if message.snr == 0 { message.snr = (object.value(forKey: "snr") as? Float) ?? 0 }
	}

	static func linkMessageUsers(
		messageUserLinks: [Int64: MessageUserLink],
		container: ModelContainer,
		options: MigrationOptions
	) throws {
		var sentMessageIds: [Int64: [Int64]] = [:]
		var receivedMessageIds: [Int64: [Int64]] = [:]
		for (messageId, link) in messageUserLinks {
			if let fromNum = link.fromNum {
				sentMessageIds[fromNum, default: []].append(messageId)
			}
			if let toNum = link.toNum {
				receivedMessageIds[toNum, default: []].append(messageId)
			}
		}

		let userNums = Set(sentMessageIds.keys).union(receivedMessageIds.keys).sorted()
		let userGroupSize = max(1, options.batchSize / 5)
		for userStart in stride(from: 0, to: userNums.count, by: userGroupSize) {
			let userEnd = min(userStart + userGroupSize, userNums.count)
			let userNumBatch = Array(userNums[userStart..<userEnd])
			let messageIds = Set(userNumBatch.flatMap {
				(sentMessageIds[$0] ?? []) + (receivedMessageIds[$0] ?? [])
			}).sorted()
			for messageStart in stride(from: 0, to: messageIds.count, by: options.batchSize) {
				let messageEnd = min(messageStart + options.batchSize, messageIds.count)
				let messageIdBatch = Array(messageIds[messageStart..<messageEnd])
				let context = ModelContext(container)
				context.autosaveEnabled = false
				let userDescriptor = FetchDescriptor<UserEntity>(
					predicate: #Predicate { userNumBatch.contains($0.num) }
				)
				let usersByNum = Dictionary(
					uniqueKeysWithValues: try context.fetch(userDescriptor).map { ($0.num, $0) }
				)
				let descriptor = FetchDescriptor<MessageEntity>(
					predicate: #Predicate { messageIdBatch.contains($0.messageId) }
				)
				for message in try context.fetch(descriptor) {
					guard let link = messageUserLinks[message.messageId] else { continue }
					if message.fromUser == nil,
					   let fromNum = link.fromNum,
					   let user = usersByNum[fromNum] {
						message.fromUser = user
					}
					if message.toUser == nil,
					   let toNum = link.toNum,
					   let user = usersByNum[toNum] {
						message.toUser = user
					}
				}
				if context.hasChanges {
					try context.save()
				}
			}
			for num in userNumBatch {
				try options.checkpoint(.afterMessageUserLink(nodeNum: num))
			}
		}
	}

	// MARK: PositionEntity

	static func migratePositions(
		cdContext: NSManagedObjectContext,
		container: ModelContainer,
		replayIndex: ReplayIndex,
		options: MigrationOptions
	) throws {
		let phaseStartedAt = ContinuousClock.now
		let batchSize = options.batchSize
		try seedExistingPositions(in: container, batchSize: batchSize, replayIndex: replayIndex)
		Logger.data.notice("⬆️ [MIGRATION] existing position scan: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds")
		var migrated = 0
		var processed = 0

		try forEachCoreDataBatch(
			entityName: "PositionEntity",
			context: cdContext,
			batchSize: batchSize,
			sortDescriptors: positionSortDescriptors,
			relationshipKeyPathsForPrefetching: ["nodePosition"]
		) { batchIndex, objects in
			let sdContext = ModelContext(container)
			sdContext.autosaveEnabled = false
			var nodes: [Int64: NodeInfoEntity] = [:]

			try replayIndex.withTransaction {
				for obj in objects {
					processed += 1
					let nodeNum = relatedInt64(obj, relationship: "nodePosition", key: "num")
					let fingerprint = PositionFingerprint(coreDataObject: obj, nodeNum: nodeNum)
					let claim = try replayIndex.claimSource(kind: .position, key: fingerprint.replayKey)
					guard claim.sourceSeen > claim.destinationCount else { continue }

					let sd = PositionEntity()
					sd.altitude = (obj.value(forKey: "altitude") as? Int32) ?? 0
					sd.heading = (obj.value(forKey: "heading") as? Int32) ?? 0
					sd.latest = (obj.value(forKey: "latest") as? Bool) ?? false
					sd.latitudeI = (obj.value(forKey: "latitudeI") as? Int32) ?? 0
					sd.longitudeI = (obj.value(forKey: "longitudeI") as? Int32) ?? 0
					sd.precisionBits = (obj.value(forKey: "precisionBits") as? Int32) ?? 32
					sd.rssi = (obj.value(forKey: "rssi") as? Int32) ?? 0
					sd.satsInView = (obj.value(forKey: "satsInView") as? Int32) ?? 0
					sd.seqNo = (obj.value(forKey: "seqNo") as? Int32) ?? 0
					sd.snr = (obj.value(forKey: "snr") as? Float) ?? 0
					sd.speed = (obj.value(forKey: "speed") as? Int32) ?? 0
					sd.time = obj.value(forKey: "time") as? Date
					if let nodeNum {
						sd.nodePosition = try destinationNode(num: nodeNum, context: sdContext, cache: &nodes)
					}
					sdContext.insert(sd)
					migrated += 1
				}
				if sdContext.hasChanges {
					try sdContext.save()
				}
			}
			try options.checkpoint(.afterHistoryBatch(.positions, index: batchIndex))
		}
		Logger.data.notice("⬆️ [MIGRATION] positions complete: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds; migrated \(migrated, privacy: .public) of \(processed, privacy: .public)")
	}

	// MARK: TelemetryEntity

	static func migrateTelemetry(
		cdContext: NSManagedObjectContext,
		container: ModelContainer,
		replayIndex: ReplayIndex,
		options: MigrationOptions
	) throws {
		let phaseStartedAt = ContinuousClock.now
		let batchSize = options.batchSize
		try seedExistingTelemetry(in: container, batchSize: batchSize, replayIndex: replayIndex)
		Logger.data.notice("⬆️ [MIGRATION] existing telemetry scan: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds")
		var migrated = 0
		var processed = 0

		try forEachCoreDataBatch(
			entityName: "TelemetryEntity",
			context: cdContext,
			batchSize: batchSize,
			sortDescriptors: telemetrySortDescriptors,
			relationshipKeyPathsForPrefetching: ["nodeTelemetry"]
		) { batchIndex, objects in
			let sdContext = ModelContext(container)
			sdContext.autosaveEnabled = false
			var nodes: [Int64: NodeInfoEntity] = [:]

			try replayIndex.withTransaction {
				for obj in objects {
					processed += 1
					let nodeNum = relatedInt64(obj, relationship: "nodeTelemetry", key: "num")
					let fingerprint = TelemetryFingerprint(coreDataObject: obj, nodeNum: nodeNum)
					let claim = try replayIndex.claimSource(kind: .telemetry, key: fingerprint.replayKey)
					guard claim.sourceSeen > claim.destinationCount else { continue }

					let sd = TelemetryEntity()
					sd.metricsType = (obj.value(forKey: "metricsType") as? Int32) ?? 0
					sd.numOnlineNodes = (obj.value(forKey: "numOnlineNodes") as? Int32) ?? 0
					sd.numPacketsRx = (obj.value(forKey: "numPacketsRx") as? Int32) ?? 0
					sd.numPacketsRxBad = (obj.value(forKey: "numPacketsRxBad") as? Int32) ?? 0
					sd.numPacketsTx = (obj.value(forKey: "numPacketsTx") as? Int32) ?? 0
					sd.numRxDupe = (obj.value(forKey: "numRxDupe") as? Int32) ?? 0
					sd.numTotalNodes = (obj.value(forKey: "numTotalNodes") as? Int32) ?? 0
					sd.numTxRelay = (obj.value(forKey: "numTxRelay") as? Int32) ?? 0
					sd.numTxRelayCanceled = (obj.value(forKey: "numTxRelayCanceled") as? Int32) ?? 0
					sd.time = obj.value(forKey: "time") as? Date
					sd.airUtilTx = obj.value(forKey: "airUtilTx") as? Float
					sd.barometricPressure = obj.value(forKey: "barometricPressure") as? Float
					sd.batteryLevel = obj.value(forKey: "batteryLevel") as? Int32
					sd.channelUtilization = obj.value(forKey: "channelUtilization") as? Float
					sd.current = obj.value(forKey: "current") as? Float
					sd.gasResistance = obj.value(forKey: "gasResistance") as? Float
					sd.iaq = obj.value(forKey: "iaq") as? Int32
					sd.irLux = obj.value(forKey: "irLux") as? Float
					sd.lux = obj.value(forKey: "lux") as? Float
					sd.powerCh1Current = obj.value(forKey: "powerCh1Current") as? Float
					sd.powerCh1Voltage = obj.value(forKey: "powerCh1Voltage") as? Float
					sd.powerCh2Current = obj.value(forKey: "powerCh2Current") as? Float
					sd.powerCh2Voltage = obj.value(forKey: "powerCh2Voltage") as? Float
					sd.powerCh3Current = obj.value(forKey: "powerCh3Current") as? Float
					sd.powerCh3Voltage = obj.value(forKey: "powerCh3Voltage") as? Float
					sd.radiation = obj.value(forKey: "radiation") as? Float
					sd.rainfall1H = obj.value(forKey: "rainfall1H") as? Float
					sd.rainfall24H = obj.value(forKey: "rainfall24H") as? Float
					sd.relativeHumidity = obj.value(forKey: "relativeHumidity") as? Float
					sd.rssi = obj.value(forKey: "rssi") as? Int32
					sd.snr = obj.value(forKey: "snr") as? Float
					if let soilMoisture = obj.value(forKey: "soilMoisture") as? Int32 {
						sd.soilMoisture = UInt32(bitPattern: soilMoisture)
					}
					sd.soilTemperature = obj.value(forKey: "soilTemperature") as? Float
					sd.temperature = obj.value(forKey: "temperature") as? Float
					sd.uptimeSeconds = obj.value(forKey: "uptimeSeconds") as? Int32
					sd.uvLux = obj.value(forKey: "uvLux") as? Float
					sd.voltage = obj.value(forKey: "voltage") as? Float
					sd.weight = obj.value(forKey: "weight") as? Float
					sd.whiteLux = obj.value(forKey: "whiteLux") as? Float
					sd.windDirection = obj.value(forKey: "windDirection") as? Int32
					sd.windGust = obj.value(forKey: "windGust") as? Float
					sd.windLull = obj.value(forKey: "windLull") as? Float
					sd.windSpeed = obj.value(forKey: "windSpeed") as? Float
					if let nodeNum {
						sd.nodeTelemetry = try destinationNode(num: nodeNum, context: sdContext, cache: &nodes)
					}
					sdContext.insert(sd)
					migrated += 1
				}
				if sdContext.hasChanges {
					try sdContext.save()
				}
			}
			try options.checkpoint(.afterHistoryBatch(.telemetry, index: batchIndex))
		}
		Logger.data.notice("⬆️ [MIGRATION] telemetry complete: \(elapsedSeconds(since: phaseStartedAt), privacy: .public) seconds; migrated \(migrated, privacy: .public) of \(processed, privacy: .public)")
	}

	// MARK: Batching helpers

	static func forEachCoreDataBatch(
		entityName: String,
		context: NSManagedObjectContext,
		batchSize: Int,
		sortDescriptors: [NSSortDescriptor],
		relationshipKeyPathsForPrefetching: [String] = [],
		body: (Int, [NSManagedObject]) throws -> Void
	) throws {
		var batchIndex = 0
		var offset = 0
		while true {
			let count = try autoreleasepool { () throws -> Int in
				let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
				request.includesPendingChanges = false
				request.returnsObjectsAsFaults = false
				request.fetchLimit = batchSize
				request.fetchOffset = offset
				request.sortDescriptors = sortDescriptors
				request.relationshipKeyPathsForPrefetching = relationshipKeyPathsForPrefetching
				let objects = try context.fetch(request)
				guard !objects.isEmpty else { return 0 }
				try body(batchIndex, objects)
				let count = objects.count
				context.reset()
				return count
			}
			guard count > 0 else { return }
			offset += count
			batchIndex += 1
		}
	}

	static func seedExistingPositions(
		in container: ModelContainer,
		batchSize: Int,
		replayIndex: ReplayIndex
	) throws {
		for latest in [false, true] {
			var offset = 0
			while true {
				let count = try autoreleasepool { () throws -> Int in
					let context = ModelContext(container)
					var descriptor = FetchDescriptor<PositionEntity>(
					predicate: #Predicate { $0.latest == latest },
					sortBy: [
						SortDescriptor(\.nodePosition?.num),
						SortDescriptor(\.time),
						SortDescriptor(\.altitude),
						SortDescriptor(\.heading),
						SortDescriptor(\.latitudeI),
						SortDescriptor(\.longitudeI),
						SortDescriptor(\.precisionBits),
						SortDescriptor(\.rssi),
						SortDescriptor(\.satsInView),
						SortDescriptor(\.seqNo),
						SortDescriptor(\.snr),
						SortDescriptor(\.speed)
					]
				)
				descriptor.fetchLimit = batchSize
				descriptor.fetchOffset = offset
					let positions = try context.fetch(descriptor)
					guard !positions.isEmpty else { return 0 }
					try replayIndex.withTransaction {
						for position in positions {
							try replayIndex.recordDestination(
								kind: .position,
								key: PositionFingerprint(position).replayKey
							)
						}
					}
					return positions.count
				}
				guard count > 0 else { break }
				offset += count
			}
		}
	}

	static func seedExistingTelemetry(
		in container: ModelContainer,
		batchSize: Int,
		replayIndex: ReplayIndex
	) throws {
		var offset = 0
		while true {
			let count = try autoreleasepool { () throws -> Int in
				let context = ModelContext(container)
				var descriptor = FetchDescriptor<TelemetryEntity>(
				sortBy: [
					SortDescriptor(\.nodeTelemetry?.num),
					SortDescriptor(\.time),
					SortDescriptor(\.metricsType),
					SortDescriptor(\.numOnlineNodes),
					SortDescriptor(\.numPacketsRx),
					SortDescriptor(\.numPacketsRxBad),
					SortDescriptor(\.numPacketsTx),
					SortDescriptor(\.numRxDupe),
					SortDescriptor(\.numTotalNodes),
					SortDescriptor(\.numTxRelay),
					SortDescriptor(\.numTxRelayCanceled),
					SortDescriptor(\.airUtilTx),
					SortDescriptor(\.barometricPressure),
					SortDescriptor(\.batteryLevel),
					SortDescriptor(\.channelUtilization),
					SortDescriptor(\.current),
					SortDescriptor(\.gasResistance),
					SortDescriptor(\.iaq),
					SortDescriptor(\.irLux),
					SortDescriptor(\.lux),
					SortDescriptor(\.powerCh1Current),
					SortDescriptor(\.powerCh1Voltage),
					SortDescriptor(\.powerCh2Current),
					SortDescriptor(\.powerCh2Voltage),
					SortDescriptor(\.powerCh3Current),
					SortDescriptor(\.powerCh3Voltage),
					SortDescriptor(\.radiation),
					SortDescriptor(\.rainfall1H),
					SortDescriptor(\.rainfall24H),
					SortDescriptor(\.relativeHumidity),
					SortDescriptor(\.rssi),
					SortDescriptor(\.snr),
					SortDescriptor(\.soilMoisture),
					SortDescriptor(\.soilTemperature),
					SortDescriptor(\.temperature),
					SortDescriptor(\.uptimeSeconds),
					SortDescriptor(\.uvLux),
					SortDescriptor(\.voltage),
					SortDescriptor(\.weight),
					SortDescriptor(\.whiteLux),
					SortDescriptor(\.windDirection),
					SortDescriptor(\.windGust),
					SortDescriptor(\.windLull),
					SortDescriptor(\.windSpeed)
				]
			)
			descriptor.fetchLimit = batchSize
			descriptor.fetchOffset = offset
				let telemetry = try context.fetch(descriptor)
				guard !telemetry.isEmpty else { return 0 }
				try replayIndex.withTransaction {
					for sample in telemetry {
						try replayIndex.recordDestination(
							kind: .telemetry,
							key: TelemetryFingerprint(sample).replayKey
						)
					}
				}
				return telemetry.count
			}
			guard count > 0 else { return }
			offset += count
		}
	}

	static func seedExistingMessages(
		in container: ModelContainer,
		batchSize: Int,
		replayIndex: ReplayIndex
	) throws {
		var offset = 0
		while true {
			let count = try autoreleasepool { () throws -> Int in
				let context = ModelContext(container)
				var descriptor = FetchDescriptor<MessageEntity>(
				sortBy: [SortDescriptor(\.messageId)]
			)
			descriptor.fetchLimit = batchSize
			descriptor.fetchOffset = offset
				let messages = try context.fetch(descriptor)
				guard !messages.isEmpty else { return 0 }
				try replayIndex.withTransaction {
					for message in messages {
						try replayIndex.recordDestination(kind: .message, key: replayKey(message.messageId))
					}
				}
				return messages.count
			}
			guard count > 0 else { return }
			offset += count
		}
	}

	static func replayKey(_ messageId: Int64) -> Data {
		var encoder = FingerprintEncoder()
		encoder.append(messageId)
		return encoder.data
	}

	static var messageSortDescriptors: [NSSortDescriptor] {
		[NSSortDescriptor(key: "messageId", ascending: true)]
	}

	static var positionSortDescriptors: [NSSortDescriptor] {
		[
			NSSortDescriptor(key: "nodePosition.num", ascending: true),
			NSSortDescriptor(key: "time", ascending: true),
			NSSortDescriptor(key: "altitude", ascending: true),
			NSSortDescriptor(key: "heading", ascending: true),
			NSSortDescriptor(key: "latest", ascending: true),
			NSSortDescriptor(key: "latitudeI", ascending: true),
			NSSortDescriptor(key: "longitudeI", ascending: true),
			NSSortDescriptor(key: "precisionBits", ascending: true),
			NSSortDescriptor(key: "rssi", ascending: true),
			NSSortDescriptor(key: "satsInView", ascending: true),
			NSSortDescriptor(key: "seqNo", ascending: true),
			NSSortDescriptor(key: "snr", ascending: true),
			NSSortDescriptor(key: "speed", ascending: true)
		]
	}

	static var telemetrySortDescriptors: [NSSortDescriptor] {
		[
			"nodeTelemetry.num", "time", "metricsType", "numOnlineNodes", "numPacketsRx",
			"numPacketsRxBad", "numPacketsTx", "numRxDupe", "numTotalNodes", "numTxRelay",
			"numTxRelayCanceled", "airUtilTx", "barometricPressure", "batteryLevel",
			"channelUtilization", "current", "gasResistance", "iaq", "irLux", "lux",
			"powerCh1Current", "powerCh1Voltage", "powerCh2Current", "powerCh2Voltage",
			"powerCh3Current", "powerCh3Voltage", "radiation", "rainfall1H", "rainfall24H",
			"relativeHumidity", "rssi", "snr", "soilMoisture", "soilTemperature", "temperature",
			"uptimeSeconds", "uvLux", "voltage", "weight", "whiteLux", "windDirection",
			"windGust", "windLull", "windSpeed"
		].map { NSSortDescriptor(key: $0, ascending: true) }
	}

	static func relatedInt64(
		_ object: NSManagedObject,
		relationship: String,
		key: String
	) -> Int64? {
		(object.value(forKey: relationship) as? NSManagedObject)?.value(forKey: key) as? Int64
	}

	static func destinationNode(
		num: Int64,
		context: ModelContext,
		cache: inout [Int64: NodeInfoEntity]
	) throws -> NodeInfoEntity? {
		if let cached = cache[num] { return cached }
		let targetNum = num
		var descriptor = FetchDescriptor<NodeInfoEntity>(
			predicate: #Predicate { $0.num == targetNum }
		)
		descriptor.fetchLimit = 1
		let node = try context.fetch(descriptor).first
		if let node { cache[num] = node }
		return node
	}

	// MARK: Config entities

	static func migrateAmbientLightingConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "AmbientLightingConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "ambientLightingConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.blue), .int32(\.current), .int32(\.green), .bool(\.ledState), .int32(\.red)],
			nodeConfig: { $0.ambientLightingConfig },
			configNode: { $0.ambientLightingConfigNode }
		) { obj -> AmbientLightingConfigEntity in
			let sd = AmbientLightingConfigEntity()
			sd.blue = (obj.value(forKey: "blue") as? Int32) ?? 0
			sd.current = (obj.value(forKey: "current") as? Int32) ?? 0
			sd.green = (obj.value(forKey: "green") as? Int32) ?? 0
			sd.ledState = (obj.value(forKey: "ledState") as? Bool) ?? false
			sd.red = (obj.value(forKey: "red") as? Int32) ?? 0
			return sd
		} wireNode: { node, config in
			node.ambientLightingConfig = config
		}
	}

	static func migrateDetectionSensorConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "DetectionSensorConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "detectionSensorConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.enabled), .int32(\.minimumBroadcastSecs), .int32(\.monitorPin), .string(\.name), .bool(\.sendBell), .int32(\.stateBroadcastSecs), .int32(\.triggerType), .bool(\.usePullup)],
			nodeConfig: { $0.detectionSensorConfig },
			configNode: { $0.detectionSensorConfigNode }
		) { obj -> DetectionSensorConfigEntity in
			let sd = DetectionSensorConfigEntity()
			sd.enabled = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.minimumBroadcastSecs = (obj.value(forKey: "minimumBroadcastSecs") as? Int32) ?? 0
			sd.monitorPin = (obj.value(forKey: "monitorPin") as? Int32) ?? 0
			sd.name = obj.value(forKey: "name") as? String
			sd.sendBell = (obj.value(forKey: "sendBell") as? Bool) ?? false
			sd.stateBroadcastSecs = (obj.value(forKey: "stateBroadcastSecs") as? Int32) ?? 0
			sd.triggerType = (obj.value(forKey: "triggerType") as? Int32) ?? 0
			sd.usePullup = (obj.value(forKey: "usePullup") as? Bool) ?? false
			return sd
		} wireNode: { node, config in
			node.detectionSensorConfig = config
		}
	}

	static func migratePaxCounterConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "PaxCounterConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "paxCounterConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.bleThreshold), .bool(\.enabled), .int32(\.updateInterval), .int32(\.wifiThreshold, default: -80)],
			nodeConfig: { $0.paxCounterConfig },
			configNode: { $0.paxCounterConfigNode }
		) { obj -> PaxCounterConfigEntity in
			let sd = PaxCounterConfigEntity()
			sd.bleThreshold = (obj.value(forKey: "bleThreshold") as? Int32) ?? 0
			sd.enabled = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.updateInterval = (obj.value(forKey: "updateInterval") as? Int32) ?? 0
			sd.wifiThreshold = (obj.value(forKey: "wifiThreshold") as? Int32) ?? -80
			return sd
		} wireNode: { node, config in
			node.paxCounterConfig = config
		}
	}

	static func migratePowerConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "PowerConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "powerConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.float(\.adcMultiplierOverride), .int32(\.deviceBatteryInaAddress), .bool(\.isPowerSaving), .int32(\.lsSecs), .int32(\.minWakeSecs), .int32(\.onBatteryShutdownAfterSecs), .int32(\.waitBluetoothSecs)],
			nodeConfig: { $0.powerConfig },
			configNode: { $0.powerConfigNode }
		) { obj -> PowerConfigEntity in
			let sd = PowerConfigEntity()
			sd.adcMultiplierOverride = (obj.value(forKey: "adcMultiplierOverride") as? Float) ?? 0
			sd.deviceBatteryInaAddress = (obj.value(forKey: "deviceBatteryInaAddress") as? Int32) ?? 0
			sd.isPowerSaving = (obj.value(forKey: "isPowerSaving") as? Bool) ?? false
			sd.lsSecs = (obj.value(forKey: "lsSecs") as? Int32) ?? 0
			sd.minWakeSecs = (obj.value(forKey: "minWakeSecs") as? Int32) ?? 0
			sd.onBatteryShutdownAfterSecs = (obj.value(forKey: "onBatteryShutdownAfterSecs") as? Int32) ?? 0
			sd.waitBluetoothSecs = (obj.value(forKey: "waitBluetoothSecs") as? Int32) ?? 0
			return sd
		} wireNode: { node, config in
			node.powerConfig = config
		}
	}

	static func migrateRTTTLConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "RTTTLConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "rtttlConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.string(\.ringtone)],
			nodeConfig: { $0.rtttlConfig },
			configNode: { $0.rtttlConfigNode }
		) { obj -> RTTTLConfigEntity in
			let sd = RTTTLConfigEntity()
			sd.ringtone = obj.value(forKey: "ringtone") as? String
			return sd
		} wireNode: { node, config in
			node.rtttlConfig = config
		}
	}

	static func migrateSecurityConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "SecurityConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "securityConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.adminChannelEnabled), .data(\.adminKey), .data(\.adminKey2), .data(\.adminKey3), .bool(\.bluetoothLoggingEnabled), .bool(\.debugLogApiEnabled), .bool(\.isManaged), .data(\.privateKey), .data(\.publicKey), .bool(\.serialEnabled)],
			nodeConfig: { $0.securityConfig },
			configNode: { $0.securityConfigNode }
		) { obj -> SecurityConfigEntity in
			let sd = SecurityConfigEntity()
			sd.adminChannelEnabled = (obj.value(forKey: "adminChannelEnabled") as? Bool) ?? false
			sd.adminKey = obj.value(forKey: "adminKey") as? Data
			sd.adminKey2 = obj.value(forKey: "adminKey2") as? Data
			sd.adminKey3 = obj.value(forKey: "adminKey3") as? Data
			sd.bluetoothLoggingEnabled = (obj.value(forKey: "bluetoothLoggingEnabled") as? Bool) ?? false
			sd.debugLogApiEnabled = (obj.value(forKey: "debugLogApiEnabled") as? Bool) ?? false
			sd.isManaged = (obj.value(forKey: "isManaged") as? Bool) ?? false
			sd.privateKey = obj.value(forKey: "privateKey") as? Data
			sd.publicKey = obj.value(forKey: "publicKey") as? Data
			sd.serialEnabled = (obj.value(forKey: "serialEnabled") as? Bool) ?? false
			return sd
		} wireNode: { node, config in
			node.securityConfig = config
		}
	}

	static func migrateStoreForwardConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "StoreForwardConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "storeForwardConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.enabled), .bool(\.heartbeat), .int32(\.historyReturnMax), .int32(\.historyReturnWindow), .bool(\.isRouter), .date(\.lastHeartbeat), .int32(\.lastRequest), .int32(\.records)],
			nodeConfig: { $0.storeForwardConfig },
			configNode: { $0.storeForwardConfigNode }
		) { obj -> StoreForwardConfigEntity in
			let sd = StoreForwardConfigEntity()
			sd.enabled = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.heartbeat = (obj.value(forKey: "heartbeat") as? Bool) ?? false
			sd.historyReturnMax = (obj.value(forKey: "historyReturnMax") as? Int32) ?? 0
			sd.historyReturnWindow = (obj.value(forKey: "historyReturnWindow") as? Int32) ?? 0
			sd.isRouter = (obj.value(forKey: "isRouter") as? Bool) ?? false
			sd.lastHeartbeat = obj.value(forKey: "lastHeartbeat") as? Date
			sd.lastRequest = (obj.value(forKey: "lastRequest") as? Int32) ?? 0
			sd.records = (obj.value(forKey: "records") as? Int32) ?? 0
			return sd
		} wireNode: { node, config in
			node.storeForwardConfig = config
		}
	}

	static func migrateTAKConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "TAKConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "takConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.role), .int32(\.team)],
			nodeConfig: { $0.takConfig },
			configNode: { $0.takConfigNode }
		) { obj -> TAKConfigEntity in
			let sd = TAKConfigEntity()
			sd.role = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.team = (obj.value(forKey: "team") as? Int32) ?? 0
			return sd
		} wireNode: { node, config in
			node.takConfig = config
		}
	}

	static func migrateBluetoothConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "BluetoothConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "bluetoothConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.deviceLoggingEnabled), .bool(\.enabled), .int32(\.fixedPin, default: 123_456), .int32(\.mode)],
			nodeConfig: { $0.bluetoothConfig },
			configNode: { $0.bluetoothConfigNode }
		) { obj -> BluetoothConfigEntity in
			let sd = BluetoothConfigEntity()
			sd.deviceLoggingEnabled = (obj.value(forKey: "deviceLoggingEnabled") as? Bool) ?? false
			sd.enabled  = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.fixedPin = (obj.value(forKey: "fixedPin") as? Int32) ?? 0
			sd.mode     = (obj.value(forKey: "mode") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.bluetoothConfig = sdConfig
		}
	}

	static func migrateCannedMessageConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "CannedMessageConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "cannedMessagesConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.enabled), .int32(\.inputbrokerEventCcw), .int32(\.inputbrokerEventCw), .int32(\.inputbrokerEventPress), .int32(\.inputbrokerPinA), .int32(\.inputbrokerPinB), .int32(\.inputbrokerPinPress), .string(\.messages), .bool(\.rotary1Enabled), .bool(\.sendBell), .bool(\.updown1Enabled)],
			nodeConfig: { $0.cannedMessageConfig },
			configNode: { $0.cannedMessagesConfigNode }
		) { obj -> CannedMessageConfigEntity in
			let sd = CannedMessageConfigEntity()
			sd.enabled = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.messages = obj.value(forKey: "messages") as? String
			sd.inputbrokerEventCcw    = (obj.value(forKey: "inputbrokerEventCcw") as? Int32) ?? 0
			sd.inputbrokerEventCw     = (obj.value(forKey: "inputbrokerEventCw") as? Int32) ?? 0
			sd.inputbrokerEventPress  = (obj.value(forKey: "inputbrokerEventPress") as? Int32) ?? 0
			sd.inputbrokerPinA        = (obj.value(forKey: "inputbrokerPinA") as? Int32) ?? 0
			sd.inputbrokerPinB        = (obj.value(forKey: "inputbrokerPinB") as? Int32) ?? 0
			sd.inputbrokerPinPress    = (obj.value(forKey: "inputbrokerPinPress") as? Int32) ?? 0
			sd.rotary1Enabled         = (obj.value(forKey: "rotary1Enabled") as? Bool) ?? false
			sd.sendBell               = (obj.value(forKey: "sendBell") as? Bool) ?? false
			sd.updown1Enabled         = (obj.value(forKey: "updown1Enabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.cannedMessageConfig = sdConfig
		}
	}

	static func migrateDeviceConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "DeviceConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "deviceConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.buttonGpio), .int32(\.buzzerGpio), .bool(\.debugLogEnabled), .bool(\.disableTripleClick), .bool(\.doubleTapAsButtonPress), .bool(\.isManaged), .bool(\.ledHeartbeatEnabled, default: true), .int32(\.nodeInfoBroadcastSecs), .int32(\.rebroadcastMode), .int32(\.role), .bool(\.serialEnabled), .bool(\.tripleClickAsAdHocPing, default: true), .string(\.tzdef)],
			nodeConfig: { $0.deviceConfig },
			configNode: { $0.deviceConfigNode }
		) { obj -> DeviceConfigEntity in
			let sd = DeviceConfigEntity()
			sd.buttonGpio = (obj.value(forKey: "buttonGpio") as? Int32) ?? 0
			sd.buzzerGpio = (obj.value(forKey: "buzzerGpio") as? Int32) ?? 0
			sd.disableTripleClick = (obj.value(forKey: "disableTripleClick") as? Bool) ?? false
			sd.doubleTapAsButtonPress = (obj.value(forKey: "doubleTapAsButtonPress") as? Bool) ?? false
			sd.isManaged = (obj.value(forKey: "isManaged") as? Bool) ?? false
			sd.ledHeartbeatEnabled = (obj.value(forKey: "ledHeartbeatEnabled") as? Bool) ?? false
			sd.nodeInfoBroadcastSecs = (obj.value(forKey: "nodeInfoBroadcastSecs") as? Int32) ?? 0
			sd.rebroadcastMode = (obj.value(forKey: "rebroadcastMode") as? Int32) ?? 0
			sd.tripleClickAsAdHocPing = (obj.value(forKey: "tripleClickAsAdHocPing") as? Bool) ?? false
			sd.tzdef = obj.value(forKey: "tzdef") as? String
			sd.debugLogEnabled = (obj.value(forKey: "debugLogEnabled") as? Bool) ?? false
			sd.role            = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.serialEnabled   = (obj.value(forKey: "serialEnabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.deviceConfig = sdConfig
		}
	}

	static func migrateDisplayConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "DisplayConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "displayConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.compassNorthTop), .int32(\.displayMode), .bool(\.flipScreen), .bool(\.headingBold, default: true), .int32(\.oledType), .int32(\.screenCarouselInterval), .int32(\.screenOnSeconds), .int32(\.units), .bool(\.use12HClock), .bool(\.wakeOnTapOrMotion)],
			nodeConfig: { $0.displayConfig },
			configNode: { $0.displayConfigNode }
		) { obj -> DisplayConfigEntity in
			let sd = DisplayConfigEntity()
			sd.displayMode = (obj.value(forKey: "displayMode") as? Int32) ?? 0
			sd.headingBold = (obj.value(forKey: "headingBold") as? Bool) ?? false
			sd.oledType = (obj.value(forKey: "oledType") as? Int32) ?? 0
			sd.units = (obj.value(forKey: "units") as? Int32) ?? 0
			sd.use12HClock = (obj.value(forKey: "use12HClock") as? Bool) ?? false
			sd.wakeOnTapOrMotion = (obj.value(forKey: "wakeOnTapOrMotion") as? Bool) ?? false
			sd.compassNorthTop        = (obj.value(forKey: "compassNorthTop") as? Bool) ?? false
			sd.flipScreen             = (obj.value(forKey: "flipScreen") as? Bool) ?? false
			// gpsFormat was removed from the SwiftData model; skip it
			sd.screenCarouselInterval = (obj.value(forKey: "screenCarouselInterval") as? Int32) ?? 0
			sd.screenOnSeconds        = (obj.value(forKey: "screenOnSeconds") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.displayConfig = sdConfig
		}
	}

	static func migrateExternalNotifConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "ExternalNotificationConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "externalNotificationConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.active), .bool(\.alertBell), .bool(\.alertBellBuzzer), .bool(\.alertBellVibra), .bool(\.alertMessage), .bool(\.alertMessageBuzzer), .bool(\.alertMessageVibra), .bool(\.enabled), .int32(\.nagTimeout), .int32(\.output), .int32(\.outputBuzzer), .int32(\.outputMilliseconds), .int32(\.outputVibra), .bool(\.useI2SAsBuzzer), .bool(\.usePWM, default: true)],
			nodeConfig: { $0.externalNotificationConfig },
			configNode: { $0.externalNotificationConfigNode }
		) { obj -> ExternalNotificationConfigEntity in
			let sd = ExternalNotificationConfigEntity()
			sd.alertBellBuzzer = (obj.value(forKey: "alertBellBuzzer") as? Bool) ?? false
			sd.alertBellVibra = (obj.value(forKey: "alertBellVibra") as? Bool) ?? false
			sd.alertMessageBuzzer = (obj.value(forKey: "alertMessageBuzzer") as? Bool) ?? false
			sd.alertMessageVibra = (obj.value(forKey: "alertMessageVibra") as? Bool) ?? false
			sd.nagTimeout = (obj.value(forKey: "nagTimeout") as? Int32) ?? 0
			sd.outputBuzzer = (obj.value(forKey: "outputBuzzer") as? Int32) ?? 0
			sd.outputVibra = (obj.value(forKey: "outputVibra") as? Int32) ?? 0
			sd.useI2SAsBuzzer = (obj.value(forKey: "useI2SAsBuzzer") as? Bool) ?? false
			sd.usePWM = (obj.value(forKey: "usePWM") as? Bool) ?? false
			sd.active             = (obj.value(forKey: "active") as? Bool) ?? false
			sd.alertBell          = (obj.value(forKey: "alertBell") as? Bool) ?? false
			sd.alertMessage       = (obj.value(forKey: "alertMessage") as? Bool) ?? false
			sd.enabled            = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.output             = (obj.value(forKey: "output") as? Int32) ?? 0
			sd.outputMilliseconds = (obj.value(forKey: "outputMilliseconds") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.externalNotificationConfig = sdConfig
		}
	}

	static func migrateLoRaConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "LoRaConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "loRaConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [
				.int32(\.bandwidth), .int32(\.channelNum), .int32(\.codingRate),
				.float(\.frequencyOffset), .int32(\.hopLimit), .bool(\.ignoreMqtt),
				.int32(\.modemPreset), .bool(\.okToMqtt), .bool(\.overrideDutyCycle),
				.float(\.overrideFrequency), .int32(\.regionCode), .int32(\.spreadFactor),
				.bool(\.sx126xRxBoostedGain), .bool(\.txEnabled, default: true),
				.int32(\.txPower), .bool(\.usePreset, default: true)
			],
			nodeConfig: { $0.loRaConfig },
			configNode: { $0.loRaConfigNode }
		) { obj -> LoRaConfigEntity in
			let sd = LoRaConfigEntity()
			sd.ignoreMqtt = (obj.value(forKey: "ignoreMqtt") as? Bool) ?? false
			sd.okToMqtt = (obj.value(forKey: "okToMqtt") as? Bool) ?? false
			sd.overrideDutyCycle = (obj.value(forKey: "overrideDutyCycle") as? Bool) ?? false
			sd.overrideFrequency = (obj.value(forKey: "overrideFrequency") as? Float) ?? 0
			sd.sx126xRxBoostedGain = (obj.value(forKey: "sx126xRxBoostedGain") as? Bool) ?? false
			sd.bandwidth       = (obj.value(forKey: "bandwidth") as? Int32) ?? 0
			sd.channelNum      = (obj.value(forKey: "channelNum") as? Int32) ?? 0
			sd.codingRate      = (obj.value(forKey: "codingRate") as? Int32) ?? 0
			sd.frequencyOffset = (obj.value(forKey: "frequencyOffset") as? Float) ?? 0
			sd.hopLimit        = (obj.value(forKey: "hopLimit") as? Int32) ?? 0
			sd.modemPreset     = (obj.value(forKey: "modemPreset") as? Int32) ?? 0
			sd.regionCode      = (obj.value(forKey: "regionCode") as? Int32) ?? 0
			sd.spreadFactor    = (obj.value(forKey: "spreadFactor") as? Int32) ?? 0
			sd.txEnabled       = (obj.value(forKey: "txEnabled") as? Bool) ?? true
			sd.txPower         = (obj.value(forKey: "txPower") as? Int32) ?? 0
			sd.usePreset       = (obj.value(forKey: "usePreset") as? Bool) ?? true
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.loRaConfig = sdConfig
		}
	}

	static func migrateMQTTConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "MQTTConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "mqttConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.string(\.address), .bool(\.enabled), .bool(\.encryptionEnabled), .bool(\.jsonEnabled), .int32(\.mapPositionPrecision, default: 13), .int32(\.mapPublishIntervalSecs), .bool(\.mapReportingEnabled), .bool(\.mapReportingShouldReportLocation), .string(\.password), .bool(\.proxyToClientEnabled), .string(\.root, default: "msh"), .bool(\.tlsEnabled), .string(\.username)],
			nodeConfig: { $0.mqttConfig },
			configNode: { $0.mqttConfigNode }
		) { obj -> MQTTConfigEntity in
			let sd = MQTTConfigEntity()
			sd.mapPositionPrecision = (obj.value(forKey: "mapPositionPrecision") as? Int32) ?? 0
			sd.mapPublishIntervalSecs = (obj.value(forKey: "mapPublishIntervalSecs") as? Int32) ?? 0
			sd.mapReportingEnabled = (obj.value(forKey: "mapReportingEnabled") as? Bool) ?? false
			sd.mapReportingShouldReportLocation = (obj.value(forKey: "mapReportingShouldReportLocation") as? Bool) ?? false
			sd.proxyToClientEnabled = (obj.value(forKey: "proxyToClientEnabled") as? Bool) ?? false
			sd.root = obj.value(forKey: "root") as? String
			sd.tlsEnabled = (obj.value(forKey: "tlsEnabled") as? Bool) ?? false
			sd.address           = obj.value(forKey: "address") as? String
			sd.enabled           = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.encryptionEnabled = (obj.value(forKey: "encryptionEnabled") as? Bool) ?? false
			sd.jsonEnabled       = (obj.value(forKey: "jsonEnabled") as? Bool) ?? false
			sd.password          = obj.value(forKey: "password") as? String
			sd.username          = obj.value(forKey: "username") as? String
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.mqttConfig = sdConfig
		}
	}

	static func migrateNetworkConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "NetworkConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "networkConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.dns), .int32(\.enabledProtocols), .bool(\.ethEnabled), .int32(\.gateway), .int32(\.ip), .string(\.ntpServer), .int32(\.subnet), .bool(\.wifiEnabled), .int32(\.wifiMode), .string(\.wifiPsk), .string(\.wifiSsid)],
			nodeConfig: { $0.networkConfig },
			configNode: { $0.networkConfigNode }
		) { obj -> NetworkConfigEntity in
			let sd = NetworkConfigEntity()
			sd.dns = (obj.value(forKey: "dns") as? Int32) ?? 0
			sd.enabledProtocols = (obj.value(forKey: "enabledProtocols") as? Int32) ?? 0
			sd.ethEnabled = (obj.value(forKey: "ethEnabled") as? Bool) ?? false
			sd.gateway = (obj.value(forKey: "gateway") as? Int32) ?? 0
			sd.ip = (obj.value(forKey: "ip") as? Int32) ?? 0
			sd.subnet = (obj.value(forKey: "subnet") as? Int32) ?? 0
			sd.wifiMode = (obj.value(forKey: "wifiMode") as? Int32) ?? 0
			sd.ntpServer   = obj.value(forKey: "ntpServer") as? String
			sd.wifiEnabled = (obj.value(forKey: "wifiEnabled") as? Bool) ?? false
			sd.wifiPsk     = obj.value(forKey: "wifiPsk") as? String
			sd.wifiSsid    = obj.value(forKey: "wifiSsid") as? String
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.networkConfig = sdConfig
		}
	}

	static func migratePositionConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "PositionConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "positionConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.broadcastSmartMinimumDistance), .int32(\.broadcastSmartMinimumIntervalSecs), .bool(\.deviceGpsEnabled), .bool(\.fixedPosition), .int32(\.gpsAttemptTime), .int32(\.gpsEnGpio), .int32(\.gpsMode), .int32(\.gpsUpdateInterval), .int32(\.positionBroadcastSeconds), .int32(\.positionFlags), .int32(\.rxGpio), .bool(\.smartPositionEnabled), .int32(\.txGpio)],
			nodeConfig: { $0.positionConfig },
			configNode: { $0.positionConfigNode }
		) { obj -> PositionConfigEntity in
			let sd = PositionConfigEntity()
			sd.broadcastSmartMinimumDistance = (obj.value(forKey: "broadcastSmartMinimumDistance") as? Int32) ?? 0
			sd.broadcastSmartMinimumIntervalSecs = (obj.value(forKey: "broadcastSmartMinimumIntervalSecs") as? Int32) ?? 0
			sd.gpsEnGpio = (obj.value(forKey: "gpsEnGpio") as? Int32) ?? 0
			sd.gpsMode = (obj.value(forKey: "gpsMode") as? Int32) ?? 0
			sd.rxGpio = (obj.value(forKey: "rxGpio") as? Int32) ?? 0
			sd.txGpio = (obj.value(forKey: "txGpio") as? Int32) ?? 0
			sd.deviceGpsEnabled           = (obj.value(forKey: "deviceGpsEnabled") as? Bool) ?? false
			sd.fixedPosition              = (obj.value(forKey: "fixedPosition") as? Bool) ?? false
			sd.gpsAttemptTime             = (obj.value(forKey: "gpsAttemptTime") as? Int32) ?? 0
			sd.gpsUpdateInterval          = (obj.value(forKey: "gpsUpdateInterval") as? Int32) ?? 0
			sd.positionBroadcastSeconds   = (obj.value(forKey: "positionBroadcastSeconds") as? Int32) ?? 0
			sd.positionFlags              = (obj.value(forKey: "positionFlags") as? Int32) ?? 0
			sd.smartPositionEnabled       = (obj.value(forKey: "smartPositionEnabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.positionConfig = sdConfig
		}
	}

	static func migrateRangeTestConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "RangeTestConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "rangeTestConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.enabled), .bool(\.save), .int32(\.sender)],
			nodeConfig: { $0.rangeTestConfig },
			configNode: { $0.rangeTestConfigNode }
		) { obj -> RangeTestConfigEntity in
			let sd = RangeTestConfigEntity()
			sd.enabled = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.save    = (obj.value(forKey: "save") as? Bool) ?? false
			sd.sender  = (obj.value(forKey: "sender") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.rangeTestConfig = sdConfig
		}
	}

	static func migrateSerialConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "SerialConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "serialConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.int32(\.baudRate), .bool(\.echo), .bool(\.enabled), .int32(\.mode), .bool(\.overrideConsoleSerialPort), .int32(\.rxd), .int32(\.timeout), .int32(\.txd)],
			nodeConfig: { $0.serialConfig },
			configNode: { $0.serialConfigNode }
		) { obj -> SerialConfigEntity in
			let sd = SerialConfigEntity()
			sd.overrideConsoleSerialPort = (obj.value(forKey: "overrideConsoleSerialPort") as? Bool) ?? false
			sd.baudRate = (obj.value(forKey: "baudRate") as? Int32) ?? 0
			sd.echo     = (obj.value(forKey: "echo") as? Bool) ?? false
			sd.enabled  = (obj.value(forKey: "enabled") as? Bool) ?? false
			sd.mode     = (obj.value(forKey: "mode") as? Int32) ?? 0
			sd.rxd      = (obj.value(forKey: "rxd") as? Int32) ?? 0
			sd.timeout  = (obj.value(forKey: "timeout") as? Int32) ?? 0
			sd.txd      = (obj.value(forKey: "txd") as? Int32) ?? 0
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.serialConfig = sdConfig
		}
	}

	static func migrateTelemetryConfigs(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "TelemetryConfigEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "telemetryConfigNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.deviceTelemetryEnabled), .int32(\.deviceUpdateInterval), .bool(\.environmentDisplayFahrenheit), .bool(\.environmentMeasurementEnabled), .bool(\.environmentScreenEnabled), .int32(\.environmentUpdateInterval), .bool(\.powerMeasurementEnabled), .bool(\.powerScreenEnabled), .int32(\.powerUpdateInterval)],
			nodeConfig: { $0.telemetryConfig },
			configNode: { $0.telemetryConfigNode }
		) { obj -> TelemetryConfigEntity in
			let sd = TelemetryConfigEntity()
			sd.deviceTelemetryEnabled = (obj.value(forKey: "deviceTelemetryEnabled") as? Bool) ?? false
			sd.environmentScreenEnabled = (obj.value(forKey: "environmentScreenEnabled") as? Bool) ?? false
			sd.environmentUpdateInterval = (obj.value(forKey: "environmentUpdateInterval") as? Int32) ?? 0
			sd.powerMeasurementEnabled = (obj.value(forKey: "powerMeasurementEnabled") as? Bool) ?? false
			sd.powerScreenEnabled = (obj.value(forKey: "powerScreenEnabled") as? Bool) ?? false
			sd.powerUpdateInterval = (obj.value(forKey: "powerUpdateInterval") as? Int32) ?? 0
			sd.deviceUpdateInterval           = (obj.value(forKey: "deviceUpdateInterval") as? Int32) ?? 0
			sd.environmentDisplayFahrenheit   = (obj.value(forKey: "environmentDisplayFahrenheit") as? Bool) ?? false
			sd.environmentMeasurementEnabled  = (obj.value(forKey: "environmentMeasurementEnabled") as? Bool) ?? false
			return sd
		} wireNode: { sdNode, sdConfig in
			sdNode.telemetryConfig = sdConfig
		}
	}

	// MARK: Remaining legacy entities

	static func migrateDeviceMetadata(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state: MergeState
	) throws {
		try migrateConfigEntity(
			entityName: "DeviceMetadataEntity",
			cdContext: cdContext,
			sdContext: sdContext,
			nodeKey: "metadataNode",
			nodeMap: nodeMap,
			state: state,
			fields: [.bool(\.canShutdown), .int32(\.deviceStateVersion), .int32(\.excludedModules), .string(\.firmwareVersion), .bool(\.hasBluetooth), .bool(\.hasEthernet), .bool(\.hasWifi), .string(\.hwModel), .int32(\.positionFlags), .int32(\.role), .date(\.time)],
			nodeConfig: { $0.metadata },
			configNode: { $0.metadataNode }
		) { obj -> DeviceMetadataEntity in
			let sd = DeviceMetadataEntity()
			sd.canShutdown = (obj.value(forKey: "canShutdown") as? Bool) ?? false
			sd.deviceStateVersion = (obj.value(forKey: "deviceStateVersion") as? Int32) ?? 0
			sd.excludedModules = (obj.value(forKey: "excludedModules") as? Int32) ?? 0
			sd.firmwareVersion = obj.value(forKey: "firmwareVersion") as? String
			sd.hasBluetooth = (obj.value(forKey: "hasBluetooth") as? Bool) ?? false
			sd.hasEthernet = (obj.value(forKey: "hasEthernet") as? Bool) ?? false
			sd.hasWifi = (obj.value(forKey: "hasWifi") as? Bool) ?? false
			sd.hwModel = obj.value(forKey: "hwModel") as? String
			sd.positionFlags = (obj.value(forKey: "positionFlags") as? Int32) ?? 0
			sd.role = (obj.value(forKey: "role") as? Int32) ?? 0
			sd.time = obj.value(forKey: "time") as? Date
			return sd
		} wireNode: { node, metadata in
			node.metadata = metadata
		}
	}

	static func migratePaxCounters(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		let request = NSFetchRequest<NSManagedObject>(entityName: "PaxCounterEntity")
		let objects = try cdContext.fetch(request)
		var destinationCounts: [PaxFingerprint: Int] = [:]
		for pax in try sdContext.fetch(FetchDescriptor<PaxCounterEntity>()) {
			destinationCounts[PaxFingerprint(pax), default: 0] += 1
		}
		var sourceCounts: [PaxFingerprint: Int] = [:]
		for object in objects {
			let node = (object.value(forKey: "paxNode") as? NSManagedObject)
				.flatMap { nodeMap[$0.objectID] }
			let fingerprint = PaxFingerprint(coreDataObject: object, nodeNum: node?.num)
			sourceCounts[fingerprint, default: 0] += 1
			guard sourceCounts[fingerprint, default: 0] > destinationCounts[fingerprint, default: 0] else {
				continue
			}
			let sd = PaxCounterEntity()
			sd.ble = (object.value(forKey: "ble") as? Int32) ?? 0
			sd.time = object.value(forKey: "time") as? Date
			sd.uptime = (object.value(forKey: "uptime") as? Int32) ?? 0
			sd.wifi = (object.value(forKey: "wifi") as? Int32) ?? 0
			sd.paxNode = node
			sdContext.insert(sd)
		}
	}

	static func migrateRoutes(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext
	) throws {
		let request = NSFetchRequest<NSManagedObject>(entityName: "RouteEntity")
		request.relationshipKeyPathsForPrefetching = ["locations"]
		var destinationRoutes: [RouteGraphFingerprint: [RouteEntity]] = [:]
		for route in try sdContext.fetch(FetchDescriptor<RouteEntity>()) {
			destinationRoutes[RouteGraphFingerprint(route), default: []].append(route)
		}
		var sourceCounts: [RouteGraphFingerprint: Int] = [:]
		for object in try cdContext.fetch(request) {
			let fingerprint = RouteGraphFingerprint(coreDataObject: object)
			let occurrence = sourceCounts[fingerprint, default: 0]
			sourceCounts[fingerprint] = occurrence + 1
			if occurrence < destinationRoutes[fingerprint, default: []].count {
				continue
			}
			let route = makeRoute(from: object)
			sdContext.insert(route)
			for legacyLocation in legacyLocations(for: object) {
				let location = makeLocation(from: legacyLocation)
				location.routeLocation = route
				sdContext.insert(location)
			}
		}

		let orphanRequest = NSFetchRequest<NSManagedObject>(entityName: "LocationEntity")
		orphanRequest.predicate = NSPredicate(format: "routeLocation == nil")
		var destinationOrphans: [LocationFingerprint: Int] = [:]
		for location in try sdContext.fetch(FetchDescriptor<LocationEntity>()).filter({ $0.routeLocation == nil }) {
			destinationOrphans[LocationFingerprint(location), default: 0] += 1
		}
		var sourceOrphans: [LocationFingerprint: Int] = [:]
		for object in try cdContext.fetch(orphanRequest) {
			let fingerprint = LocationFingerprint(coreDataObject: object)
			sourceOrphans[fingerprint, default: 0] += 1
			guard sourceOrphans[fingerprint, default: 0] > destinationOrphans[fingerprint, default: 0] else {
				continue
			}
			sdContext.insert(makeLocation(from: object))
		}
	}

	static func legacyLocations(for route: NSManagedObject) -> [NSManagedObject] {
		((route.value(forKey: "locations") as? NSOrderedSet)?.array ?? []).compactMap { $0 as? NSManagedObject }
	}

	static func makeRoute(from object: NSManagedObject) -> RouteEntity {
		let route = RouteEntity()
		route.color = (object.value(forKey: "color") as? Int64) ?? 0
		route.date = object.value(forKey: "date") as? Date
		route.distance = (object.value(forKey: "distance") as? Double) ?? 0
		route.elevationGain = (object.value(forKey: "elevationGain") as? Double) ?? 0
		route.enabled = (object.value(forKey: "enabled") as? Bool) ?? false
		route.endDate = object.value(forKey: "endDate") as? Date
		route.id = (object.value(forKey: "id") as? Int32) ?? 0
		route.name = object.value(forKey: "name") as? String
		route.notes = object.value(forKey: "notes") as? String
		return route
	}

	static func makeLocation(from object: NSManagedObject) -> LocationEntity {
		let location = LocationEntity()
		location.altitude = (object.value(forKey: "altitude") as? Int32) ?? 0
		location.heading = (object.value(forKey: "heading") as? Int32) ?? 0
		location.id = (object.value(forKey: "id") as? Int32) ?? 0
		location.latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0
		location.longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0
		location.speed = (object.value(forKey: "speed") as? Int32) ?? 0
		return location
	}

	static func migrateTraceRoutes(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeMap: [NSManagedObjectID: NodeInfoEntity]
	) throws {
		let request = NSFetchRequest<NSManagedObject>(entityName: "TraceRouteEntity")
		request.relationshipKeyPathsForPrefetching = ["hops", "node"]
		var destinationRoutes: [TraceRouteGraphFingerprint: Int] = [:]
		for route in try sdContext.fetch(FetchDescriptor<TraceRouteEntity>()) {
			destinationRoutes[TraceRouteGraphFingerprint(route), default: 0] += 1
		}
		var sourceRoutes: [TraceRouteGraphFingerprint: Int] = [:]
		for object in try cdContext.fetch(request) {
			let nodeNum = (object.value(forKey: "node") as? NSManagedObject)
				.flatMap { nodeMap[$0.objectID] }?.num
			let fingerprint = TraceRouteGraphFingerprint(coreDataObject: object, nodeNum: nodeNum)
			sourceRoutes[fingerprint, default: 0] += 1
			guard sourceRoutes[fingerprint, default: 0] > destinationRoutes[fingerprint, default: 0] else {
				continue
			}
			let route = makeTraceRoute(from: object)
			if let legacyNode = object.value(forKey: "node") as? NSManagedObject,
			   let node = nodeMap[legacyNode.objectID] {
				route.node = node
				route.toNum = node.num
			}
			sdContext.insert(route)

			for (index, legacyHop) in legacyTraceHops(for: object).enumerated() {
				let hop = makeTraceHop(from: legacyHop, index: index)
				hop.traceRoute = route
				sdContext.insert(hop)
				let position = makeTracePosition(from: legacyHop)
				position.traceRoute = route
				sdContext.insert(position)
			}
		}

		let orphanRequest = NSFetchRequest<NSManagedObject>(entityName: "TraceRouteHopEntity")
		orphanRequest.predicate = NSPredicate(format: "traceRoute == nil")
		var destinationHops: [TraceHopScalarFingerprint: Int] = [:]
		for hop in try sdContext.fetch(FetchDescriptor<TraceRouteHopEntity>()).filter({ $0.traceRoute == nil }) {
			destinationHops[TraceHopScalarFingerprint(hop), default: 0] += 1
		}
		var destinationPositions: [TracePositionFingerprint: Int] = [:]
		for position in try sdContext.fetch(FetchDescriptor<TraceRouteNodePositionEntity>())
			.filter({ $0.traceRoute == nil }) {
			destinationPositions[TracePositionFingerprint(position), default: 0] += 1
		}
		var sourceHops: [TraceHopScalarFingerprint: Int] = [:]
		var sourcePositions: [TracePositionFingerprint: Int] = [:]
		for object in try cdContext.fetch(orphanRequest) {
			let hopFingerprint = TraceHopScalarFingerprint(coreDataObject: object, index: 0)
			sourceHops[hopFingerprint, default: 0] += 1
			if sourceHops[hopFingerprint, default: 0] > destinationHops[hopFingerprint, default: 0] {
				sdContext.insert(makeTraceHop(from: object, index: 0))
			}
			let positionFingerprint = TracePositionFingerprint(coreDataObject: object)
			sourcePositions[positionFingerprint, default: 0] += 1
			if sourcePositions[positionFingerprint, default: 0] > destinationPositions[positionFingerprint, default: 0] {
				sdContext.insert(makeTracePosition(from: object))
			}
		}
	}

	static func legacyTraceHops(for route: NSManagedObject) -> [NSManagedObject] {
		((route.value(forKey: "hops") as? NSOrderedSet)?.array ?? []).compactMap { $0 as? NSManagedObject }
	}

	static func makeTraceRoute(from object: NSManagedObject) -> TraceRouteEntity {
		let route = TraceRouteEntity()
		route.hasPositions = (object.value(forKey: "hasPositions") as? Bool) ?? false
		route.hopsBack = (object.value(forKey: "hopsBack") as? Int32) ?? 0
		route.hopsTowards = (object.value(forKey: "hopsTowards") as? Int32) ?? 0
		route.id = (object.value(forKey: "id") as? Int64) ?? 0
		route.response = (object.value(forKey: "response") as? Bool) ?? false
		route.routeBackText = object.value(forKey: "routeBackText") as? String
		route.routeText = object.value(forKey: "routeText") as? String
		route.sent = (object.value(forKey: "sent") as? Bool) ?? false
		route.snr = (object.value(forKey: "snr") as? Float) ?? 0
		route.time = object.value(forKey: "time") as? Date
		return route
	}

	static func makeTraceHop(from object: NSManagedObject, index: Int) -> TraceRouteHopEntity {
		let hop = TraceRouteHopEntity()
		hop.back = (object.value(forKey: "back") as? Bool) ?? false
		hop.index = Int32(index)
		hop.name = object.value(forKey: "name") as? String
		hop.num = (object.value(forKey: "num") as? Int64) ?? 0
		hop.snr = (object.value(forKey: "snr") as? Float) ?? 0
		hop.time = object.value(forKey: "time") as? Date
		return hop
	}

	static func makeTracePosition(from object: NSManagedObject) -> TraceRouteNodePositionEntity {
		let position = TraceRouteNodePositionEntity()
		position.num = (object.value(forKey: "num") as? Int64) ?? 0
		position.altitude = (object.value(forKey: "altitude") as? Int32) ?? 0
		position.latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0
		position.longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0
		position.snr = (object.value(forKey: "snr") as? Float) ?? 0
		position.time = object.value(forKey: "time") as? Date
		return position
	}

	static func migrateWaypoints(
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext
	) throws {
		let request = NSFetchRequest<NSManagedObject>(entityName: "WaypointEntity")
		let existingById = Dictionary(
			uniqueKeysWithValues: try sdContext.fetch(FetchDescriptor<WaypointEntity>()).map { ($0.id, $0) }
		)
		for object in try cdContext.fetch(request) {
			let id = (object.value(forKey: "id") as? Int64) ?? 0
			if let existing = existingById[id] {
				mergeMissingWaypointFields(from: object, into: existing)
				continue
			}
			let waypoint = WaypointEntity()
			waypoint.created = object.value(forKey: "created") as? Date
			waypoint.createdBy = (object.value(forKey: "createdBy") as? Int64) ?? 0
			waypoint.expire = object.value(forKey: "expire") as? Date
			waypoint.icon = (object.value(forKey: "icon") as? Int64) ?? 0
			waypoint.id = id
			waypoint.lastUpdated = object.value(forKey: "lastUpdated") as? Date
			waypoint.lastUpdatedBy = (object.value(forKey: "lastUpdatedBy") as? Int64) ?? 0
			waypoint.latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0
			waypoint.locked = ((object.value(forKey: "locked") as? Int64) ?? 0) != 0
			waypoint.longDescription = object.value(forKey: "longDescription") as? String
			waypoint.longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0
			waypoint.name = object.value(forKey: "name") as? String
			sdContext.insert(waypoint)
		}
	}

	static func mergeMissingWaypointFields(from object: NSManagedObject, into waypoint: WaypointEntity) {
		waypoint.created = waypoint.created ?? object.value(forKey: "created") as? Date
		if waypoint.createdBy == 0 { waypoint.createdBy = (object.value(forKey: "createdBy") as? Int64) ?? 0 }
		waypoint.expire = waypoint.expire ?? object.value(forKey: "expire") as? Date
		if waypoint.icon == 0 { waypoint.icon = (object.value(forKey: "icon") as? Int64) ?? 0 }
		waypoint.lastUpdated = waypoint.lastUpdated ?? object.value(forKey: "lastUpdated") as? Date
		if waypoint.lastUpdatedBy == 0 { waypoint.lastUpdatedBy = (object.value(forKey: "lastUpdatedBy") as? Int64) ?? 0 }
		if waypoint.latitudeI == 0 { waypoint.latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0 }
		waypoint.locked = waypoint.locked || (((object.value(forKey: "locked") as? Int64) ?? 0) != 0)
		waypoint.longDescription = waypoint.longDescription ?? object.value(forKey: "longDescription") as? String
		if waypoint.longitudeI == 0 { waypoint.longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0 }
		waypoint.name = waypoint.name ?? object.value(forKey: "name") as? String
	}

	// MARK: Generic config helper

	/// Generic helper that fetches a config entity, creates the SwiftData
	/// counterpart via `make`, inserts it, and links it to its parent node via
	/// `wireNode`.
	// swiftlint:disable:next function_parameter_count
	static func migrateConfigEntity<T: PersistentModel>(
		entityName: String,
		cdContext: NSManagedObjectContext,
		sdContext: ModelContext,
		nodeKey: String,
		nodeMap: [NSManagedObjectID: NodeInfoEntity],
		state _: MergeState,
		fields: [LegacyConfigField<T>],
		nodeConfig: (NodeInfoEntity) -> T?,
		configNode: (T) -> NodeInfoEntity?,
		make: (NSManagedObject) throws -> T,
		wireNode: (NodeInfoEntity, T) -> Void
	) throws {
		let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
		let objects = try cdContext.fetch(request)
		var destinationOrphans: [Data: Int] = [:]
		for config in try sdContext.fetch(FetchDescriptor<T>()) where configNode(config) == nil {
			destinationOrphans[configFingerprint(config, fields: fields), default: 0] += 1
		}
		var sourceOrphans: [Data: Int] = [:]

		var migrated = 0
		for obj in objects {
			let source = try make(obj)
			let cdNode = obj.value(forKey: nodeKey) as? NSManagedObject
			let sdNode = cdNode.flatMap { nodeMap[$0.objectID] }
			if let sdNode, let destination = nodeConfig(sdNode) {
				for field in fields {
					field.mergeMissing(source, destination)
				}
				continue
			}
			if sdNode == nil {
				let fingerprint = configFingerprint(source, fields: fields)
				sourceOrphans[fingerprint, default: 0] += 1
				guard sourceOrphans[fingerprint, default: 0] > destinationOrphans[fingerprint, default: 0] else {
					continue
				}
			}
			if let sdNode {
				wireNode(sdNode, source)
			}
			sdContext.insert(source)
			migrated += 1
		}
		Logger.data.info("⬆️ migrated \(migrated) of \(objects.count) \(entityName) records")
	}

	static func configFingerprint<T>(_ config: T, fields: [LegacyConfigField<T>]) -> Data {
		var encoder = FingerprintEncoder()
		for field in fields {
			field.appendValue(config, &encoder)
		}
		return encoder.data
	}
}

// MARK: - Retry fingerprints

private struct LegacyConfigField<Model> {
	let appendValue: (Model, inout FingerprintEncoder) -> Void
	let mergeMissing: (Model, Model) -> Void

	static func bool(
		_ keyPath: ReferenceWritableKeyPath<Model, Bool>,
		default defaultValue: Bool = false
	) -> Self {
		Self(
			appendValue: { model, encoder in encoder.append(model[keyPath: keyPath]) },
			mergeMissing: { source, destination in
				if destination[keyPath: keyPath] == defaultValue {
					destination[keyPath: keyPath] = source[keyPath: keyPath]
				}
			}
		)
	}

	static func int32(
		_ keyPath: ReferenceWritableKeyPath<Model, Int32>,
		default defaultValue: Int32 = 0
	) -> Self {
		Self(
			appendValue: { model, encoder in encoder.append(model[keyPath: keyPath]) },
			mergeMissing: { source, destination in
				if destination[keyPath: keyPath] == defaultValue {
					destination[keyPath: keyPath] = source[keyPath: keyPath]
				}
			}
		)
	}

	static func float(
		_ keyPath: ReferenceWritableKeyPath<Model, Float>,
		default defaultValue: Float = 0
	) -> Self {
		Self(
			appendValue: { model, encoder in encoder.append(model[keyPath: keyPath].bitPattern) },
			mergeMissing: { source, destination in
				if destination[keyPath: keyPath].bitPattern == defaultValue.bitPattern {
					destination[keyPath: keyPath] = source[keyPath: keyPath]
				}
			}
		)
	}

	static func string(
		_ keyPath: ReferenceWritableKeyPath<Model, String?>,
		default defaultValue: String? = nil
	) -> Self {
		Self(
			appendValue: { model, encoder in encoder.append(model[keyPath: keyPath]) },
			mergeMissing: { source, destination in
				if destination[keyPath: keyPath] == defaultValue {
					destination[keyPath: keyPath] = source[keyPath: keyPath]
				}
			}
		)
	}

	static func data(_ keyPath: ReferenceWritableKeyPath<Model, Data?>) -> Self {
		Self(
			appendValue: { model, encoder in encoder.append(model[keyPath: keyPath]) },
			mergeMissing: { source, destination in
				if destination[keyPath: keyPath] == nil {
					destination[keyPath: keyPath] = source[keyPath: keyPath]
				}
			}
		)
	}

	static func date(_ keyPath: ReferenceWritableKeyPath<Model, Date?>) -> Self {
		Self(
			appendValue: { model, encoder in encoder.append(model[keyPath: keyPath]) },
			mergeMissing: { source, destination in
				if destination[keyPath: keyPath] == nil {
					destination[keyPath: keyPath] = source[keyPath: keyPath]
				}
			}
		)
	}
}

private struct MessageUserLink {
	let fromNum: Int64?
	let toNum: Int64?
}

private struct ChannelFingerprint: Hashable {
	let myNodeNum: Int64?
	let downlinkEnabled: Bool
	let id: Int32
	let index: Int32
	let mute: Bool
	let name: String?
	let positionPrecision: Int32
	let psk: Data?
	let role: Int32
	let uplinkEnabled: Bool

	init(_ channel: ChannelEntity) {
		myNodeNum = channel.myInfoChannel?.myNodeNum
		downlinkEnabled = channel.downlinkEnabled
		id = channel.id
		index = channel.index
		mute = channel.mute
		name = channel.name
		positionPrecision = channel.positionPrecision
		psk = channel.psk
		role = channel.role
		uplinkEnabled = channel.uplinkEnabled
	}

	init(coreDataObject object: NSManagedObject, myNodeNum: Int64?) {
		self.myNodeNum = myNodeNum
		downlinkEnabled = (object.value(forKey: "downlinkEnabled") as? Bool) ?? false
		id = (object.value(forKey: "id") as? Int32) ?? 0
		index = (object.value(forKey: "index") as? Int32) ?? 0
		mute = (object.value(forKey: "mute") as? Bool) ?? false
		name = object.value(forKey: "name") as? String
		positionPrecision = (object.value(forKey: "positionPrecision") as? Int32) ?? 32
		psk = object.value(forKey: "psk") as? Data
		role = (object.value(forKey: "role") as? Int32) ?? 0
		uplinkEnabled = (object.value(forKey: "uplinkEnabled") as? Bool) ?? false
	}
}

private struct LocationFingerprint: Hashable {
	let altitude: Int32
	let heading: Int32
	let id: Int32
	let latitudeI: Int32
	let longitudeI: Int32
	let speed: Int32

	var replayKey: Data {
		var encoder = FingerprintEncoder()
		encoder.append(altitude)
		encoder.append(heading)
		encoder.append(id)
		encoder.append(latitudeI)
		encoder.append(longitudeI)
		encoder.append(speed)
		return encoder.data
	}

	init(_ location: LocationEntity) {
		altitude = location.altitude
		heading = location.heading
		id = location.id
		latitudeI = location.latitudeI
		longitudeI = location.longitudeI
		speed = location.speed
	}

	init(coreDataObject object: NSManagedObject) {
		altitude = (object.value(forKey: "altitude") as? Int32) ?? 0
		heading = (object.value(forKey: "heading") as? Int32) ?? 0
		id = (object.value(forKey: "id") as? Int32) ?? 0
		latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0
		longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0
		speed = (object.value(forKey: "speed") as? Int32) ?? 0
	}
}

private struct RouteGraphFingerprint: Hashable {
	let color: Int64
	let date: Date?
	let distance: UInt64
	let elevationGain: UInt64
	let enabled: Bool
	let endDate: Date?
	let id: Int32
	let name: String?
	let notes: String?
	let locationKeys: [Data]

	init(_ route: RouteEntity) {
		color = route.color
		date = route.date
		distance = route.distance.bitPattern
		elevationGain = route.elevationGain.bitPattern
		enabled = route.enabled
		endDate = route.endDate
		id = route.id
		name = route.name
		notes = route.notes
		locationKeys = route.locations.map { LocationFingerprint($0).replayKey }
			.sorted { $0.lexicographicallyPrecedes($1) }
	}

	init(coreDataObject object: NSManagedObject) {
		color = (object.value(forKey: "color") as? Int64) ?? 0
		date = object.value(forKey: "date") as? Date
		distance = ((object.value(forKey: "distance") as? Double) ?? 0).bitPattern
		elevationGain = ((object.value(forKey: "elevationGain") as? Double) ?? 0).bitPattern
		enabled = (object.value(forKey: "enabled") as? Bool) ?? false
		endDate = object.value(forKey: "endDate") as? Date
		id = (object.value(forKey: "id") as? Int32) ?? 0
		name = object.value(forKey: "name") as? String
		notes = object.value(forKey: "notes") as? String
		locationKeys = CoreDataMigrationService.legacyLocations(for: object)
			.map { LocationFingerprint(coreDataObject: $0).replayKey }
			.sorted { $0.lexicographicallyPrecedes($1) }
	}
}

private struct TraceHopScalarFingerprint: Hashable {
	let back: Bool
	let index: Int32
	let name: String?
	let num: Int64
	let snr: UInt32
	let time: Date?

	var replayKey: Data {
		var encoder = FingerprintEncoder()
		encoder.append(back)
		encoder.append(index)
		encoder.append(name)
		encoder.append(num)
		encoder.append(snr)
		encoder.append(time)
		return encoder.data
	}

	init(_ hop: TraceRouteHopEntity) {
		back = hop.back
		index = hop.index
		name = hop.name
		num = hop.num
		snr = hop.snr.bitPattern
		time = hop.time
	}

	init(coreDataObject object: NSManagedObject, index: Int) {
		back = (object.value(forKey: "back") as? Bool) ?? false
		self.index = Int32(index)
		name = object.value(forKey: "name") as? String
		num = (object.value(forKey: "num") as? Int64) ?? 0
		snr = ((object.value(forKey: "snr") as? Float) ?? 0).bitPattern
		time = object.value(forKey: "time") as? Date
	}
}

private struct TracePositionFingerprint: Hashable {
	let num: Int64
	let altitude: Int32
	let latitudeI: Int32
	let longitudeI: Int32
	let snr: UInt32
	let time: Date?

	var replayKey: Data {
		var encoder = FingerprintEncoder()
		encoder.append(num)
		encoder.append(altitude)
		encoder.append(latitudeI)
		encoder.append(longitudeI)
		encoder.append(snr)
		encoder.append(time)
		return encoder.data
	}

	init(_ position: TraceRouteNodePositionEntity) {
		num = position.num
		altitude = position.altitude
		latitudeI = position.latitudeI
		longitudeI = position.longitudeI
		snr = position.snr.bitPattern
		time = position.time
	}

	init(coreDataObject object: NSManagedObject) {
		num = (object.value(forKey: "num") as? Int64) ?? 0
		altitude = (object.value(forKey: "altitude") as? Int32) ?? 0
		latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0
		longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0
		snr = ((object.value(forKey: "snr") as? Float) ?? 0).bitPattern
		time = object.value(forKey: "time") as? Date
	}
}

private struct TraceRouteGraphFingerprint: Hashable {
	let hasPositions: Bool
	let hopsBack: Int32
	let hopsTowards: Int32
	let id: Int64
	let response: Bool
	let routeBackText: String?
	let routeText: String?
	let sent: Bool
	let snr: UInt32
	let time: Date?
	let nodeNum: Int64?
	let hopKeys: [Data]
	let positionKeys: [Data]

	init(_ route: TraceRouteEntity) {
		hasPositions = route.hasPositions
		hopsBack = route.hopsBack
		hopsTowards = route.hopsTowards
		id = route.id
		response = route.response
		routeBackText = route.routeBackText
		routeText = route.routeText
		sent = route.sent
		snr = route.snr.bitPattern
		time = route.time
		nodeNum = route.node?.num
		hopKeys = route.hops.map { TraceHopScalarFingerprint($0).replayKey }
			.sorted { $0.lexicographicallyPrecedes($1) }
		positionKeys = route.nodePositions.map { TracePositionFingerprint($0).replayKey }
			.sorted { $0.lexicographicallyPrecedes($1) }
	}

	init(coreDataObject object: NSManagedObject, nodeNum: Int64?) {
		hasPositions = (object.value(forKey: "hasPositions") as? Bool) ?? false
		hopsBack = (object.value(forKey: "hopsBack") as? Int32) ?? 0
		hopsTowards = (object.value(forKey: "hopsTowards") as? Int32) ?? 0
		id = (object.value(forKey: "id") as? Int64) ?? 0
		response = (object.value(forKey: "response") as? Bool) ?? false
		routeBackText = object.value(forKey: "routeBackText") as? String
		routeText = object.value(forKey: "routeText") as? String
		sent = (object.value(forKey: "sent") as? Bool) ?? false
		snr = ((object.value(forKey: "snr") as? Float) ?? 0).bitPattern
		time = object.value(forKey: "time") as? Date
		self.nodeNum = nodeNum
		let hops = CoreDataMigrationService.legacyTraceHops(for: object)
		hopKeys = hops.enumerated().map { TraceHopScalarFingerprint(coreDataObject: $0.element, index: $0.offset).replayKey }
			.sorted { $0.lexicographicallyPrecedes($1) }
		positionKeys = hops.map { TracePositionFingerprint(coreDataObject: $0).replayKey }
			.sorted { $0.lexicographicallyPrecedes($1) }
	}
}

private struct PaxFingerprint: Hashable {
	let nodeNum: Int64?
	let ble: Int32
	let time: Date?
	let uptime: Int32
	let wifi: Int32

	init(_ pax: PaxCounterEntity) {
		nodeNum = pax.paxNode?.num
		ble = pax.ble
		time = pax.time
		uptime = pax.uptime
		wifi = pax.wifi
	}

	init(coreDataObject object: NSManagedObject, nodeNum: Int64?) {
		self.nodeNum = nodeNum
		ble = (object.value(forKey: "ble") as? Int32) ?? 0
		time = object.value(forKey: "time") as? Date
		uptime = (object.value(forKey: "uptime") as? Int32) ?? 0
		wifi = (object.value(forKey: "wifi") as? Int32) ?? 0
	}
}

private struct PositionFingerprint: Hashable {
	let nodeNum: Int64?
	let altitude: Int32
	let heading: Int32
	let latest: Bool
	let latitudeI: Int32
	let longitudeI: Int32
	let precisionBits: Int32
	let rssi: Int32
	let satsInView: Int32
	let seqNo: Int32
	let snr: UInt32
	let speed: Int32
	let time: Date?

	var replayKey: Data {
		var encoder = FingerprintEncoder()
		encoder.append(nodeNum)
		encoder.append(altitude)
		encoder.append(heading)
		encoder.append(latest)
		encoder.append(latitudeI)
		encoder.append(longitudeI)
		encoder.append(precisionBits)
		encoder.append(rssi)
		encoder.append(satsInView)
		encoder.append(seqNo)
		encoder.append(snr)
		encoder.append(speed)
		encoder.append(time)
		return encoder.data
	}

	init(_ position: PositionEntity) {
		nodeNum = position.nodePosition?.num
		altitude = position.altitude
		heading = position.heading
		latest = position.latest
		latitudeI = position.latitudeI
		longitudeI = position.longitudeI
		precisionBits = position.precisionBits
		rssi = position.rssi
		satsInView = position.satsInView
		seqNo = position.seqNo
		snr = position.snr.bitPattern
		speed = position.speed
		time = position.time
	}

	init(coreDataObject object: NSManagedObject, nodeNum: Int64?) {
		self.nodeNum = nodeNum
		altitude = (object.value(forKey: "altitude") as? Int32) ?? 0
		heading = (object.value(forKey: "heading") as? Int32) ?? 0
		latest = (object.value(forKey: "latest") as? Bool) ?? false
		latitudeI = (object.value(forKey: "latitudeI") as? Int32) ?? 0
		longitudeI = (object.value(forKey: "longitudeI") as? Int32) ?? 0
		precisionBits = (object.value(forKey: "precisionBits") as? Int32) ?? 32
		rssi = (object.value(forKey: "rssi") as? Int32) ?? 0
		satsInView = (object.value(forKey: "satsInView") as? Int32) ?? 0
		seqNo = (object.value(forKey: "seqNo") as? Int32) ?? 0
		snr = ((object.value(forKey: "snr") as? Float) ?? 0).bitPattern
		speed = (object.value(forKey: "speed") as? Int32) ?? 0
		time = object.value(forKey: "time") as? Date
	}
}

private struct TelemetryFingerprint: Hashable {
	let nodeNum: Int64?
	let metricsType: Int32
	let numOnlineNodes: Int32
	let numPacketsRx: Int32
	let numPacketsRxBad: Int32
	let numPacketsTx: Int32
	let numRxDupe: Int32
	let numTotalNodes: Int32
	let numTxRelay: Int32
	let numTxRelayCanceled: Int32
	let time: Date?
	let airUtilTx: UInt32?
	let barometricPressure: UInt32?
	let batteryLevel: Int32?
	let channelUtilization: UInt32?
	let current: UInt32?
	let gasResistance: UInt32?
	let iaq: Int32?
	let irLux: UInt32?
	let lux: UInt32?
	let powerCh1Current: UInt32?
	let powerCh1Voltage: UInt32?
	let powerCh2Current: UInt32?
	let powerCh2Voltage: UInt32?
	let powerCh3Current: UInt32?
	let powerCh3Voltage: UInt32?
	let radiation: UInt32?
	let rainfall1H: UInt32?
	let rainfall24H: UInt32?
	let relativeHumidity: UInt32?
	let rssi: Int32?
	let snr: UInt32?
	let soilMoisture: UInt32?
	let soilTemperature: UInt32?
	let temperature: UInt32?
	let uptimeSeconds: Int32?
	let uvLux: UInt32?
	let voltage: UInt32?
	let weight: UInt32?
	let whiteLux: UInt32?
	let windDirection: Int32?
	let windGust: UInt32?
	let windLull: UInt32?
	let windSpeed: UInt32?

	var replayKey: Data {
		var encoder = FingerprintEncoder()
		encoder.append(nodeNum)
		encoder.append(metricsType)
		encoder.append(numOnlineNodes)
		encoder.append(numPacketsRx)
		encoder.append(numPacketsRxBad)
		encoder.append(numPacketsTx)
		encoder.append(numRxDupe)
		encoder.append(numTotalNodes)
		encoder.append(numTxRelay)
		encoder.append(numTxRelayCanceled)
		encoder.append(time)
		encoder.append(airUtilTx)
		encoder.append(barometricPressure)
		encoder.append(batteryLevel)
		encoder.append(channelUtilization)
		encoder.append(current)
		encoder.append(gasResistance)
		encoder.append(iaq)
		encoder.append(irLux)
		encoder.append(lux)
		encoder.append(powerCh1Current)
		encoder.append(powerCh1Voltage)
		encoder.append(powerCh2Current)
		encoder.append(powerCh2Voltage)
		encoder.append(powerCh3Current)
		encoder.append(powerCh3Voltage)
		encoder.append(radiation)
		encoder.append(rainfall1H)
		encoder.append(rainfall24H)
		encoder.append(relativeHumidity)
		encoder.append(rssi)
		encoder.append(snr)
		encoder.append(soilMoisture)
		encoder.append(soilTemperature)
		encoder.append(temperature)
		encoder.append(uptimeSeconds)
		encoder.append(uvLux)
		encoder.append(voltage)
		encoder.append(weight)
		encoder.append(whiteLux)
		encoder.append(windDirection)
		encoder.append(windGust)
		encoder.append(windLull)
		encoder.append(windSpeed)
		return encoder.data
	}

	init(_ telemetry: TelemetryEntity) {
		nodeNum = telemetry.nodeTelemetry?.num
		metricsType = telemetry.metricsType
		numOnlineNodes = telemetry.numOnlineNodes
		numPacketsRx = telemetry.numPacketsRx
		numPacketsRxBad = telemetry.numPacketsRxBad
		numPacketsTx = telemetry.numPacketsTx
		numRxDupe = telemetry.numRxDupe
		numTotalNodes = telemetry.numTotalNodes
		numTxRelay = telemetry.numTxRelay
		numTxRelayCanceled = telemetry.numTxRelayCanceled
		time = telemetry.time
		airUtilTx = telemetry.airUtilTx?.bitPattern
		barometricPressure = telemetry.barometricPressure?.bitPattern
		batteryLevel = telemetry.batteryLevel
		channelUtilization = telemetry.channelUtilization?.bitPattern
		current = telemetry.current?.bitPattern
		gasResistance = telemetry.gasResistance?.bitPattern
		iaq = telemetry.iaq
		irLux = telemetry.irLux?.bitPattern
		lux = telemetry.lux?.bitPattern
		powerCh1Current = telemetry.powerCh1Current?.bitPattern
		powerCh1Voltage = telemetry.powerCh1Voltage?.bitPattern
		powerCh2Current = telemetry.powerCh2Current?.bitPattern
		powerCh2Voltage = telemetry.powerCh2Voltage?.bitPattern
		powerCh3Current = telemetry.powerCh3Current?.bitPattern
		powerCh3Voltage = telemetry.powerCh3Voltage?.bitPattern
		radiation = telemetry.radiation?.bitPattern
		rainfall1H = telemetry.rainfall1H?.bitPattern
		rainfall24H = telemetry.rainfall24H?.bitPattern
		relativeHumidity = telemetry.relativeHumidity?.bitPattern
		rssi = telemetry.rssi
		snr = telemetry.snr?.bitPattern
		soilMoisture = telemetry.soilMoisture
		soilTemperature = telemetry.soilTemperature?.bitPattern
		temperature = telemetry.temperature?.bitPattern
		uptimeSeconds = telemetry.uptimeSeconds
		uvLux = telemetry.uvLux?.bitPattern
		voltage = telemetry.voltage?.bitPattern
		weight = telemetry.weight?.bitPattern
		whiteLux = telemetry.whiteLux?.bitPattern
		windDirection = telemetry.windDirection
		windGust = telemetry.windGust?.bitPattern
		windLull = telemetry.windLull?.bitPattern
		windSpeed = telemetry.windSpeed?.bitPattern
	}

	init(coreDataObject object: NSManagedObject, nodeNum: Int64?) {
		self.nodeNum = nodeNum
		metricsType = (object.value(forKey: "metricsType") as? Int32) ?? 0
		numOnlineNodes = (object.value(forKey: "numOnlineNodes") as? Int32) ?? 0
		numPacketsRx = (object.value(forKey: "numPacketsRx") as? Int32) ?? 0
		numPacketsRxBad = (object.value(forKey: "numPacketsRxBad") as? Int32) ?? 0
		numPacketsTx = (object.value(forKey: "numPacketsTx") as? Int32) ?? 0
		numRxDupe = (object.value(forKey: "numRxDupe") as? Int32) ?? 0
		numTotalNodes = (object.value(forKey: "numTotalNodes") as? Int32) ?? 0
		numTxRelay = (object.value(forKey: "numTxRelay") as? Int32) ?? 0
		numTxRelayCanceled = (object.value(forKey: "numTxRelayCanceled") as? Int32) ?? 0
		time = object.value(forKey: "time") as? Date
		airUtilTx = (object.value(forKey: "airUtilTx") as? Float)?.bitPattern
		barometricPressure = (object.value(forKey: "barometricPressure") as? Float)?.bitPattern
		batteryLevel = object.value(forKey: "batteryLevel") as? Int32
		channelUtilization = (object.value(forKey: "channelUtilization") as? Float)?.bitPattern
		current = (object.value(forKey: "current") as? Float)?.bitPattern
		gasResistance = (object.value(forKey: "gasResistance") as? Float)?.bitPattern
		iaq = object.value(forKey: "iaq") as? Int32
		irLux = (object.value(forKey: "irLux") as? Float)?.bitPattern
		lux = (object.value(forKey: "lux") as? Float)?.bitPattern
		powerCh1Current = (object.value(forKey: "powerCh1Current") as? Float)?.bitPattern
		powerCh1Voltage = (object.value(forKey: "powerCh1Voltage") as? Float)?.bitPattern
		powerCh2Current = (object.value(forKey: "powerCh2Current") as? Float)?.bitPattern
		powerCh2Voltage = (object.value(forKey: "powerCh2Voltage") as? Float)?.bitPattern
		powerCh3Current = (object.value(forKey: "powerCh3Current") as? Float)?.bitPattern
		powerCh3Voltage = (object.value(forKey: "powerCh3Voltage") as? Float)?.bitPattern
		radiation = (object.value(forKey: "radiation") as? Float)?.bitPattern
		rainfall1H = (object.value(forKey: "rainfall1H") as? Float)?.bitPattern
		rainfall24H = (object.value(forKey: "rainfall24H") as? Float)?.bitPattern
		relativeHumidity = (object.value(forKey: "relativeHumidity") as? Float)?.bitPattern
		rssi = object.value(forKey: "rssi") as? Int32
		snr = (object.value(forKey: "snr") as? Float)?.bitPattern
		soilMoisture = (object.value(forKey: "soilMoisture") as? Int32).map(UInt32.init(bitPattern:))
		soilTemperature = (object.value(forKey: "soilTemperature") as? Float)?.bitPattern
		temperature = (object.value(forKey: "temperature") as? Float)?.bitPattern
		uptimeSeconds = object.value(forKey: "uptimeSeconds") as? Int32
		uvLux = (object.value(forKey: "uvLux") as? Float)?.bitPattern
		voltage = (object.value(forKey: "voltage") as? Float)?.bitPattern
		weight = (object.value(forKey: "weight") as? Float)?.bitPattern
		whiteLux = (object.value(forKey: "whiteLux") as? Float)?.bitPattern
		windDirection = object.value(forKey: "windDirection") as? Int32
		windGust = (object.value(forKey: "windGust") as? Float)?.bitPattern
		windLull = (object.value(forKey: "windLull") as? Float)?.bitPattern
		windSpeed = (object.value(forKey: "windSpeed") as? Float)?.bitPattern
	}
}

// MARK: - Bounded replay index

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class ReplayIndex {
	enum Kind: Int32 {
		case message
		case position
		case telemetry
	}

	private let url: URL
	private var database: OpaquePointer?
	private var seedStatement: OpaquePointer?
	private var claimStatement: OpaquePointer?

	init(url: URL) throws {
		self.url = url
		try Self.removeFiles(at: url)
		let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
		guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
			let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open replay index."
			if let database { sqlite3_close(database) }
			throw MigrationError.replayIndex(message)
		}

		do {
			try execute("PRAGMA journal_mode = DELETE")
			try execute("PRAGMA synchronous = OFF")
			try execute("""
				CREATE TABLE fingerprints (
					kind INTEGER NOT NULL,
					key BLOB NOT NULL,
					destination_count INTEGER NOT NULL DEFAULT 0,
					source_seen INTEGER NOT NULL DEFAULT 0,
					PRIMARY KEY (kind, key)
				) WITHOUT ROWID
				""")
			seedStatement = try prepare("""
				INSERT INTO fingerprints (kind, key, destination_count, source_seen)
				VALUES (?1, ?2, 1, 0)
				ON CONFLICT(kind, key) DO UPDATE SET destination_count = destination_count + 1
				""")
			claimStatement = try prepare("""
				INSERT INTO fingerprints (kind, key, destination_count, source_seen)
				VALUES (?1, ?2, 0, 1)
				ON CONFLICT(kind, key) DO UPDATE SET source_seen = source_seen + 1
				RETURNING destination_count, source_seen
				""")
		} catch {
			close()
			try? Self.removeFiles(at: url)
			throw error
		}
	}

	deinit {
		close()
	}

	func closeAndRemove() {
		close()
		try? Self.removeFiles(at: url)
	}

	static func removeStale(at url: URL) throws {
		try removeFiles(at: url)
	}

	func withTransaction<T>(_ body: () throws -> T) throws -> T {
		try execute("BEGIN IMMEDIATE")
		do {
			let result = try body()
			try execute("COMMIT")
			return result
		} catch {
			try? execute("ROLLBACK")
			throw error
		}
	}

	func recordDestination(kind: Kind, key: Data) throws {
		guard let seedStatement else { throw MigrationError.replayIndex("Replay index is closed.") }
		try bind(kind: kind, key: key, to: seedStatement)
		defer { reset(seedStatement) }
		guard sqlite3_step(seedStatement) == SQLITE_DONE else {
			throw databaseError()
		}
	}

	func claimSource(kind: Kind, key: Data) throws -> (destinationCount: Int, sourceSeen: Int) {
		guard let claimStatement else { throw MigrationError.replayIndex("Replay index is closed.") }
		try bind(kind: kind, key: key, to: claimStatement)
		defer { reset(claimStatement) }
		guard sqlite3_step(claimStatement) == SQLITE_ROW else {
			throw databaseError()
		}
		return (
			Int(sqlite3_column_int64(claimStatement, 0)),
			Int(sqlite3_column_int64(claimStatement, 1))
		)
	}

	private func bind(kind: Kind, key: Data, to statement: OpaquePointer) throws {
		guard sqlite3_bind_int(statement, 1, kind.rawValue) == SQLITE_OK else {
			throw databaseError()
		}
		let result = key.withUnsafeBytes { bytes in
			sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
		}
		guard result == SQLITE_OK else { throw databaseError() }
	}

	private func execute(_ sql: String) throws {
		guard let database else { throw MigrationError.replayIndex("Replay index is closed.") }
		var errorMessage: UnsafeMutablePointer<CChar>?
		guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
			let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
			sqlite3_free(errorMessage)
			throw MigrationError.replayIndex(message)
		}
	}

	private func prepare(_ sql: String) throws -> OpaquePointer {
		guard let database else { throw MigrationError.replayIndex("Replay index is closed.") }
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
			  let statement else {
			throw databaseError()
		}
		return statement
	}

	private func reset(_ statement: OpaquePointer) {
		sqlite3_reset(statement)
		sqlite3_clear_bindings(statement)
	}

	private func databaseError() -> MigrationError {
		guard let database else { return .replayIndex("Replay index is closed.") }
		return .replayIndex(String(cString: sqlite3_errmsg(database)))
	}

	private func close() {
		if let seedStatement {
			sqlite3_finalize(seedStatement)
			self.seedStatement = nil
		}
		if let claimStatement {
			sqlite3_finalize(claimStatement)
			self.claimStatement = nil
		}
		if let database {
			sqlite3_close(database)
			self.database = nil
		}
	}

	private static func removeFiles(at url: URL) throws {
		let fileManager = FileManager.default
		for suffix in ["", "-wal", "-shm", "-journal"] {
			let fileURL = URL(fileURLWithPath: url.path + suffix)
			if fileManager.fileExists(atPath: fileURL.path) {
				try fileManager.removeItem(at: fileURL)
			}
		}
	}
}

private struct FingerprintEncoder {
	private(set) var data = Data()

	mutating func append<T: FixedWidthInteger>(_ value: T) {
		var littleEndian = value.littleEndian
		withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
	}

	mutating func append(_ value: Bool) {
		append(value ? UInt8(1) : UInt8(0))
	}

	mutating func append(_ value: Date?) {
		append(value.map { $0.timeIntervalSinceReferenceDate.bitPattern })
	}

	mutating func append(_ value: String?) {
		guard let value else {
			append(UInt8(0))
			return
		}
		append(UInt8(1))
		let bytes = Data(value.utf8)
		append(UInt64(bytes.count))
		data.append(bytes)
	}

	mutating func append(_ value: Data?) {
		guard let value else {
			append(UInt8(0))
			return
		}
		append(UInt8(1))
		append(UInt64(value.count))
		data.append(value)
	}

	mutating func append<T: FixedWidthInteger>(_ value: T?) {
		guard let value else {
			append(UInt8(0))
			return
		}
		append(UInt8(1))
		append(value)
	}
}

// MARK: - Store retirement

private extension CoreDataMigrationService {

	/// Renames the SQLite store family so the migration never runs again.
	/// Existing destination files make retry safe after an interrupted partial move.
	static func retireLegacyStore(
		at locations: StoreLocations,
		options: MigrationOptions
	) throws {
		let fm = FileManager.default
		// The source store can recreate WAL/SHM files when a retry opens it.
		// Persist a marker before the first move so those regenerated sidecars can
		// be distinguished from an unrelated backup-file collision.
		let storeMembers: [(suffix: String, member: StoreMember)] = [
			("-wal", .wal),
			("-shm", .shm),
			("", .main)
		]
		if !fm.fileExists(atPath: locations.retirementMarkerURL.path) {
			for storeMember in storeMembers {
				let backupFile = sidecar(of: locations.backupStoreURL, suffix: storeMember.suffix)
				if fm.fileExists(atPath: backupFile.path) {
					throw MigrationError.backupAlreadyExists(backupFile.lastPathComponent)
				}
			}
			try Data().write(to: locations.retirementMarkerURL, options: .atomic)
		}

		// Keep the legacy main file in place until both sidecars are safe. Retry
		// therefore continues to see an unfinished migration after any sidecar move.
		for storeMember in storeMembers {
			let srcFile = sidecar(of: locations.legacyStoreURL, suffix: storeMember.suffix)
			let dstFile = sidecar(of: locations.backupStoreURL, suffix: storeMember.suffix)
			guard fm.fileExists(atPath: srcFile.path) else { continue }
			if fm.fileExists(atPath: dstFile.path) {
				guard storeMember.member != .main else {
					throw MigrationError.storeFamilyConflict(dstFile.lastPathComponent)
				}
				try fm.removeItem(at: srcFile)
			} else {
				try fm.moveItem(at: srcFile, to: dstFile)
			}
			try options.checkpoint(.afterRetirementMove(storeMember.member))
		}
		try fm.removeItem(at: locations.retirementMarkerURL)
	}
}

// MARK: - Errors

enum MigrationError: LocalizedError {
	case modelNotFound
	case modelLoadFailed
	case backupAlreadyExists(String)
	case storeFamilyConflict(String)
	case replayIndex(String)
	case duplicateLegacyMessageId(Int64)

	var errorDescription: String? {
		switch self {
		case .modelNotFound:
			return "Legacy Core Data model file not found in bundle."
		case .modelLoadFailed:
			return "Failed to load legacy Core Data model from bundle."
		case let .backupAlreadyExists(fileName):
			return "Cannot retire the legacy store because \(fileName) already exists."
		case let .storeFamilyConflict(fileName):
			return "Cannot move the legacy store because \(fileName) already exists."
		case let .replayIndex(message):
			return "Cannot build the migration replay index: \(message)"
		case let .duplicateLegacyMessageId(messageId):
			return "The legacy store contains duplicate message ID \(messageId)."
		}
	}
}
