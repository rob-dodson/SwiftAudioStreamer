// main.swift is the command-line entry point. It parses CLI options, resolves playable
// URLs through HarnessSupport, and starts StreamHarness to drive either AudioStream or
// AVPlayer playback.
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
var debugLoggingEnabled = false
var volume: Float = 1.0
var playDuration: TimeInterval = 5
var printPowerLevels = false
var forceAVPlayer = false
var skipURLParsing = false
var noLoop = false
var positionalArguments: [String] = []

var argumentIndex = 0
while argumentIndex < arguments.count {
    let argument = arguments[argumentIndex]
    switch argument {
    case "--debug":
        debugLoggingEnabled = true
        argumentIndex += 1
    case "--power":
        printPowerLevels = true
        argumentIndex += 1
    case "--noloop":
        noLoop = true
        argumentIndex += 1
    case "--avplayer":
        forceAVPlayer = true
        argumentIndex += 1
    case "--noparse":
        skipURLParsing = true
        argumentIndex += 1
    case "--volume":
        let valueIndex = argumentIndex + 1
        guard valueIndex < arguments.count else {
            fputs("missing value for --volume\n", stderr)
            Darwin.exit(2)
        }
        guard let parsedVolume = Float(arguments[valueIndex]), parsedVolume >= 0, parsedVolume <= 1 else {
            fputs("\(HarnessInputError.invalidVolume(arguments[valueIndex]).localizedDescription)\n", stderr)
            Darwin.exit(2)
        }
        volume = parsedVolume
        argumentIndex += 2
    case "--help","-?":
		print(HarnessSupport.usage)
        argumentIndex += 1
    case "--play-duration":
        let valueIndex = argumentIndex + 1
        guard valueIndex < arguments.count else {
            fputs("missing value for --play-duration\n", stderr)
            Darwin.exit(2)
        }
        guard let parsedPlayDuration = TimeInterval(arguments[valueIndex]), parsedPlayDuration >= 0 else {
            fputs("\(HarnessInputError.invalidPlayDuration(arguments[valueIndex]).localizedDescription)\n", stderr)
            Darwin.exit(2)
        }
        playDuration = parsedPlayDuration
        argumentIndex += 2
    default:
        positionalArguments.append(argument)
        argumentIndex += 1
    }
}

guard !positionalArguments.isEmpty else {
    fputs("usage: swift-audio-streamer [--debug] [--power] [--avplayer] [--noparse] [--noloop] [--volume 0.0-1.0] [--play-duration seconds] <stream-url> [stream-url ...]\n", stderr)
    Darwin.exit(2)
}

Task { @MainActor in
    if debugLoggingEnabled {
        fputs("[main] starting swift-audio-streamer\n", stderr)
    }

    do {
        let urls = try await {
            if skipURLParsing {
                return try HarnessSupport.resolveInputURLs(from: positionalArguments)
            }

            return try await HarnessSupport.resolvePlayableURLs(from: positionalArguments)
        }()
        let harness = StreamHarness(debugLoggingEnabled: debugLoggingEnabled)
        harness.setVolume(volume)
        let exitCode = await harness.run(
            urls: urls,
            playDuration: playDuration,
            printPowerLevels: printPowerLevels,
            forceAVPlayer: forceAVPlayer,
			noLoop : noLoop
        )
        if debugLoggingEnabled {
            fputs("[main] exiting with code \(exitCode)\n", stderr)
        }
        Darwin.exit(exitCode)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        Darwin.exit(2)
    }
}

dispatchMain()

