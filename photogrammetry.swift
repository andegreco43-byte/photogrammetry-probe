// photogrammetry.swift
//
// A single-file, Xcode-free equivalent of Apple's HelloPhotogrammetry sample.
// Compile with:
//
//     swiftc -O -parse-as-library -o photogrammetry photogrammetry.swift
//
// Usage:
//
//     ./photogrammetry <input-folder> <output.usdz> [--detail full]
//                      [--ordering sequential] [--sensitivity normal]
//
// <input-folder> is a CaptureSample output folder (the one containing the
// images and their depth/gravity metadata). Point at the folder, not a file.
//
// Detail levels: preview, reduced, medium, full, raw
//   preview/reduced -> fast, low poly. Use for pipeline testing.
//   full            -> recommended for volumetry.
//   raw             -> unsimplified; very large meshes.
//
// Ordering: sequential (photos taken in a continuous orbit) or unordered.
// Sensitivity: normal or high (high helps on low-texture subjects; slower).

import Foundation
import RealityKit

@main
struct Photogrammetry {

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
        exit(1)
    }

    static func parseDetail(_ s: String) -> PhotogrammetrySession.Request.Detail {
        switch s.lowercased() {
        case "preview": return .preview
        case "reduced": return .reduced
        case "medium":  return .medium
        case "full":    return .full
        case "raw":     return .raw
        default: fail("unknown detail '\(s)' (preview|reduced|medium|full|raw)")
        }
    }

    static func parseOrdering(_ s: String) -> PhotogrammetrySession.Configuration.SampleOrdering {
        switch s.lowercased() {
        case "sequential": return .sequential
        case "unordered":  return .unordered
        default: fail("unknown ordering '\(s)' (sequential|unordered)")
        }
    }

    static func parseSensitivity(_ s: String) -> PhotogrammetrySession.Configuration.FeatureSensitivity {
        switch s.lowercased() {
        case "normal": return .normal
        case "high":   return .high
        default: fail("unknown sensitivity '\(s)' (normal|high)")
        }
    }

    static func main() async {

        guard PhotogrammetrySession.isSupported else {
            fail("PhotogrammetrySession is not supported on this machine.")
        }

        // ---- argument parsing -------------------------------------------------
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("""
            usage: photogrammetry <input-folder> <output.usdz> \
            [--detail full] [--ordering sequential] [--sensitivity normal]
            """)
            exit(2)
        }

        let inputPath  = args.removeFirst()
        let outputPath = args.removeFirst()

        var detailStr      = "full"
        var orderingStr    = "sequential"
        var sensitivityStr = "normal"

        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !args.isEmpty else { fail("flag \(flag) needs a value") }
            let value = args.removeFirst()
            switch flag {
            case "--detail":      detailStr      = value
            case "--ordering":    orderingStr    = value
            case "--sensitivity": sensitivityStr = value
            default: fail("unknown flag \(flag)")
            }
        }

        let inputURL  = URL(fileURLWithPath: inputPath,  isDirectory: true)
        let outputURL = URL(fileURLWithPath: outputPath)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            fail("input folder does not exist or is not a directory: \(inputURL.path)")
        }

        // Make sure the output's parent directory exists.
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let detail = parseDetail(detailStr)

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering      = parseOrdering(orderingStr)
        config.featureSensitivity  = parseSensitivity(sensitivityStr)

        // ---- provenance log ---------------------------------------------------
        // Printed to stdout so a batch driver can capture it per-reconstruction.
        // Pin these values in your methods section.
        let started = Date()
        print("=== photogrammetry run ===")
        print("input        : \(inputURL.path)")
        print("output       : \(outputURL.path)")
        print("detail       : \(detailStr)")
        print("ordering     : \(orderingStr)")
        print("sensitivity  : \(sensitivityStr)")
        print("os           : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("host         : \(ProcessInfo.processInfo.hostName)")
        print("started      : \(ISO8601DateFormatter().string(from: started))")

        // ---- run --------------------------------------------------------------
        let session: PhotogrammetrySession
        do {
            session = try PhotogrammetrySession(input: inputURL, configuration: config)
        } catch {
            fail("could not create session: \(error)")
        }

        do {
            try session.process(requests: [ .modelFile(url: outputURL, detail: detail) ])
        } catch {
            fail("could not start processing: \(error)")
        }

        var lastPct = -1
        var invalidSamples = 0
        var skippedSamples = 0
        var didDownsample  = false

        do {
            for try await output in session.outputs {
                switch output {

                case .requestProgress(_, let fraction):
                    let pct = Int(fraction * 100)
                    if pct != lastPct && pct % 5 == 0 {
                        lastPct = pct
                        print("progress     : \(pct)%")
                        fflush(stdout)
                    }

                case .requestComplete(_, let result):
                    if case .modelFile(let url) = result {
                        print("wrote        : \(url.path)")
                    }

                case .requestError(_, let error):
                    fail("request failed: \(error)")

                case .invalidSample(let id, let reason):
                    invalidSamples += 1
                    print("invalid      : sample \(id) (\(reason))")

                case .skippedSample(let id):
                    skippedSamples += 1
                    print("skipped      : sample \(id)")

                case .automaticDownsampling:
                    didDownsample = true
                    print("WARNING      : automatic downsampling engaged")

                case .processingCancelled:
                    fail("processing was cancelled")

                case .processingComplete:
                    let elapsed = Date().timeIntervalSince(started)
                    print("invalid_total: \(invalidSamples)")
                    print("skipped_total: \(skippedSamples)")
                    print("downsampled  : \(didDownsample)")
                    print("elapsed_sec  : \(String(format: "%.1f", elapsed))")
                    print("=== complete ===")
                    exit(0)

                default:
                    break
                }
            }
        } catch {
            fail("session failed: \(error)")
        }

        fail("session ended without completing")
    }
}
