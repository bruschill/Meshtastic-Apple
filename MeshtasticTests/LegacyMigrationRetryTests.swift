import CoreData
import SwiftData
import XCTest
@testable import Meshtastic

final class LegacyMigrationRetryTests: XCTestCase {
	private let storeMembers: [CoreDataMigrationService.StoreMember] = [.wal, .shm, .main]
	private var temporaryDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LegacyMigrationRetryTests-")
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let temporaryDirectory {
			try? FileManager.default.removeItem(at: temporaryDirectory)
		}
		try super.tearDownWithError()
	}

	@MainActor
	func testRetryAfterParentSave() async throws {
		let (locations, container) = try makeScenario()

		try await interruptMigration(at: .afterParentSave, container: container, locations: locations)
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(at: locations))
		XCTAssertEqual(
			try migrationCounts(in: container),
			MigrationCounts(messages: 0, positions: 0, telemetry: 0, channels: 2, deviceConfigs: 2)
		)

		try await completeMigration(container: container, locations: locations)
		try assertFinalState(container: container, locations: locations)
	}

	@MainActor
	func testRetryCompletesPartialUniqueRowsAndDistinctOrphans() async throws {
		let (locations, container) = try makeScenario()
		let context = container.mainContext
		let node = NodeInfoEntity()
		node.num = 111
		context.insert(node)
		let attachedConfig = DeviceConfigEntity()
		attachedConfig.role = 109
		attachedConfig.deviceConfigNode = node
		context.insert(attachedConfig)
		let preexistingOrphan = DeviceConfigEntity()
		preexistingOrphan.role = 110
		context.insert(preexistingOrphan)
		let partialLoRa = LoRaConfigEntity()
		partialLoRa.loRaConfigNode = node
		context.insert(partialLoRa)
		let partialMQTT = MQTTConfigEntity()
		partialMQTT.mqttConfigNode = node
		context.insert(partialMQTT)
		let message = MessageEntity()
		message.messageId = 1002
		message.messagePayload = "live payload"
		context.insert(message)
		let waypoint = WaypointEntity()
		waypoint.id = 77
		waypoint.name = "live waypoint"
		context.insert(waypoint)
		try context.save()

		try await interruptMigration(at: .afterParentSave, container: container, locations: locations)
		let interruptedContext = ModelContext(container)
		let interruptedNode = try XCTUnwrap(
			interruptedContext.fetch(FetchDescriptor<NodeInfoEntity>()).first(where: { $0.num == 111 })
		)
		XCTAssertEqual(interruptedNode.deviceConfig?.role, 109)
		XCTAssertEqual(interruptedNode.deviceConfig?.buttonGpio, 81)
		XCTAssertEqual(interruptedNode.loRaConfig?.hopLimit, 6)
		XCTAssertEqual(interruptedNode.mqttConfig?.root, "root")
		XCTAssertEqual(
			Set(try interruptedContext.fetch(FetchDescriptor<DeviceConfigEntity>())
				.filter { $0.deviceConfigNode == nil }.map(\.role)),
			Set([Int32(108), Int32(110)])
		)
		let interruptedWaypoint = try XCTUnwrap(
			interruptedContext.fetch(FetchDescriptor<WaypointEntity>()).first(where: { $0.id == 77 })
		)
		XCTAssertEqual(interruptedWaypoint.name, "live waypoint")
		XCTAssertEqual(interruptedWaypoint.latitudeI, 79)

		try await completeMigration(container: container, locations: locations)
		let migratedContext = ModelContext(container)
		let migratedMessage = try XCTUnwrap(
			migratedContext.fetch(FetchDescriptor<MessageEntity>()).first(where: { $0.messageId == 1002 })
		)
		XCTAssertEqual(migratedMessage.messagePayload, "live payload")
		XCTAssertEqual(migratedMessage.messageTimestamp, 5)
		XCTAssertEqual(migratedMessage.fromUser?.num, 111)
		XCTAssertEqual(try migratedContext.fetchCount(FetchDescriptor<MessageEntity>()), 2)
		XCTAssertEqual(try migratedContext.fetchCount(FetchDescriptor<DeviceConfigEntity>()), 3)
		XCTAssertEqual(try migratedContext.fetchCount(FetchDescriptor<WaypointEntity>()), 1)
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(at: locations))
		XCTAssertTrue(FileManager.default.fileExists(atPath: locations.backupStoreURL.path))
	}

	@MainActor
	func testRetryAfterEveryHistoryBatch() async throws {
		let checkpoints: [(CoreDataMigrationService.MigrationCheckpoint, MigrationCounts)] = [
			(.afterHistoryBatch(.messages, index: 0), .init(messages: 1, positions: 0, telemetry: 0, channels: 2, deviceConfigs: 2)),
			(.afterHistoryBatch(.messages, index: 1), .init(messages: 2, positions: 0, telemetry: 0, channels: 2, deviceConfigs: 2)),
			(.afterHistoryBatch(.positions, index: 0), .init(messages: 2, positions: 1, telemetry: 0, channels: 2, deviceConfigs: 2)),
			(.afterHistoryBatch(.positions, index: 1), .init(messages: 2, positions: 2, telemetry: 0, channels: 2, deviceConfigs: 2)),
			(.afterHistoryBatch(.positions, index: 2), .init(messages: 2, positions: 3, telemetry: 0, channels: 2, deviceConfigs: 2)),
			(.afterHistoryBatch(.telemetry, index: 0), .init(messages: 2, positions: 3, telemetry: 1, channels: 2, deviceConfigs: 2)),
			(.afterHistoryBatch(.telemetry, index: 1), .init(messages: 2, positions: 3, telemetry: 2, channels: 2, deviceConfigs: 2))
		]

		for (checkpoint, expectedCounts) in checkpoints {
			let (locations, container) = try makeScenario()
			try await interruptMigration(at: checkpoint, container: container, locations: locations)
			XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(at: locations), "checkpoint: \(checkpoint)")
			XCTAssertEqual(try migrationCounts(in: container), expectedCounts, "checkpoint: \(checkpoint)")

			try await completeMigration(container: container, locations: locations)
			try assertFinalState(container: container, locations: locations)
		}
	}

	@MainActor
	func testRetryAfterMessageScalarsRepairsRelationships() async throws {
		let (locations, container) = try makeScenario()

		try await interruptMigration(at: .afterMessageScalarPersistence, container: container, locations: locations)
		let interruptedMessages = try container.mainContext.fetch(FetchDescriptor<MessageEntity>())
		XCTAssertEqual(Set(interruptedMessages.map(\.messageId)), [1001, 1002])
		XCTAssertTrue(interruptedMessages.allSatisfy { $0.fromUser == nil && $0.toUser == nil })

		try await completeMigration(container: container, locations: locations)
		try assertFinalState(container: container, locations: locations)
	}

	@MainActor
	func testRetryAfterMessageUserLinkDoesNotDuplicateMessages() async throws {
		let (locations, container) = try makeScenario()

		try await interruptMigration(at: .afterMessageUserLink(nodeNum: 111), container: container, locations: locations)
		let linkedMessages = try container.mainContext.fetch(FetchDescriptor<MessageEntity>())
		XCTAssertEqual(linkedMessages.count, 2)
		XCTAssertEqual(
			linkedMessages.filter { $0.fromUser?.num == 111 && $0.toUser?.num == 111 }.count,
			1
		)

		try await completeMigration(container: container, locations: locations)
		try assertFinalState(container: container, locations: locations)
	}

	@MainActor
	func testPrepareRetriesAfterEveryStoreMove() async throws {
		for member in storeMembers {
			let locations = try makeLocations()
			try buildLegacyStore(at: locations.candidateStoreURL)
			try Data().write(to: sidecar(of: locations.candidateStoreURL, suffix: "-wal"))
			try Data().write(to: sidecar(of: locations.candidateStoreURL, suffix: "-shm"))

			XCTAssertThrowsError(
				try CoreDataMigrationService.prepareForMigration(
					locations: locations,
					options: .init(checkpoint: { checkpoint in
						if checkpoint == .afterPrepareMove(member) { throw TestInterruption() }
					})
				)
			)
			XCTAssertEqual(
				CoreDataMigrationService.legacyStoreExists(at: locations),
				member == .main,
				"member: \(member)"
			)

			try CoreDataMigrationService.prepareForMigration(locations: locations)
			XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(at: locations), "member: \(member)")
			XCTAssertFalse(FileManager.default.fileExists(atPath: locations.candidateStoreURL.path), "member: \(member)")

			let container = try makeDestinationContainer(at: locations)
			try await completeMigration(container: container, locations: locations)
			try assertFinalState(container: container, locations: locations)
		}
	}

	func testPrepareRejectsAnIncompleteStoreFamily() throws {
		let locations = try makeLocations()
		try Data("orphaned WAL".utf8).write(
			to: sidecar(of: locations.legacyStoreURL, suffix: "-wal")
		)

		XCTAssertThrowsError(
			try CoreDataMigrationService.prepareForMigration(locations: locations)
		) { error in
			guard let migrationError = error as? MigrationError,
				  case .storeFamilyConflict = migrationError else {
				return XCTFail("Expected an incomplete store-family conflict, got \(error)")
			}
		}
	}

	func testRetirementMarkerKeepsBootstrapPending() throws {
		let locations = try makeLocations()
		try Data().write(to: locations.retirementMarkerURL)

		XCTAssertTrue(CoreDataMigrationService.migrationWorkExists(at: locations))

		try FileManager.default.removeItem(at: locations.retirementMarkerURL)
		XCTAssertFalse(CoreDataMigrationService.migrationWorkExists(at: locations))
	}

	@MainActor
	func testBatchSizesProduceIdenticalHistory() async throws {
		for batchSize in [1, 2, 10] {
			let (locations, container) = try makeScenario()
			try await completeMigration(
				container: container,
				locations: locations,
				batchSize: batchSize
			)
			try assertFinalState(container: container, locations: locations)
		}
	}

	@MainActor
	func testStaleReplayIndexIsRebuilt() async throws {
		let (locations, container) = try makeScenario()
		try Data("stale".utf8).write(to: locations.replayIndexURL)

		try await completeMigration(container: container, locations: locations)

		try assertFinalState(container: container, locations: locations)
	}

	@MainActor
	func testRetirementRetriesAfterEveryStoreMove() async throws {
		for member in storeMembers {
			let (locations, container) = try makeScenario()
			let legacyWAL = sidecar(of: locations.legacyStoreURL, suffix: "-wal")
			let legacySHM = sidecar(of: locations.legacyStoreURL, suffix: "-shm")

			do {
				try await CoreDataMigrationService.migrateOffMain(
					into: container,
					locations: locations,
					options: .init(
						batchSize: 1,
						checkpoint: { checkpoint in
							if checkpoint == .beforeRetirement {
								try Data().write(to: legacyWAL)
								try Data().write(to: legacySHM)
							}
							if checkpoint == .afterRetirementMove(member) {
								throw TestInterruption()
							}
						}
					)
				)
				XCTFail("Expected retirement to be interrupted after moving \(member)")
			} catch is TestInterruption {
				// Expected interruption.
			}
			XCTAssertEqual(
				CoreDataMigrationService.legacyStoreExists(at: locations),
				member != .main,
				"member: \(member)"
			)

			if CoreDataMigrationService.legacyStoreExists(at: locations) {
				try await completeMigration(container: container, locations: locations)
			} else {
				try Data("stale".utf8).write(to: locations.replayIndexURL)
				try CoreDataMigrationService.prepareForMigration(locations: locations)
			}
			XCTAssertFalse(FileManager.default.fileExists(atPath: locations.retirementMarkerURL.path))
			try assertFinalState(container: container, locations: locations)
		}
	}

	@MainActor
	func testRetirementCollisionWithoutMarkerFailsClosed() async throws {
		let (locations, container) = try makeScenario()
		let backupWAL = sidecar(of: locations.backupStoreURL, suffix: "-wal")
		try Data("collision".utf8).write(to: backupWAL)

		do {
			try await CoreDataMigrationService.migrateOffMain(
				into: container,
				locations: locations,
				options: .init(batchSize: 1)
			)
			XCTFail("Expected the existing backup sidecar to block retirement")
		} catch let error as MigrationError {
			guard case .backupAlreadyExists = error else { throw error }
		}
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(at: locations))
		XCTAssertFalse(FileManager.default.fileExists(atPath: locations.retirementMarkerURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: locations.replayIndexURL.path))

		try FileManager.default.removeItem(at: backupWAL)
		try await completeMigration(container: container, locations: locations)
		try assertFinalState(container: container, locations: locations)
	}

	@MainActor
	func testRetirementCollisionWithMarkerFailsClosed() async throws {
		let (locations, container) = try makeScenario()
		try FileManager.default.copyItem(at: locations.legacyStoreURL, to: locations.backupStoreURL)
		try Data().write(to: locations.retirementMarkerURL)

		do {
			try await CoreDataMigrationService.migrateOffMain(
				into: container,
				locations: locations,
				options: .init(batchSize: 1)
			)
			XCTFail("Expected concurrent legacy and backup main stores to block retirement")
		} catch let error as MigrationError {
			guard case .storeFamilyConflict = error else { throw error }
		}

		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(at: locations))
		XCTAssertTrue(FileManager.default.fileExists(atPath: locations.backupStoreURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: locations.retirementMarkerURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: locations.replayIndexURL.path))
	}

	@MainActor
	func testRetryAfterCommittedDataBeforeRetirementDoesNotDuplicateHistory() async throws {
		let (locations, container) = try makeScenario()

		try await interruptMigration(at: .beforeRetirement, container: container, locations: locations)
		XCTAssertTrue(CoreDataMigrationService.legacyStoreExists(at: locations))
		XCTAssertEqual(try migrationCounts(in: container), .final)

		try await completeMigration(container: container, locations: locations)
		try assertFinalState(container: container, locations: locations)
	}

}

private extension LegacyMigrationRetryTests {
	@MainActor
	func interruptMigration(
		at target: CoreDataMigrationService.MigrationCheckpoint,
		container: ModelContainer,
		locations: CoreDataMigrationService.StoreLocations
	) async throws {
		do {
			try await CoreDataMigrationService.migrateOffMain(
				into: container,
				locations: locations,
				options: .init(
					batchSize: 1,
					checkpoint: { checkpoint in
						if checkpoint == target { throw TestInterruption() }
					}
				)
			)
			XCTFail("Expected migration to be interrupted at \(target)")
		} catch is TestInterruption {
			// Expected interruption.
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: locations.replayIndexURL.path))
	}

	@MainActor
	private func completeMigration(
		container: ModelContainer,
		locations: CoreDataMigrationService.StoreLocations,
		batchSize: Int = 1
	) async throws {
		try await CoreDataMigrationService.migrateOffMain(
			into: container,
			locations: locations,
			options: .init(batchSize: batchSize)
		)
	}

	@MainActor
	private func makeScenario() throws -> (CoreDataMigrationService.StoreLocations, ModelContainer) {
		let locations = try makeLocations()
		try buildLegacyStore(at: locations.legacyStoreURL)
		return (locations, try makeDestinationContainer(at: locations))
	}

	private func makeLocations() throws -> CoreDataMigrationService.StoreLocations {
		let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return CoreDataMigrationService.StoreLocations(applicationSupportURL: root)
	}

	@MainActor
	private func makeDestinationContainer(
		at locations: CoreDataMigrationService.StoreLocations
	) throws -> ModelContainer {
		let schema = Schema(versionedSchema: MeshtasticSchema.current)
		let configuration = ModelConfiguration(url: locations.destinationStoreURL, allowsSave: true)
		let container = try ModelContainer(
			for: schema,
			migrationPlan: MeshtasticMigrationPlan.self,
			configurations: configuration
		)
		container.mainContext.autosaveEnabled = false
		return container
	}

	@MainActor
	private func migrationCounts(in container: ModelContainer) throws -> MigrationCounts {
		MigrationCounts(
			messages: try container.mainContext.fetchCount(FetchDescriptor<MessageEntity>()),
			positions: try container.mainContext.fetchCount(FetchDescriptor<PositionEntity>()),
			telemetry: try container.mainContext.fetchCount(FetchDescriptor<TelemetryEntity>()),
			channels: try container.mainContext.fetchCount(FetchDescriptor<ChannelEntity>()),
			deviceConfigs: try container.mainContext.fetchCount(FetchDescriptor<DeviceConfigEntity>())
		)
	}

	@MainActor
	// swiftlint:disable:next function_body_length
	private func assertFinalState(
		container: ModelContainer,
		locations: CoreDataMigrationService.StoreLocations
	) throws {
		XCTAssertEqual(try migrationCounts(in: container), .final)
		XCTAssertFalse(CoreDataMigrationService.legacyStoreExists(at: locations))
		XCTAssertTrue(FileManager.default.fileExists(atPath: locations.backupStoreURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: locations.replayIndexURL.path))

		let messages = try container.mainContext.fetch(FetchDescriptor<MessageEntity>())
		XCTAssertEqual(Set(messages.map(\.messageId)), [1001, 1002])
		XCTAssertEqual(
			Dictionary(uniqueKeysWithValues: messages.map { ($0.messageId, $0.messagePayload) }),
			[1001: "message 1001", 1002: "message 1002"]
		)
		XCTAssertTrue(messages.allSatisfy {
			$0.ackError == 1 && $0.ackSNR == 2.5 && $0.ackTimestamp == 3 &&
			$0.admin && $0.adminDescription == "admin" && $0.channel == 4 && $0.isEmoji &&
			$0.messagePayloadMarkdown == "markdown" &&
			$0.messagePayloadTranslated == "translated" &&
			$0.messagePayloadTranslatedMarkdown == "translated markdown" &&
			$0.messageTimestamp == 5 && $0.pkiEncrypted && $0.portNum == 6 &&
			$0.publicKey == Data([1, 2, 3]) && $0.read && $0.realACK && !$0.receivedACK &&
			$0.relayNode == 9 && $0.relays == 2 && $0.replyID == 10 && $0.rssi == -80 &&
			$0.showTranslatedMessage && $0.snr == 14.5 &&
			$0.fromUser?.num == 111 && $0.toUser?.num == 111
		})

		let positions = try container.mainContext.fetch(FetchDescriptor<PositionEntity>())
		XCTAssertTrue(positions.allSatisfy {
			$0.altitude == 123 && $0.heading == 45 && $0.longitudeI == -122_000_000 &&
			$0.precisionBits == 17 && $0.rssi == -42 && $0.satsInView == 7 &&
			$0.seqNo == 8 && $0.snr == 9.5 && $0.speed == 10 && $0.nodePosition?.num == 111
		})
		let positionIdentities = positions.map(PositionIdentity.init).sorted {
			if $0.latitudeI != $1.latitudeI { return $0.latitudeI < $1.latitudeI }
			return $0.time < $1.time
		}
		XCTAssertEqual(
			positionIdentities,
			[
				PositionIdentity(latitudeI: 37_000_000, time: 1_700_000_001, latest: false),
				PositionIdentity(latitudeI: 37_000_000, time: 1_700_000_001, latest: false),
				PositionIdentity(latitudeI: 38_000_000, time: 1_700_000_002, latest: true)
			]
		)

		let telemetry = try container.mainContext.fetch(FetchDescriptor<TelemetryEntity>())
		XCTAssertTrue(telemetry.allSatisfy {
			$0.nodeTelemetry?.num == 111 && $0.metricsType == 1 &&
			$0.numOnlineNodes == 2 && $0.numPacketsRx == 3 && $0.numPacketsRxBad == 4 &&
			$0.numPacketsTx == 5 && $0.numRxDupe == 6 && $0.numTotalNodes == 7 &&
			$0.numTxRelay == 8 && $0.numTxRelayCanceled == 9
		})
		let populatedTelemetry = try XCTUnwrap(
			telemetry.first { $0.time == Date(timeIntervalSince1970: 1_700_000_003) }
		)
		XCTAssertTrue(
			populatedTelemetry.airUtilTx == 10.5 && populatedTelemetry.barometricPressure == 11.5 &&
			populatedTelemetry.batteryLevel == 12 && populatedTelemetry.channelUtilization == 13.5 &&
			populatedTelemetry.current == 14.5 && populatedTelemetry.gasResistance == 15.5 &&
			populatedTelemetry.iaq == 16 && populatedTelemetry.irLux == 17.5 &&
			populatedTelemetry.lux == 18.5 && populatedTelemetry.powerCh1Current == 19.5 &&
			populatedTelemetry.powerCh1Voltage == 20.5 && populatedTelemetry.powerCh2Current == 21.5 &&
			populatedTelemetry.powerCh2Voltage == 22.5 && populatedTelemetry.powerCh3Current == 23.5 &&
			populatedTelemetry.powerCh3Voltage == 24.5 && populatedTelemetry.radiation == 25.5 &&
			populatedTelemetry.rainfall1H == 26.5 && populatedTelemetry.rainfall24H == 27.5 &&
			populatedTelemetry.relativeHumidity == 28.5 && populatedTelemetry.rssi == -29 &&
			populatedTelemetry.snr == 30.5 && populatedTelemetry.soilMoisture == 4_000_000_000 &&
			populatedTelemetry.soilTemperature == 32.5 && populatedTelemetry.temperature == 33.5 &&
			populatedTelemetry.uptimeSeconds == 34 && populatedTelemetry.uvLux == 35.5 &&
			populatedTelemetry.voltage == 36.5 && populatedTelemetry.weight == 37.5 &&
			populatedTelemetry.whiteLux == 38.5 && populatedTelemetry.windDirection == 39 &&
			populatedTelemetry.windGust == 40.5 && populatedTelemetry.windLull == 41.5 &&
			populatedTelemetry.windSpeed == 42.5
		)
		let nilTelemetry = try XCTUnwrap(
			telemetry.first { $0.time == Date(timeIntervalSince1970: 1_700_000_004) }
		)
		XCTAssertTrue(
			nilTelemetry.airUtilTx == 0 && nilTelemetry.barometricPressure == 0 &&
			nilTelemetry.batteryLevel == 0 && nilTelemetry.channelUtilization == 0 &&
			nilTelemetry.current == 0 && nilTelemetry.gasResistance == 0 &&
			nilTelemetry.iaq == 0 && nilTelemetry.irLux == 0 && nilTelemetry.lux == 0 &&
			nilTelemetry.powerCh1Current == nil && nilTelemetry.powerCh1Voltage == nil &&
			nilTelemetry.powerCh2Current == nil && nilTelemetry.powerCh2Voltage == nil &&
			nilTelemetry.powerCh3Current == nil && nilTelemetry.powerCh3Voltage == nil &&
			nilTelemetry.radiation == 0 && nilTelemetry.rainfall1H == 0 &&
			nilTelemetry.rainfall24H == 0 && nilTelemetry.relativeHumidity == 0 &&
			nilTelemetry.rssi == 0 && nilTelemetry.snr == 0 && nilTelemetry.soilMoisture == 0 &&
			nilTelemetry.soilTemperature == 0 && nilTelemetry.temperature == 0 &&
			nilTelemetry.uptimeSeconds == 0 && nilTelemetry.uvLux == 0 && nilTelemetry.voltage == 0 &&
			nilTelemetry.weight == 0 && nilTelemetry.whiteLux == 0 && nilTelemetry.windDirection == 0 &&
			nilTelemetry.windGust == 0 && nilTelemetry.windLull == 0 && nilTelemetry.windSpeed == 0
		)
		let migratedNode = try XCTUnwrap(
			container.mainContext.fetch(FetchDescriptor<NodeInfoEntity>()).first
		)
		XCTAssertTrue(
			migratedNode.bleName == "Legacy BLE" && migratedNode.channel == 2 && migratedNode.favorite &&
			migratedNode.firstHeard == Date(timeIntervalSince1970: 1_699_999_999) &&
			migratedNode.hopsAway == 3 && migratedNode.id == 4 && migratedNode.ignored &&
			migratedNode.lastHeard == Date(timeIntervalSince1970: 1_700_000_000) &&
			migratedNode.num == 111 && migratedNode.peripheralId == "peripheral" &&
			migratedNode.rssi == -70 &&
			migratedNode.sessionExpiration == Date(timeIntervalSince1970: 1_700_000_100) &&
			migratedNode.sessionPasskey == Data([4, 5, 6]) && migratedNode.snr == 7.5 &&
			migratedNode.viaMqtt
		)
		let migratedUser = try XCTUnwrap(migratedNode.user)
		XCTAssertTrue(
			migratedUser.hwDisplayName == "Test Hardware" && migratedUser.hwModel == "TEST" &&
			migratedUser.hwModelId == 8 && migratedUser.isLicensed && !migratedUser.keyMatch &&
			migratedUser.lastMessage == Date(timeIntervalSince1970: 1_700_000_200) &&
			migratedUser.longName == "Legacy User" && migratedUser.mute &&
			migratedUser.newPublicKey == Data([7, 8]) && migratedUser.num == 111 &&
			migratedUser.numString == "111" && migratedUser.pkiEncrypted &&
			migratedUser.publicKey == Data([9, 10]) && migratedUser.role == 11 &&
			migratedUser.shortName == "LU" && migratedUser.unmessagable &&
			migratedUser.userId == "!0000006f"
		)
		let migratedInfo = try XCTUnwrap(migratedNode.myInfo)
		XCTAssertTrue(
			migratedInfo.bleName == "My BLE" && migratedInfo.deviceId == Data([12, 13]) &&
			migratedInfo.minAppVersion == 14 && migratedInfo.myNodeNum == 111 &&
			migratedInfo.peripheralId == "my-peripheral" && migratedInfo.pioEnv == "pio" &&
			migratedInfo.rebootCount == 15 && migratedInfo.registered
		)
		let migratedChannel = try XCTUnwrap(migratedInfo.channels.first)
		XCTAssertTrue(
			migratedChannel.downlinkEnabled && migratedChannel.id == 16 &&
			migratedChannel.index == 0 && migratedChannel.mute &&
			migratedChannel.name == "LegacyChan" && migratedChannel.positionPrecision == 17 &&
			migratedChannel.psk == Data([18, 19]) && migratedChannel.role == 20 &&
			migratedChannel.uplinkEnabled
		)
		XCTAssertTrue(
			migratedNode.ambientLightingConfig?.blue == 21 &&
			migratedNode.ambientLightingConfig?.current == 22 &&
			migratedNode.ambientLightingConfig?.green == 23 &&
			migratedNode.ambientLightingConfig?.ledState == true &&
			migratedNode.ambientLightingConfig?.red == 24
		)
		XCTAssertTrue(
			migratedNode.detectionSensorConfig?.enabled == true &&
			migratedNode.detectionSensorConfig?.minimumBroadcastSecs == 25 &&
			migratedNode.detectionSensorConfig?.monitorPin == 26 &&
			migratedNode.detectionSensorConfig?.name == "sensor" &&
			migratedNode.detectionSensorConfig?.sendBell == true &&
			migratedNode.detectionSensorConfig?.stateBroadcastSecs == 27 &&
			migratedNode.detectionSensorConfig?.triggerType == 28 &&
			migratedNode.detectionSensorConfig?.usePullup == true
		)
		XCTAssertTrue(
			migratedNode.paxCounterConfig?.bleThreshold == 29 &&
			migratedNode.paxCounterConfig?.enabled == true &&
			migratedNode.paxCounterConfig?.updateInterval == 30 &&
			migratedNode.paxCounterConfig?.wifiThreshold == -31
		)
		XCTAssertTrue(
			migratedNode.powerConfig?.adcMultiplierOverride == 32.5 &&
			migratedNode.powerConfig?.deviceBatteryInaAddress == 33 &&
			migratedNode.powerConfig?.isPowerSaving == true &&
			migratedNode.powerConfig?.lsSecs == 34 && migratedNode.powerConfig?.minWakeSecs == 35 &&
			migratedNode.powerConfig?.onBatteryShutdownAfterSecs == 36 &&
			migratedNode.powerConfig?.waitBluetoothSecs == 37
		)
		XCTAssertEqual(migratedNode.rtttlConfig?.ringtone, "ringtone")
		XCTAssertTrue(
			migratedNode.securityConfig?.adminChannelEnabled == true &&
			migratedNode.securityConfig?.adminKey == Data([38]) &&
			migratedNode.securityConfig?.adminKey2 == Data([39]) &&
			migratedNode.securityConfig?.adminKey3 == Data([40]) &&
			migratedNode.securityConfig?.bluetoothLoggingEnabled == true &&
			migratedNode.securityConfig?.debugLogApiEnabled == true &&
			migratedNode.securityConfig?.isManaged == true &&
			migratedNode.securityConfig?.privateKey == Data([41]) &&
			migratedNode.securityConfig?.publicKey == Data([42]) &&
			migratedNode.securityConfig?.serialEnabled == true
		)
		XCTAssertTrue(
			migratedNode.storeForwardConfig?.enabled == true &&
			migratedNode.storeForwardConfig?.heartbeat == true &&
			migratedNode.storeForwardConfig?.historyReturnMax == 43 &&
			migratedNode.storeForwardConfig?.historyReturnWindow == 44 &&
			migratedNode.storeForwardConfig?.isRouter == true &&
			migratedNode.storeForwardConfig?.lastHeartbeat == Date(timeIntervalSince1970: 1_700_000_300) &&
			migratedNode.storeForwardConfig?.lastRequest == 45 &&
			migratedNode.storeForwardConfig?.records == 46
		)
		XCTAssertTrue(migratedNode.takConfig?.role == 47 && migratedNode.takConfig?.team == 48)
		let migratedMetadata = try XCTUnwrap(migratedNode.metadata)
		XCTAssertTrue(
			migratedMetadata.canShutdown && migratedMetadata.deviceStateVersion == 49 &&
			migratedMetadata.excludedModules == 50 && migratedMetadata.firmwareVersion == "1.2.3" &&
			migratedMetadata.hasBluetooth && migratedMetadata.hasEthernet && migratedMetadata.hasWifi &&
			migratedMetadata.hwModel == "TEST" && migratedMetadata.positionFlags == 51 &&
			migratedMetadata.role == 52 &&
			migratedMetadata.time == Date(timeIntervalSince1970: 1_700_000_400)
		)
		let migratedPax = try XCTUnwrap(migratedNode.pax.first)
		XCTAssertTrue(
			migratedPax.ble == 53 && migratedPax.time == Date(timeIntervalSince1970: 1_700_000_500) &&
			migratedPax.uptime == 54 && migratedPax.wifi == 55
		)
		let routes = try container.mainContext.fetch(FetchDescriptor<RouteEntity>())
		let migratedRoute = try XCTUnwrap(routes.first(where: { $0.name == "route" }))
		XCTAssertTrue(
			migratedRoute.color == 56 && migratedRoute.date == Date(timeIntervalSince1970: 1_700_000_600) &&
			migratedRoute.distance == 57.5 && migratedRoute.elevationGain == 58.5 &&
			migratedRoute.enabled && migratedRoute.endDate == Date(timeIntervalSince1970: 1_700_000_700) &&
			migratedRoute.id == 59 && migratedRoute.name == "route" && migratedRoute.notes == "notes"
		)
		let migratedLocation = try XCTUnwrap(migratedRoute.locations.first)
		XCTAssertTrue(
			migratedLocation.altitude == 60 && migratedLocation.heading == 61 &&
			migratedLocation.id == 62 && migratedLocation.latitudeI == 63 &&
			migratedLocation.longitudeI == 64 && migratedLocation.speed == 65
		)
		let secondRoute = try XCTUnwrap(routes.first(where: { $0.name == "second route" }))
		XCTAssertEqual(secondRoute.id, 59)
		XCTAssertEqual(secondRoute.locations.first?.latitudeI, 167)
		let orphanLocation = try XCTUnwrap(
			container.mainContext.fetch(FetchDescriptor<LocationEntity>())
				.first(where: { $0.routeLocation == nil })
		)
		XCTAssertTrue(orphanLocation.id == 168 && orphanLocation.latitudeI == 169)
		let traces = try container.mainContext.fetch(FetchDescriptor<TraceRouteEntity>())
		let migratedTrace = try XCTUnwrap(traces.first(where: { $0.routeText == "towards" }))
		XCTAssertTrue(
			migratedTrace.hasPositions && migratedTrace.hopsBack == 66 && migratedTrace.hopsTowards == 67 &&
			migratedTrace.id == 68 && migratedTrace.response && migratedTrace.routeBackText == "back" &&
			migratedTrace.routeText == "towards" && migratedTrace.sent && migratedTrace.snr == 69.5 &&
			migratedTrace.time == Date(timeIntervalSince1970: 1_700_000_800) &&
			migratedTrace.node?.num == 111
		)
		let migratedHop = try XCTUnwrap(migratedTrace.hops.first)
		XCTAssertTrue(
			migratedHop.back && migratedHop.index == 0 && migratedHop.name == "hop" &&
			migratedHop.num == 73 && migratedHop.snr == 74.5 &&
			migratedHop.time == Date(timeIntervalSince1970: 1_700_000_900)
		)
		let migratedTracePosition = try XCTUnwrap(migratedTrace.nodePositions.first)
		XCTAssertTrue(
			migratedTracePosition.num == 73 && migratedTracePosition.altitude == 70 &&
			migratedTracePosition.latitudeI == 71 && migratedTracePosition.longitudeI == 72 &&
			migratedTracePosition.snr == 74.5 &&
			migratedTracePosition.time == Date(timeIntervalSince1970: 1_700_000_900)
		)
		let duplicateIdTrace = try XCTUnwrap(traces.first(where: { $0.routeText == "second trace" }))
		XCTAssertFalse(duplicateIdTrace.hasPositions)
		XCTAssertEqual(duplicateIdTrace.id, 68)
		XCTAssertEqual(duplicateIdTrace.hops.filter { $0.num == 73 }.count, 2)
		XCTAssertEqual(
			Set(duplicateIdTrace.nodePositions.filter { $0.num == 73 }.map(\.latitudeI)),
			Set([Int32(171), Int32(181)])
		)
		let orphanHop = try XCTUnwrap(
			container.mainContext.fetch(FetchDescriptor<TraceRouteHopEntity>())
				.first(where: { $0.traceRoute == nil })
		)
		XCTAssertEqual(orphanHop.num, 193)
		let orphanTracePosition = try XCTUnwrap(
			container.mainContext.fetch(FetchDescriptor<TraceRouteNodePositionEntity>())
				.first(where: { $0.traceRoute == nil })
		)
		XCTAssertTrue(orphanTracePosition.num == 193 && orphanTracePosition.latitudeI == 191)
		let waypoints = try container.mainContext.fetch(FetchDescriptor<WaypointEntity>())
		let migratedWaypoint = try XCTUnwrap(waypoints.first(where: { $0.name == "waypoint" }))
		XCTAssertTrue(
			migratedWaypoint.created == Date(timeIntervalSince1970: 1_700_001_000) &&
			migratedWaypoint.createdBy == 75 &&
			migratedWaypoint.expire == Date(timeIntervalSince1970: 1_700_001_100) &&
			migratedWaypoint.icon == 76 && migratedWaypoint.id == 77 &&
			migratedWaypoint.lastUpdated == Date(timeIntervalSince1970: 1_700_001_200) &&
			migratedWaypoint.lastUpdatedBy == 78 && migratedWaypoint.latitudeI == 79 &&
			migratedWaypoint.locked && migratedWaypoint.longDescription == "description" &&
			migratedWaypoint.longitudeI == 80 && migratedWaypoint.name == "waypoint"
		)
		XCTAssertTrue(
			migratedNode.deviceConfig?.buttonGpio == 81 && migratedNode.deviceConfig?.buzzerGpio == 82 &&
			migratedNode.deviceConfig?.disableTripleClick == true &&
			migratedNode.deviceConfig?.doubleTapAsButtonPress == true &&
			migratedNode.deviceConfig?.isManaged == true &&
			migratedNode.deviceConfig?.ledHeartbeatEnabled == true &&
			migratedNode.deviceConfig?.nodeInfoBroadcastSecs == 83 &&
			migratedNode.deviceConfig?.rebroadcastMode == 84 && migratedNode.deviceConfig?.role == 5 &&
			migratedNode.deviceConfig?.tripleClickAsAdHocPing == true &&
			migratedNode.deviceConfig?.tzdef == "UTC0"
		)
		XCTAssertEqual(migratedNode.bluetoothConfig?.deviceLoggingEnabled, true)
		XCTAssertTrue(
			migratedNode.cannedMessageConfig?.enabled == true &&
			migratedNode.cannedMessageConfig?.messages == "one|two"
		)
		XCTAssertTrue(
			migratedNode.displayConfig?.displayMode == 85 && migratedNode.displayConfig?.headingBold == true &&
			migratedNode.displayConfig?.oledType == 86 && migratedNode.displayConfig?.units == 87 &&
			migratedNode.displayConfig?.use12HClock == true &&
			migratedNode.displayConfig?.wakeOnTapOrMotion == true
		)
		XCTAssertTrue(
			migratedNode.externalNotificationConfig?.alertBellBuzzer == true &&
			migratedNode.externalNotificationConfig?.alertBellVibra == true &&
			migratedNode.externalNotificationConfig?.alertMessageBuzzer == true &&
			migratedNode.externalNotificationConfig?.alertMessageVibra == true &&
			migratedNode.externalNotificationConfig?.nagTimeout == 88 &&
			migratedNode.externalNotificationConfig?.outputBuzzer == 89 &&
			migratedNode.externalNotificationConfig?.outputVibra == 90 &&
			migratedNode.externalNotificationConfig?.useI2SAsBuzzer == true &&
			migratedNode.externalNotificationConfig?.usePWM == true
		)
		XCTAssertTrue(
			migratedNode.loRaConfig?.ignoreMqtt == true && migratedNode.loRaConfig?.okToMqtt == true &&
			migratedNode.loRaConfig?.overrideDutyCycle == true &&
			migratedNode.loRaConfig?.overrideFrequency == 91.5 &&
			migratedNode.loRaConfig?.sx126xRxBoostedGain == true
		)
		XCTAssertTrue(
			migratedNode.mqttConfig?.mapPositionPrecision == 92 &&
			migratedNode.mqttConfig?.mapPublishIntervalSecs == 93 &&
			migratedNode.mqttConfig?.mapReportingEnabled == true &&
			migratedNode.mqttConfig?.mapReportingShouldReportLocation == true &&
			migratedNode.mqttConfig?.proxyToClientEnabled == true &&
			migratedNode.mqttConfig?.root == "root" && migratedNode.mqttConfig?.tlsEnabled == true
		)
		XCTAssertTrue(
			migratedNode.networkConfig?.dns == 94 && migratedNode.networkConfig?.enabledProtocols == 95 &&
			migratedNode.networkConfig?.ethEnabled == true && migratedNode.networkConfig?.gateway == 96 &&
			migratedNode.networkConfig?.ip == 97 && migratedNode.networkConfig?.subnet == 98 &&
			migratedNode.networkConfig?.wifiMode == 99
		)
		XCTAssertTrue(
			migratedNode.positionConfig?.broadcastSmartMinimumDistance == 100 &&
			migratedNode.positionConfig?.broadcastSmartMinimumIntervalSecs == 101 &&
			migratedNode.positionConfig?.gpsEnGpio == 102 && migratedNode.positionConfig?.gpsMode == 103 &&
			migratedNode.positionConfig?.rxGpio == 104 && migratedNode.positionConfig?.txGpio == 105
		)
		XCTAssertEqual(migratedNode.serialConfig?.overrideConsoleSerialPort, true)
		XCTAssertTrue(
			migratedNode.telemetryConfig?.deviceTelemetryEnabled == true &&
			migratedNode.telemetryConfig?.environmentScreenEnabled == true &&
			migratedNode.telemetryConfig?.environmentUpdateInterval == 106 &&
			migratedNode.telemetryConfig?.powerMeasurementEnabled == true &&
			migratedNode.telemetryConfig?.powerScreenEnabled == true &&
			migratedNode.telemetryConfig?.powerUpdateInterval == 107
		)
		let orphanChannels = try container.mainContext.fetch(FetchDescriptor<ChannelEntity>())
			.filter { $0.myInfoChannel == nil }
		XCTAssertEqual(orphanChannels.map(\.index), [7])
		let orphanConfigs = try container.mainContext.fetch(FetchDescriptor<DeviceConfigEntity>())
			.filter { $0.deviceConfigNode == nil }
		XCTAssertEqual(orphanConfigs.count, 1)
		XCTAssertEqual(orphanConfigs.first?.role, 108)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RouteEntity>()), 2)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<LocationEntity>()), 3)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TraceRouteEntity>()), 2)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TraceRouteHopEntity>()), 4)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TraceRouteNodePositionEntity>()), 4)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<WaypointEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PaxCounterEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DeviceMetadataEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<AmbientLightingConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DetectionSensorConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PaxCounterConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PowerConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RTTTLConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<SecurityConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoreForwardConfigEntity>()), 1)
		XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TAKConfigEntity>()), 1)
		try assertBackupStoreIsReadable(at: locations.backupStoreURL)
	}

	private func assertBackupStoreIsReadable(at storeURL: URL) throws {
		let momdURL = try XCTUnwrap(Bundle.main.url(forResource: "Meshtastic", withExtension: "momd"))
		let modelURL = momdURL.appendingPathComponent("MeshtasticDataModelV 58.mom")
		let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
		let container = NSPersistentContainer(name: "Meshtastic", managedObjectModel: model)
		let description = NSPersistentStoreDescription(url: storeURL)
		description.shouldAddStoreAsynchronously = false
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }

		let context = container.viewContext
		for (entityName, expectedCount) in [
			("NodeInfoEntity", 1), ("UserEntity", 1), ("MyInfoEntity", 1),
			("ChannelEntity", 2), ("MessageEntity", 2), ("PositionEntity", 3),
			("TelemetryEntity", 2), ("DeviceConfigEntity", 2),
			("BluetoothConfigEntity", 1), ("CannedMessageConfigEntity", 1),
			("DisplayConfigEntity", 1), ("ExternalNotificationConfigEntity", 1),
			("LoRaConfigEntity", 1), ("MQTTConfigEntity", 1), ("NetworkConfigEntity", 1),
			("PositionConfigEntity", 1), ("SerialConfigEntity", 1), ("TelemetryConfigEntity", 1),
			("AmbientLightingConfigEntity", 1), ("DetectionSensorConfigEntity", 1),
			("PaxCounterConfigEntity", 1), ("PowerConfigEntity", 1),
			("RTTTLConfigEntity", 1), ("SecurityConfigEntity", 1),
			("StoreForwardConfigEntity", 1), ("TAKConfigEntity", 1),
			("DeviceMetadataEntity", 1), ("PaxCounterEntity", 1),
			("RouteEntity", 2), ("LocationEntity", 3), ("TraceRouteEntity", 2),
			("TraceRouteHopEntity", 4), ("WaypointEntity", 1)
		] {
			let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
			XCTAssertEqual(try context.count(for: request), expectedCount, entityName)
		}
		for store in container.persistentStoreCoordinator.persistentStores {
			try container.persistentStoreCoordinator.remove(store)
		}
	}

	private func sidecar(of storeURL: URL, suffix: String) -> URL {
		storeURL.deletingPathExtension().appendingPathExtension("sqlite\(suffix)")
	}

	// swiftlint:disable:next function_body_length
	private func buildLegacyStore(at storeURL: URL) throws {
		let momdURL = try XCTUnwrap(Bundle.main.url(forResource: "Meshtastic", withExtension: "momd"))
		let modelURL = momdURL.appendingPathComponent("MeshtasticDataModelV 58.mom")
		let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
		let container = NSPersistentContainer(name: "Meshtastic", managedObjectModel: model)
		let description = NSPersistentStoreDescription(url: storeURL)
		description.shouldAddStoreAsynchronously = false
		container.persistentStoreDescriptions = [description]
		var loadError: Error?
		container.loadPersistentStores { _, error in loadError = error }
		if let loadError { throw loadError }

		let context = container.viewContext
		func insert(_ entityName: String) -> NSManagedObject {
			NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
		}

		let node = insert("NodeInfoEntity")
		node.setValue("Legacy BLE", forKey: "bleName")
		node.setValue(Int32(2), forKey: "channel")
		node.setValue(true, forKey: "favorite")
		node.setValue(Date(timeIntervalSince1970: 1_699_999_999), forKey: "firstHeard")
		node.setValue(Int32(3), forKey: "hopsAway")
		node.setValue(Int64(4), forKey: "id")
		node.setValue(true, forKey: "ignored")
		node.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "lastHeard")
		node.setValue(Int64(111), forKey: "num")
		node.setValue("peripheral", forKey: "peripheralId")
		node.setValue(Int32(-70), forKey: "rssi")
		node.setValue(Date(timeIntervalSince1970: 1_700_000_100), forKey: "sessionExpiration")
		node.setValue(Data([4, 5, 6]), forKey: "sessionPasskey")
		node.setValue(Float(7.5), forKey: "snr")
		node.setValue(true, forKey: "viaMqtt")

		let user = insert("UserEntity")
		user.setValue(Int64(111), forKey: "num")
		user.setValue("Test Hardware", forKey: "hwDisplayName")
		user.setValue("TEST", forKey: "hwModel")
		user.setValue(Int32(8), forKey: "hwModelId")
		user.setValue(true, forKey: "isLicensed")
		user.setValue(false, forKey: "keyMatch")
		user.setValue(Date(timeIntervalSince1970: 1_700_000_200), forKey: "lastMessage")
		user.setValue("Legacy User", forKey: "longName")
		user.setValue(true, forKey: "mute")
		user.setValue(Data([7, 8]), forKey: "newPublicKey")
		user.setValue("111", forKey: "numString")
		user.setValue(true, forKey: "pkiEncrypted")
		user.setValue(Data([9, 10]), forKey: "publicKey")
		user.setValue(Int32(11), forKey: "role")
		user.setValue("LU", forKey: "shortName")
		user.setValue(true, forKey: "unmessagable")
		user.setValue("!0000006f", forKey: "userId")
		user.setValue(node, forKey: "userNode")

		let myInfo = insert("MyInfoEntity")
		myInfo.setValue("My BLE", forKey: "bleName")
		myInfo.setValue(Data([12, 13]), forKey: "deviceId")
		myInfo.setValue(Int32(14), forKey: "minAppVersion")
		myInfo.setValue(Int64(111), forKey: "myNodeNum")
		myInfo.setValue("my-peripheral", forKey: "peripheralId")
		myInfo.setValue("pio", forKey: "pioEnv")
		myInfo.setValue(Int32(15), forKey: "rebootCount")
		myInfo.setValue(true, forKey: "registered")
		myInfo.setValue(node, forKey: "myInfoNode")

		let channel = insert("ChannelEntity")
		channel.setValue(true, forKey: "downlinkEnabled")
		channel.setValue(Int32(16), forKey: "id")
		channel.setValue(Int32(0), forKey: "index")
		channel.setValue(true, forKey: "mute")
		channel.setValue("LegacyChan", forKey: "name")
		channel.setValue(Int32(17), forKey: "positionPrecision")
		channel.setValue(Data([18, 19]), forKey: "psk")
		channel.setValue(Int32(20), forKey: "role")
		channel.setValue(true, forKey: "uplinkEnabled")
		channel.setValue(myInfo, forKey: "myInfoChannel")

		let config = insert("DeviceConfigEntity")
		config.setValue(Int32(81), forKey: "buttonGpio")
		config.setValue(Int32(82), forKey: "buzzerGpio")
		config.setValue(true, forKey: "disableTripleClick")
		config.setValue(true, forKey: "doubleTapAsButtonPress")
		config.setValue(true, forKey: "isManaged")
		config.setValue(true, forKey: "ledHeartbeatEnabled")
		config.setValue(Int32(83), forKey: "nodeInfoBroadcastSecs")
		config.setValue(Int32(84), forKey: "rebroadcastMode")
		config.setValue(Int32(5), forKey: "role")
		config.setValue(true, forKey: "tripleClickAsAdHocPing")
		config.setValue("UTC0", forKey: "tzdef")
		config.setValue(node, forKey: "deviceConfigNode")

		let bluetooth = insert("BluetoothConfigEntity")
		bluetooth.setValue(true, forKey: "deviceLoggingEnabled")
		bluetooth.setValue(node, forKey: "bluetoothConfigNode")

		let canned = insert("CannedMessageConfigEntity")
		canned.setValue(true, forKey: "enabled")
		canned.setValue("one|two", forKey: "messages")
		canned.setValue(node, forKey: "cannedMessagesConfigNode")

		let display = insert("DisplayConfigEntity")
		display.setValue(Int32(85), forKey: "displayMode")
		display.setValue(true, forKey: "headingBold")
		display.setValue(Int32(86), forKey: "oledType")
		display.setValue(Int32(87), forKey: "units")
		display.setValue(true, forKey: "use12HClock")
		display.setValue(true, forKey: "wakeOnTapOrMotion")
		display.setValue(node, forKey: "displayConfigNode")

		let external = insert("ExternalNotificationConfigEntity")
		external.setValue(true, forKey: "alertBellBuzzer")
		external.setValue(true, forKey: "alertBellVibra")
		external.setValue(true, forKey: "alertMessageBuzzer")
		external.setValue(true, forKey: "alertMessageVibra")
		external.setValue(Int32(88), forKey: "nagTimeout")
		external.setValue(Int32(89), forKey: "outputBuzzer")
		external.setValue(Int32(90), forKey: "outputVibra")
		external.setValue(true, forKey: "useI2SAsBuzzer")
		external.setValue(true, forKey: "usePWM")
		external.setValue(node, forKey: "externalNotificationConfigNode")

		let lora = insert("LoRaConfigEntity")
		lora.setValue(Int32(6), forKey: "hopLimit")
		lora.setValue(true, forKey: "ignoreMqtt")
		lora.setValue(true, forKey: "okToMqtt")
		lora.setValue(true, forKey: "overrideDutyCycle")
		lora.setValue(Float(91.5), forKey: "overrideFrequency")
		lora.setValue(true, forKey: "sx126xRxBoostedGain")
		lora.setValue(node, forKey: "loRaConfigNode")

		let mqtt = insert("MQTTConfigEntity")
		mqtt.setValue(Int32(92), forKey: "mapPositionPrecision")
		mqtt.setValue(Int32(93), forKey: "mapPublishIntervalSecs")
		mqtt.setValue(true, forKey: "mapReportingEnabled")
		mqtt.setValue(true, forKey: "mapReportingShouldReportLocation")
		mqtt.setValue(true, forKey: "proxyToClientEnabled")
		mqtt.setValue("root", forKey: "root")
		mqtt.setValue(true, forKey: "tlsEnabled")
		mqtt.setValue(node, forKey: "mqttConfigNode")

		let network = insert("NetworkConfigEntity")
		network.setValue(Int32(94), forKey: "dns")
		network.setValue(Int32(95), forKey: "enabledProtocols")
		network.setValue(true, forKey: "ethEnabled")
		network.setValue(Int32(96), forKey: "gateway")
		network.setValue(Int32(97), forKey: "ip")
		network.setValue(Int32(98), forKey: "subnet")
		network.setValue(Int32(99), forKey: "wifiMode")
		network.setValue(node, forKey: "networkConfigNode")

		let positionConfig = insert("PositionConfigEntity")
		positionConfig.setValue(Int32(100), forKey: "broadcastSmartMinimumDistance")
		positionConfig.setValue(Int32(101), forKey: "broadcastSmartMinimumIntervalSecs")
		positionConfig.setValue(Int32(102), forKey: "gpsEnGpio")
		positionConfig.setValue(Int32(103), forKey: "gpsMode")
		positionConfig.setValue(Int32(104), forKey: "rxGpio")
		positionConfig.setValue(Int32(105), forKey: "txGpio")
		positionConfig.setValue(node, forKey: "positionConfigNode")

		let serial = insert("SerialConfigEntity")
		serial.setValue(true, forKey: "overrideConsoleSerialPort")
		serial.setValue(node, forKey: "serialConfigNode")

		let telemetryConfig = insert("TelemetryConfigEntity")
		telemetryConfig.setValue(true, forKey: "deviceTelemetryEnabled")
		telemetryConfig.setValue(true, forKey: "environmentScreenEnabled")
		telemetryConfig.setValue(Int32(106), forKey: "environmentUpdateInterval")
		telemetryConfig.setValue(true, forKey: "powerMeasurementEnabled")
		telemetryConfig.setValue(true, forKey: "powerScreenEnabled")
		telemetryConfig.setValue(Int32(107), forKey: "powerUpdateInterval")
		telemetryConfig.setValue(node, forKey: "telemetryConfigNode")

		let ambient = insert("AmbientLightingConfigEntity")
		ambient.setValue(Int32(21), forKey: "blue")
		ambient.setValue(Int32(22), forKey: "current")
		ambient.setValue(Int32(23), forKey: "green")
		ambient.setValue(true, forKey: "ledState")
		ambient.setValue(Int32(24), forKey: "red")
		ambient.setValue(node, forKey: "ambientLightingConfigNode")

		let detection = insert("DetectionSensorConfigEntity")
		detection.setValue(true, forKey: "enabled")
		detection.setValue(Int32(25), forKey: "minimumBroadcastSecs")
		detection.setValue(Int32(26), forKey: "monitorPin")
		detection.setValue("sensor", forKey: "name")
		detection.setValue(true, forKey: "sendBell")
		detection.setValue(Int32(27), forKey: "stateBroadcastSecs")
		detection.setValue(Int32(28), forKey: "triggerType")
		detection.setValue(true, forKey: "usePullup")
		detection.setValue(node, forKey: "detectionSensorConfigNode")

		let paxConfig = insert("PaxCounterConfigEntity")
		paxConfig.setValue(Int32(29), forKey: "bleThreshold")
		paxConfig.setValue(true, forKey: "enabled")
		paxConfig.setValue(Int32(30), forKey: "updateInterval")
		paxConfig.setValue(Int32(-31), forKey: "wifiThreshold")
		paxConfig.setValue(node, forKey: "paxCounterConfigNode")

		let power = insert("PowerConfigEntity")
		power.setValue(Float(32.5), forKey: "adcMultiplierOverride")
		power.setValue(Int32(33), forKey: "deviceBatteryInaAddress")
		power.setValue(true, forKey: "isPowerSaving")
		power.setValue(Int32(34), forKey: "lsSecs")
		power.setValue(Int32(35), forKey: "minWakeSecs")
		power.setValue(Int32(36), forKey: "onBatteryShutdownAfterSecs")
		power.setValue(Int32(37), forKey: "waitBluetoothSecs")
		power.setValue(node, forKey: "powerConfigNode")

		let rtttl = insert("RTTTLConfigEntity")
		rtttl.setValue("ringtone", forKey: "ringtone")
		rtttl.setValue(node, forKey: "rtttlConfigNode")

		let security = insert("SecurityConfigEntity")
		security.setValue(true, forKey: "adminChannelEnabled")
		security.setValue(Data([38]), forKey: "adminKey")
		security.setValue(Data([39]), forKey: "adminKey2")
		security.setValue(Data([40]), forKey: "adminKey3")
		security.setValue(true, forKey: "bluetoothLoggingEnabled")
		security.setValue(true, forKey: "debugLogApiEnabled")
		security.setValue(true, forKey: "isManaged")
		security.setValue(Data([41]), forKey: "privateKey")
		security.setValue(Data([42]), forKey: "publicKey")
		security.setValue(true, forKey: "serialEnabled")
		security.setValue(node, forKey: "securityConfigNode")

		let storeForward = insert("StoreForwardConfigEntity")
		storeForward.setValue(true, forKey: "enabled")
		storeForward.setValue(true, forKey: "heartbeat")
		storeForward.setValue(Int32(43), forKey: "historyReturnMax")
		storeForward.setValue(Int32(44), forKey: "historyReturnWindow")
		storeForward.setValue(true, forKey: "isRouter")
		storeForward.setValue(Date(timeIntervalSince1970: 1_700_000_300), forKey: "lastHeartbeat")
		storeForward.setValue(Int32(45), forKey: "lastRequest")
		storeForward.setValue(Int32(46), forKey: "records")
		storeForward.setValue(node, forKey: "storeForwardConfigNode")

		let tak = insert("TAKConfigEntity")
		tak.setValue(Int32(47), forKey: "role")
		tak.setValue(Int32(48), forKey: "team")
		tak.setValue(node, forKey: "takConfigNode")

		let metadata = insert("DeviceMetadataEntity")
		metadata.setValue(true, forKey: "canShutdown")
		metadata.setValue(Int32(49), forKey: "deviceStateVersion")
		metadata.setValue(Int32(50), forKey: "excludedModules")
		metadata.setValue("1.2.3", forKey: "firmwareVersion")
		metadata.setValue(true, forKey: "hasBluetooth")
		metadata.setValue(true, forKey: "hasEthernet")
		metadata.setValue(true, forKey: "hasWifi")
		metadata.setValue("TEST", forKey: "hwModel")
		metadata.setValue(Int32(51), forKey: "positionFlags")
		metadata.setValue(Int32(52), forKey: "role")
		metadata.setValue(Date(timeIntervalSince1970: 1_700_000_400), forKey: "time")
		metadata.setValue(node, forKey: "metadataNode")

		let pax = insert("PaxCounterEntity")
		pax.setValue(Int32(53), forKey: "ble")
		pax.setValue(Date(timeIntervalSince1970: 1_700_000_500), forKey: "time")
		pax.setValue(Int32(54), forKey: "uptime")
		pax.setValue(Int32(55), forKey: "wifi")
		pax.setValue(node, forKey: "paxNode")

		let route = insert("RouteEntity")
		route.setValue(Int64(56), forKey: "color")
		route.setValue(Date(timeIntervalSince1970: 1_700_000_600), forKey: "date")
		route.setValue(Double(57.5), forKey: "distance")
		route.setValue(Double(58.5), forKey: "elevationGain")
		route.setValue(true, forKey: "enabled")
		route.setValue(Date(timeIntervalSince1970: 1_700_000_700), forKey: "endDate")
		route.setValue(Int32(59), forKey: "id")
		route.setValue("route", forKey: "name")
		route.setValue("notes", forKey: "notes")
		let location = insert("LocationEntity")
		location.setValue(Int32(60), forKey: "altitude")
		location.setValue(Int32(61), forKey: "heading")
		location.setValue(Int32(62), forKey: "id")
		location.setValue(Int32(63), forKey: "latitudeI")
		location.setValue(Int32(64), forKey: "longitudeI")
		location.setValue(Int32(65), forKey: "speed")
		location.setValue(route, forKey: "routeLocation")
		let duplicateIdRoute = insert("RouteEntity")
		duplicateIdRoute.setValue(Int32(59), forKey: "id")
		duplicateIdRoute.setValue("second route", forKey: "name")
		let secondLocation = insert("LocationEntity")
		secondLocation.setValue(Int32(166), forKey: "id")
		secondLocation.setValue(Int32(167), forKey: "latitudeI")
		secondLocation.setValue(duplicateIdRoute, forKey: "routeLocation")
		let orphanLocation = insert("LocationEntity")
		orphanLocation.setValue(Int32(168), forKey: "id")
		orphanLocation.setValue(Int32(169), forKey: "latitudeI")

		let traceRoute = insert("TraceRouteEntity")
		traceRoute.setValue(true, forKey: "hasPositions")
		traceRoute.setValue(Int32(66), forKey: "hopsBack")
		traceRoute.setValue(Int32(67), forKey: "hopsTowards")
		traceRoute.setValue(Int64(68), forKey: "id")
		traceRoute.setValue(true, forKey: "response")
		traceRoute.setValue("back", forKey: "routeBackText")
		traceRoute.setValue("towards", forKey: "routeText")
		traceRoute.setValue(true, forKey: "sent")
		traceRoute.setValue(Float(69.5), forKey: "snr")
		traceRoute.setValue(Date(timeIntervalSince1970: 1_700_000_800), forKey: "time")
		traceRoute.setValue(node, forKey: "node")
		let hop = insert("TraceRouteHopEntity")
		hop.setValue(Int32(70), forKey: "altitude")
		hop.setValue(true, forKey: "back")
		hop.setValue(Int32(71), forKey: "latitudeI")
		hop.setValue(Int32(72), forKey: "longitudeI")
		hop.setValue("hop", forKey: "name")
		hop.setValue(Int64(73), forKey: "num")
		hop.setValue(Float(74.5), forKey: "snr")
		hop.setValue(Date(timeIntervalSince1970: 1_700_000_900), forKey: "time")
		hop.setValue(traceRoute, forKey: "traceRoute")
		let duplicateIdTrace = insert("TraceRouteEntity")
		duplicateIdTrace.setValue(false, forKey: "hasPositions")
		duplicateIdTrace.setValue(Int64(68), forKey: "id")
		duplicateIdTrace.setValue("second trace", forKey: "routeText")
		for (altitude, latitude, longitude, time) in [
			(Int32(170), Int32(171), Int32(172), 1_700_000_901.0),
			(Int32(180), Int32(181), Int32(182), 1_700_000_902.0)
		] {
			let repeatedHop = insert("TraceRouteHopEntity")
			repeatedHop.setValue(altitude, forKey: "altitude")
			repeatedHop.setValue(latitude, forKey: "latitudeI")
			repeatedHop.setValue(longitude, forKey: "longitudeI")
			repeatedHop.setValue(Int64(73), forKey: "num")
			repeatedHop.setValue(Float(174.5), forKey: "snr")
			repeatedHop.setValue(Date(timeIntervalSince1970: time), forKey: "time")
			repeatedHop.setValue(duplicateIdTrace, forKey: "traceRoute")
		}
		let orphanHop = insert("TraceRouteHopEntity")
		orphanHop.setValue(Int32(190), forKey: "altitude")
		orphanHop.setValue(Int32(191), forKey: "latitudeI")
		orphanHop.setValue(Int32(192), forKey: "longitudeI")
		orphanHop.setValue(Int64(193), forKey: "num")
		orphanHop.setValue(Date(timeIntervalSince1970: 1_700_000_903), forKey: "time")

		let waypoint = insert("WaypointEntity")
		waypoint.setValue(Date(timeIntervalSince1970: 1_700_001_000), forKey: "created")
		waypoint.setValue(Int64(75), forKey: "createdBy")
		waypoint.setValue(Date(timeIntervalSince1970: 1_700_001_100), forKey: "expire")
		waypoint.setValue(Int64(76), forKey: "icon")
		waypoint.setValue(Int64(77), forKey: "id")
		waypoint.setValue(Date(timeIntervalSince1970: 1_700_001_200), forKey: "lastUpdated")
		waypoint.setValue(Int64(78), forKey: "lastUpdatedBy")
		waypoint.setValue(Int32(79), forKey: "latitudeI")
		waypoint.setValue(Int64(1), forKey: "locked")
		waypoint.setValue("description", forKey: "longDescription")
		waypoint.setValue(Int32(80), forKey: "longitudeI")
		waypoint.setValue("waypoint", forKey: "name")
		for messageId in [Int64(1001), Int64(1002)] {
			let message = insert("MessageEntity")
			message.setValue(Int32(1), forKey: "ackError")
			message.setValue(Float(2.5), forKey: "ackSNR")
			message.setValue(Int32(3), forKey: "ackTimestamp")
			message.setValue(true, forKey: "admin")
			message.setValue("admin", forKey: "adminDescription")
			message.setValue(Int32(4), forKey: "channel")
			message.setValue(true, forKey: "isEmoji")
			message.setValue(messageId, forKey: "messageId")
			message.setValue("message \(messageId)", forKey: "messagePayload")
			message.setValue("markdown", forKey: "messagePayloadMarkdown")
			message.setValue("translated", forKey: "messagePayloadTranslated")
			message.setValue("translated markdown", forKey: "messagePayloadTranslatedMarkdown")
			message.setValue(Int32(5), forKey: "messageTimestamp")
			message.setValue(true, forKey: "pkiEncrypted")
			message.setValue(Int32(6), forKey: "portNum")
			message.setValue(Data([1, 2, 3]), forKey: "publicKey")
			message.setValue(true, forKey: "read")
			message.setValue(true, forKey: "realACK")
			message.setValue(false, forKey: "receivedACK")
			message.setValue(Int64(9), forKey: "relayNode")
			message.setValue(Int16(2), forKey: "relays")
			message.setValue(Int64(10), forKey: "replyID")
			message.setValue(Int32(-80), forKey: "rssi")
			message.setValue(true, forKey: "showTranslatedMessage")
			message.setValue(Float(14.5), forKey: "snr")
			message.setValue(user, forKey: "fromUser")
			message.setValue(user, forKey: "toUser")
		}

		func insertPosition(latitude: Int32, time: TimeInterval) {
			let position = insert("PositionEntity")
			position.setValue(Int32(123), forKey: "altitude")
			position.setValue(Int32(45), forKey: "heading")
			position.setValue(latitude == 38_000_000, forKey: "latest")
			position.setValue(latitude, forKey: "latitudeI")
			position.setValue(Int32(-122_000_000), forKey: "longitudeI")
			position.setValue(Int32(17), forKey: "precisionBits")
			position.setValue(Int32(-42), forKey: "rssi")
			position.setValue(Int32(7), forKey: "satsInView")
			position.setValue(Int32(8), forKey: "seqNo")
			position.setValue(Float(9.5), forKey: "snr")
			position.setValue(Int32(10), forKey: "speed")
			position.setValue(Date(timeIntervalSince1970: time), forKey: "time")
			position.setValue(node, forKey: "nodePosition")
		}
		insertPosition(latitude: 37_000_000, time: 1_700_000_001)
		insertPosition(latitude: 37_000_000, time: 1_700_000_001)
		insertPosition(latitude: 38_000_000, time: 1_700_000_002)

		func insertTelemetry(populated: Bool, time: TimeInterval) {
			let telemetry = insert("TelemetryEntity")
			telemetry.setValue(Int32(1), forKey: "metricsType")
			telemetry.setValue(Int32(2), forKey: "numOnlineNodes")
			telemetry.setValue(Int32(3), forKey: "numPacketsRx")
			telemetry.setValue(Int32(4), forKey: "numPacketsRxBad")
			telemetry.setValue(Int32(5), forKey: "numPacketsTx")
			telemetry.setValue(Int32(6), forKey: "numRxDupe")
			telemetry.setValue(Int32(7), forKey: "numTotalNodes")
			telemetry.setValue(Int32(8), forKey: "numTxRelay")
			telemetry.setValue(Int32(9), forKey: "numTxRelayCanceled")
			if populated {
				telemetry.setValue(Float(10.5), forKey: "airUtilTx")
				telemetry.setValue(Float(11.5), forKey: "barometricPressure")
				telemetry.setValue(Int32(12), forKey: "batteryLevel")
				telemetry.setValue(Float(13.5), forKey: "channelUtilization")
				telemetry.setValue(Float(14.5), forKey: "current")
				telemetry.setValue(Float(15.5), forKey: "gasResistance")
				telemetry.setValue(Int32(16), forKey: "iaq")
				telemetry.setValue(Float(17.5), forKey: "irLux")
				telemetry.setValue(Float(18.5), forKey: "lux")
				telemetry.setValue(Float(19.5), forKey: "powerCh1Current")
				telemetry.setValue(Float(20.5), forKey: "powerCh1Voltage")
				telemetry.setValue(Float(21.5), forKey: "powerCh2Current")
				telemetry.setValue(Float(22.5), forKey: "powerCh2Voltage")
				telemetry.setValue(Float(23.5), forKey: "powerCh3Current")
				telemetry.setValue(Float(24.5), forKey: "powerCh3Voltage")
				telemetry.setValue(Float(25.5), forKey: "radiation")
				telemetry.setValue(Float(26.5), forKey: "rainfall1H")
				telemetry.setValue(Float(27.5), forKey: "rainfall24H")
				telemetry.setValue(Float(28.5), forKey: "relativeHumidity")
				telemetry.setValue(Int32(-29), forKey: "rssi")
				telemetry.setValue(Float(30.5), forKey: "snr")
				telemetry.setValue(Int32(bitPattern: 4_000_000_000), forKey: "soilMoisture")
				telemetry.setValue(Float(32.5), forKey: "soilTemperature")
				telemetry.setValue(Float(33.5), forKey: "temperature")
				telemetry.setValue(Int32(34), forKey: "uptimeSeconds")
				telemetry.setValue(Float(35.5), forKey: "uvLux")
				telemetry.setValue(Float(36.5), forKey: "voltage")
				telemetry.setValue(Float(37.5), forKey: "weight")
				telemetry.setValue(Float(38.5), forKey: "whiteLux")
				telemetry.setValue(Int32(39), forKey: "windDirection")
				telemetry.setValue(Float(40.5), forKey: "windGust")
				telemetry.setValue(Float(41.5), forKey: "windLull")
				telemetry.setValue(Float(42.5), forKey: "windSpeed")
			}
			telemetry.setValue(Date(timeIntervalSince1970: time), forKey: "time")
			telemetry.setValue(node, forKey: "nodeTelemetry")
		}
		insertTelemetry(populated: true, time: 1_700_000_003)
		insertTelemetry(populated: false, time: 1_700_000_004)

		// V58 permits these orphans. Migration must preserve them without retry duplicates.
		let orphanChannel = insert("ChannelEntity")
		orphanChannel.setValue(Int32(7), forKey: "index")
		let orphanConfig = insert("DeviceConfigEntity")
		orphanConfig.setValue(Int32(108), forKey: "role")

		try context.save()
		for store in container.persistentStoreCoordinator.persistentStores {
			try container.persistentStoreCoordinator.remove(store)
		}
	}
}

private struct TestInterruption: Error {}

private struct PositionIdentity: Equatable {
	let latitudeI: Int32
	let time: TimeInterval
	let latest: Bool

	init(_ position: PositionEntity) {
		latitudeI = position.latitudeI
		time = position.time?.timeIntervalSince1970 ?? 0
		latest = position.latest
	}

	init(latitudeI: Int32, time: TimeInterval, latest: Bool) {
		self.latitudeI = latitudeI
		self.time = time
		self.latest = latest
	}
}

private struct MigrationCounts: Equatable {
	let messages: Int
	let positions: Int
	let telemetry: Int
	let channels: Int
	let deviceConfigs: Int

	static let final = MigrationCounts(messages: 2, positions: 3, telemetry: 2, channels: 2, deviceConfigs: 2)
}
