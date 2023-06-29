import ArgumentParser
import Dispatch
import Sentry
import SwiftUI
import SwiftDate

struct Prune: AsyncParsableCommand {
  static var configuration = CommandConfiguration(abstract: "Prune OCI and IPSW caches")

  @Option(help: ArgumentHelp("Remove cache entries last accessed more than n days ago",
                             discussion: "For example, --older-than=7 will remove entries that weren't accessed by Tart in the last 7 days.",
                             valueName: "n"))
  var olderThan: UInt?

  @Option(help: ArgumentHelp("Remove least recently used cache entries that do not fit the specified cache size budget n, expressed in gigabytes",
                             discussion: "For example, --cache-budget=50 will effectively shrink all caches to a total size of 50 gigabytes.",
                             valueName: "n"))
  var cacheBudget: UInt?

  @Flag(help: .hidden)
  var gc: Bool = false

  func validate() throws {
    if olderThan == nil && cacheBudget == nil && !gc {
      throw ValidationError("at least one pruning criteria must be specified")
    }
  }

  func run() async throws {
    if gc {
      try VMStorageOCI().gc()
    }

    // Clean up cache entries based on last accessed date
    if let olderThan = olderThan {
      let olderThanInterval = Int(exactly: olderThan)!.days.timeInterval
      let olderThanDate = Date().addingTimeInterval(olderThanInterval)

      try Prune.pruneOlderThan(olderThanDate: olderThanDate)
    }

    // Clean up cache entries based on imposed cache size limit and entry's last accessed date
    if let cacheBudget = cacheBudget {
      try Prune.pruneCacheBudget(cacheBudgetBytes: UInt64(cacheBudget) * 1024 * 1024 * 1024)
    }
  }

  static func pruneOlderThan(olderThanDate: Date) throws {
    let prunableStorages: [PrunableStorage] = [VMStorageOCI(), try IPSWCache()]
    let prunables: [Prunable] = try prunableStorages.flatMap { try $0.prunables() }

    try prunables.filter { try $0.accessDate() <= olderThanDate }.forEach { try $0.delete() }
  }

  static func pruneCacheBudget(cacheBudgetBytes: UInt64) throws {
    let prunableStorages: [PrunableStorage] = [VMStorageOCI(), try IPSWCache()]
    let prunables: [Prunable] = try prunableStorages
      .flatMap { try $0.prunables() }
      .sorted { try $0.accessDate() > $1.accessDate() }

    var cacheBudgetBytes = cacheBudgetBytes
    var prunablesToDelete: [Prunable] = []

    for prunable in prunables {
      let prunableSizeBytes = UInt64(try prunable.sizeBytes())

      if prunableSizeBytes <= cacheBudgetBytes {
        // Don't mark for deletion as
        // there's a budget available
        cacheBudgetBytes -= prunableSizeBytes
      } else {
        // Mark for deletion
        prunablesToDelete.append(prunable)
      }
    }

    try prunablesToDelete.forEach { try $0.delete() }
  }

  static func reclaimIfNeeded(_ requiredBytes: UInt64) throws {
    SentrySDK.configureScope { scope in
      scope.setContext(value: ["requiredBytes": requiredBytes], key: "Prune")
    }

    // Figure out how much disk space is available
    let attrs = try Config().tartCacheDir.resourceValues(forKeys: [
      .volumeAvailableCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey
    ])
    let volumeAvailableCapacityCalculated = max(
      UInt64(attrs.volumeAvailableCapacity!),
      UInt64(attrs.volumeAvailableCapacityForImportantUsage!)
    )

    SentrySDK.configureScope { scope in
      scope.setContext(value: [
        "volumeAvailableCapacity": attrs.volumeAvailableCapacity!,
        "volumeAvailableCapacityForImportantUsage": attrs.volumeAvailableCapacityForImportantUsage!,
        "volumeAvailableCapacityCalculated": volumeAvailableCapacityCalculated
      ], key: "Prune")
    }

    if volumeAvailableCapacityCalculated <= 0 {
      SentrySDK.capture(message: "Zero volume capacity reported") { scope in
        scope.setLevel(.warning)
      }

      return
    }

    // Now that we know how much free space is left,
    // check if we even need to reclaim anything
    if requiredBytes < volumeAvailableCapacityCalculated {
      return
    }

    try Prune.reclaimIfPossible(requiredBytes - volumeAvailableCapacityCalculated)
  }

  private static func reclaimIfPossible(_ reclaimBytes: UInt64) throws {
    let transaction = SentrySDK.startTransaction(name: "Pruning cache", operation: "prune", bindToScope: true)
    defer { transaction.finish() }

    let prunableStorages: [PrunableStorage] = [VMStorageOCI(), try IPSWCache()]
    let prunables: [Prunable] = try prunableStorages
      .flatMap { try $0.prunables() }
      .sorted { try $0.accessDate() < $1.accessDate() }

    // Does it even make sense to start?
    let cacheUsedBytes = try prunables.map { try $0.sizeBytes() }.reduce(0, +)
    if cacheUsedBytes < reclaimBytes {
      return
    }

    var cacheReclaimedBytes: Int = 0

    var it = prunables.makeIterator()

    while cacheReclaimedBytes <= reclaimBytes {
      guard let prunable = it.next() else {
        break
      }

      try SentrySDK.span?.setData(value: prunable.sizeBytes(), key: prunable.url.path)

      cacheReclaimedBytes += try prunable.sizeBytes()

      try prunable.delete()
    }

    SentrySDK.span?.setMeasurement(name: "gc_disk_reclaimed", value: cacheReclaimedBytes as NSNumber, unit: MeasurementUnitInformation.byte);
  }
}
