import Foundation

struct RoutingProbeArguments {
    static let usage = """
    Usage:
      routing-probe --help
      routing-probe --self-test
      routing-probe --config CONFIG.json --check [--report REPORT.json]
      routing-probe --config CONFIG.json --allow-capture [--duration SECONDS] [--report REPORT.json]

    Four explicit endpoint UIDs are required in CONFIG.json (see docs/ROUTING_PROBE.md).
    --check validates configuration against live inventory without opening audio units.
    --allow-capture consents to two live input streams, kept in memory only. Both
    output routes remain muted throughout. Permission must already be granted;
    this tool never requests permission. Duration is 2–60 seconds (default 5).
    Reports contain device metadata and counters, never microphone samples.
    Exit: 0 selected check passed, 1 failed, 2 invalid arguments, 3 skipped/permission unavailable.
    A passing muted run does not establish electrical compatibility or audible routing.
    """
    let configPath: String
    let reportPath: String?
    let duration: Double
    let checkOnly: Bool

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard values[argument] == nil && !flags.contains(argument) else { throw AudioFailure("Duplicate option: \(argument)") }
            switch argument {
            case "--config", "--report", "--duration":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--"), !arguments[index].isEmpty else {
                    throw AudioFailure("Missing value for \(argument).")
                }
                values[argument] = arguments[index]
            case "--check", "--allow-capture": flags.insert(argument)
            default: throw AudioFailure("Unknown option: \(argument)")
            }
            index += 1
        }
        guard let config = values["--config"] else { throw AudioFailure("An explicit --config file is required.") }
        checkOnly = flags.contains("--check")
        guard checkOnly != flags.contains("--allow-capture") else {
            throw AudioFailure("Choose --check without capture, or explicitly consent with --allow-capture; these modes cannot be combined.")
        }
        guard !checkOnly || values["--duration"] == nil else { throw AudioFailure("--duration applies only to a capture run.") }
        guard let duration = Double(values["--duration"] ?? "5"), duration.isFinite, (2...60).contains(duration) else {
            throw AudioFailure("Duration must be a finite number from 2 to 60 seconds.")
        }
        configPath = config; reportPath = values["--report"]; self.duration = duration
    }

    func loadConfiguration() throws -> RoutingConfiguration {
        let url = URL(fileURLWithPath: configPath)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 65_536 else { throw AudioFailure("Configuration is larger than 64 KiB.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536 else { throw AudioFailure("Configuration is larger than 64 KiB.") }
        return try Self.decodeConfiguration(data)
    }

    static func decodeConfiguration(_ data: Data) throws -> RoutingConfiguration {
        let config = try JSONDecoder().decode(ConfigurationPayload.self, from: data).configuration
        guard config.selectedUIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1024 }),
              (0...31).contains(config.micChannel), (0...31).contains(config.xboxFirstChannel),
              !config.xboxStereo || config.xboxFirstChannel < 31,
              [0, 32, 64, 128, 256, 512].contains(config.requestedBuffer) else {
            throw AudioFailure("Invalid endpoint UIDs, zero-based channels, or buffer (allowed: 0, 32, 64, 128, 256, 512).")
        }
        return config
    }

    private struct ConfigurationPayload: Decodable {
        let configuration: RoutingConfiguration
        private enum CodingKeys: String, CodingKey { case schemaVersion, configuration }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.schemaVersion) || container.contains(.configuration) {
                guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
                    throw AudioFailure("Unsupported readiness report schemaVersion; expected 1.")
                }
                configuration = try container.decode(RoutingConfiguration.self, forKey: .configuration)
            } else {
                configuration = try RoutingConfiguration(from: decoder)
            }
        }
    }
}
