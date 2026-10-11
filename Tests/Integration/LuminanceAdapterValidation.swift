import Foundation
import CoreGraphics

/// Exercises only getters. This executable does not create an app, request
/// privacy permissions, set brightness, or write a transfer table.
@main
struct LuminanceAdapterValidation {
    private static var checks: [String: Bool] = [:]

    static func main() {
        #if HEADROOM_LUMINANCE_FORCE_FALLBACK
        let mode = "forced-preset-fallback"
        #else
        let mode = "corebrightness-and-fallback"
        validateParser()
        #endif

        let ids = onlineDisplays()
        let before = ids.reduce(into: [UInt32: [[Float]]]()) { result, id in
            result[id] = gamma(displayID: id)
        }
        let reader = DisplayLuminanceReader()
        check(reader.reading(displayID: 0) == nil, "readerRejectsZeroDisplay")
        check(reader.reading(displayID: UInt32.max) == nil, "readerRejectsNonexistentDisplay")
        let legacy = DisplayLuminanceReadingSnapshot(referenceNits: 123, maximumHDRNits: nil)
        check(legacy.referenceNits == 123 && legacy.systemTelemetry == nil && legacy.maximumHDRNits == nil,
              "legacySnapshotHasNoFabricatedTelemetry")
        var readings: [[String: Any]] = []
        var supported = 0
        for id in ids {
            guard let snapshot = reader.reading(displayID: id) else {
                readings.append(["displayID": id, "source": "unavailable"])
                continue
            }
            supported += 1
            check(snapshot.referenceNits.isFinite && snapshot.referenceNits >= 0,
                  "display\(id)UsableNativeReference")
            var entry: [String: Any] = ["displayID": id, "referenceNits": snapshot.referenceNits,
                                       "maximumHDRNits": snapshot.maximumHDRNits as Any? ?? NSNull()]
            #if HEADROOM_LUMINANCE_FORCE_FALLBACK
            check(snapshot.systemTelemetry == nil, "display\(id)FallbackHasNoSystemTelemetry")
            entry["source"] = "preset-fallback"
            #else
            if let telemetry = snapshot.systemTelemetry {
                if let physical = telemetry.reportedPhysicalNits {
                    check(snapshot.referenceNits == physical,
                          "display\(id)ReferenceUsesReportedNativeNits")
                    check(snapshot.maximumHDRNits == telemetry.maximumHDRNits,
                          "display\(id)LimitUsesSameSnapshotHDR")
                    entry["source"] = "corebrightness-reported-native"
                } else {
                    entry["source"] = "preset-fallback"
                }
                entry["edrStateSDRBasis"] = telemetry.sdrNits
                entry["reportedHeadroom"] = telemetry.reportedHeadroom
                entry["availableHeadroom"] = telemetry.availableHeadroom
                entry["reportedPhysicalNits"] = telemetry.reportedPhysicalNits as Any? ?? NSNull()
            } else {
                entry["source"] = "preset-fallback"
            }
            #endif
            readings.append(entry)
        }
        #if HEADROOM_LUMINANCE_FORCE_FALLBACK
        check(CoreBrightnessLuminanceReader.attemptCount > 0, "unavailableProviderWasTried")
        #else
        let direct = CoreBrightnessLuminanceReader()
        check(direct.reading(displayID: 0) == nil, "directAdapterRejectsZeroDisplay")
        check(direct.reading(displayID: UInt32.max) == nil, "directAdapterRejectsNonexistentDisplay")
        // Repeated create/read/release checks private-client and copied-object
        // ownership without sharing a private client between execution queues.
        for _ in 0..<25 {
            autoreleasepool {
                let temporary = CoreBrightnessLuminanceReader()
                if let id = ids.first { _ = temporary.reading(displayID: id) }
            }
        }
        #endif
        for (id, baseline) in before {
            check(gamma(displayID: id) == baseline, "display\(id)GammaUnchanged")
        }
        if CommandLine.arguments.contains("--require-supported") {
            check(supported > 0, "atLeastOneSupportedDisplay")
            check(!before.isEmpty, "atLeastOneGammaBaseline")
        }
        let report: [String: Any] = ["mode": mode, "allPassed": checks.values.allSatisfy { $0 },
                                   "checkCount": checks.count, "checks": checks, "readings": readings,
                                   "displaySettingsWritten": false, "opticalMeasurement": false]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }

    private static func check(_ success: Bool, _ name: String) { checks[name] = success }

    private static func onlineDisplays() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func gamma(displayID: UInt32) -> [[Float]]? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0, capacity <= 65_536 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &count) == .success,
              count > 0, count <= capacity else { return nil }
        return [Array(r.prefix(Int(count))), Array(g.prefix(Int(count))), Array(b.prefix(Int(count)))]
    }

    #if !HEADROOM_LUMINANCE_FORCE_FALLBACK
    private static func validateParser() {
        let values: [String: Any] = ["SDR": 400.2, "Headroom": 1.2, "AvailableHeadroom": 3.998, "HDRMax": 1600.0]
        func status(_ edr: [String: Any], id: Any = NSNumber(value: 1), physical: Any? = NSNumber(value: 400.2)) -> [String: Any] {
            var display: [String: Any] = ["CBDisplayInfo": ["CBDisplayInfoDisplayID": id], "EDRState": edr]
            display["NitsPhysical"] = physical
            return ["Display": display]
        }
        func parse(_ value: [String: Any]) -> DisplayLuminanceSystemTelemetry? {
            CoreBrightnessLuminanceReader.telemetry(from: value, displayID: 1)
        }
        let parsed = parse(status(values))
        check(parsed?.sdrNits == 400.2 && parsed?.reportedHeadroom == 1.2 &&
              parsed?.availableHeadroom == 3.998 && parsed?.maximumHDRNits == 1600,
              "parserPreservesReportedValues")
        check(parse([:]) == nil, "parserRejectsMissingStatus")
        check(parse(["Display": "not a dictionary"]) == nil, "parserRejectsWrongStatusType")
        check(CoreBrightnessLuminanceReader.telemetry(from: status(values), displayID: 0) == nil,
              "parserRejectsZeroRequestedID")
        let badIDs: [Any] = [NSNumber(value: 0), NSNumber(value: 2), NSNumber(value: true),
                             NSNumber(value: 1.5), NSNumber(value: Double.nan), "1"]
        for (index, id) in badIDs.enumerated() {
            check(parse(status(values, id: id)) == nil, "parserRejectsIdentity\(index)")
        }
        let badNumbers: [Any] = [NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
                                NSNumber(value: -1), NSNumber(value: true), "400", NSNull()]
        for key in ["SDR", "Headroom", "AvailableHeadroom", "HDRMax"] {
            for (index, value) in badNumbers.enumerated() {
                var edr = values; edr[key] = value
                check(parse(status(edr)) == nil, "parserRejects\(key)Value\(index)")
            }
            var missing = values; missing.removeValue(forKey: key)
            check(parse(status(missing)) == nil, "parserRejectsMissing\(key)")
        }
        for key in ["Headroom", "AvailableHeadroom"] {
            for value in [0.0, 0.99, 1025.0] {
                var edr = values; edr[key] = value
                check(parse(status(edr)) == nil, "parserRejects\(key)OutOfRange\(value)")
            }
        }
        for (key, value) in [("SDR", 1601.0), ("HDRMax", 0.0), ("HDRMax", 10001.0)] {
            var edr = values; edr[key] = value
            check(parse(status(edr)) == nil, "parserRejects\(key)Limit\(value)")
        }
        for (index, value) in (badNumbers + [NSNumber(value: 10001)]).enumerated() {
            let optional = parse(status(values, physical: value))
            check(optional?.reportedPhysicalNits == nil && optional?.sdrNits == 400.2,
                  "parserIgnoresInvalidOptionalPhysical\(index)")
        }
        check(parse(status(values, physical: nil))?.sdrNits == 400.2,
              "parserAllowsMissingOptionalPhysical")
        var zero = values; zero["SDR"] = 0.0
        check(parse(status(zero))?.sdrNits == 0, "parserPreservesRealZeroSDR")
        var distinct = values; distinct["SDR"] = 321.0
        check(parse(status(distinct, physical: 456.0))?.reportedPhysicalNits == 456,
              "parserDoesNotConflatePhysicalAndSDR")
        check(parse(status(values, physical: 1601.0))?.reportedPhysicalNits == nil,
              "parserRejectsPhysicalAboveHDRLimit")

        let changing = parse(status(values, physical: 355.165558))!
        var fallbackCalls = 0
        let native = DisplayLuminanceReader.referenceSnapshot(systemTelemetry: changing) {
            fallbackCalls += 1
            return DisplayLuminanceReadingSnapshot(referenceNits: 123, maximumHDRNits: 1000)
        }
        check(native?.referenceNits == 355.165558 && native?.referenceNits != changing.sdrNits,
              "nativeReferenceTracksPhysicalInsteadOfFixedEDRState")
        check(fallbackCalls == 0, "validPhysicalAvoidsFallback")
        let missingPhysical = parse(status(values, physical: nil))!
        let fallback = DisplayLuminanceReader.referenceSnapshot(systemTelemetry: missingPhysical) {
            DisplayLuminanceReadingSnapshot(referenceNits: 321, maximumHDRNits: 1000)
        }
        check(fallback?.referenceNits == 321 && fallback?.maximumHDRNits == 1000,
              "missingPhysicalUsesActualPresetFallback")
        check(fallback?.systemTelemetry?.sdrNits == 400.2,
              "fallbackPreservesDistinctEDRDiagnosticBasis")
        check(DisplayLuminanceReader.referenceSnapshot(systemTelemetry: missingPhysical, fallback: { nil }) == nil,
              "missingPhysicalAndFallbackNeverInventNativeNitsFromEDRState")
        let zeroPhysical = parse(status(values, physical: 0.0))!
        check(DisplayLuminanceReader.referenceSnapshot(systemTelemetry: zeroPhysical, fallback: { nil })?.referenceNits == 0,
              "reportedPhysicalZeroIsNotMissing")
    }
    #endif
}
