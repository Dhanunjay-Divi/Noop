import Darwin
import Foundation
import NoopStudyCore

private struct Arguments {
    let command: String
    let values: [String: String]
    let switches: Set<String>

    init(_ raw: [String]) throws {
        guard let first = raw.first else { throw StudyError.badArguments(Self.usage) }
        command = first
        var values: [String: String] = [:]
        var switches = Set<String>()
        var index = 1
        while index < raw.count {
            let key = raw[index]
            guard key.hasPrefix("--") else {
                throw StudyError.badArguments("Unexpected argument '\(key)'.\n\n\(Self.usage)")
            }
            if key == "--acknowledge-holdout-reveal" {
                switches.insert(key)
                index += 1
                continue
            }
            guard index + 1 < raw.count else {
                throw StudyError.badArguments("Missing value for \(key).\n\n\(Self.usage)")
            }
            values[key] = raw[index + 1]
            index += 2
        }
        self.values = values
        self.switches = switches
    }

    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw StudyError.badArguments("Missing \(key).\n\n\(Self.usage)")
        }
        return value
    }

    static let usage = """
    NOOP private reference-study harness

      noop-study lock \
        --manifest manifests/study.json \
        --output locks/split-v1.lock.json

      noop-study audit \
        --manifest manifests/study.json \
        --lock locks/split-v1.lock.json \
        --output reports/audit.json

      noop-study fit \
        --manifest manifests/study.json \
        --lock locks/split-v1.lock.json \
        --candidate-id candidate-v1 \
        --output candidates/candidate-v1.json

      noop-study discover \
        --manifest manifests/study.json \
        --lock locks/split-v1.lock.json \
        --output reports/discovery.json \
        [--candidate candidates/candidate-v1.json] \
        [--audit-output audit/discovery.private.json]

      noop-study validate \
        --manifest manifests/study.json \
        --lock locks/split-v1.lock.json \
        --candidate candidates/candidate-v1.json \
        --reveal-lock locks/validation-reveal-v1.lock.json \
        --output reports/validation.json \
        [--audit-output audit/validation.private.json] \
        --acknowledge-holdout-reveal

    All manifest/lock/report paths are relative to --private-root. The default is:
      ~/Library/Application Support/NOOP-Private/whoop-study

    Optional:
      --private-root /absolute/encrypted/private/root
      --lock-key /absolute/path/outside/the/study/root
    """
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let privateRoot = arguments.values["--private-root"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? StudyPaths.defaultPrivateRoot
    let keyURL = arguments.values["--lock-key"]
        .map { URL(fileURLWithPath: $0, isDirectory: false) }
        ?? StudyPaths.defaultLockKey(for: privateRoot)
    try StudyPaths.ensurePrivateDirectory(privateRoot)

    let manifestRelative = try arguments.required("--manifest")
    let manifestURL = try StudyPaths.resolveInput(manifestRelative, under: privateRoot)
    let manifest = try StudyManifestIO.load(from: manifestURL)

    switch arguments.command {
    case "lock":
        let outputURL = try StudyPaths.resolveOutput(
            try arguments.required("--output"),
            under: privateRoot
        )
        let lock = try StudySplitLocker.create(
            manifest: manifest,
            privateRoot: privateRoot,
            keyURL: keyURL
        )
        try StudySplitLocker.write(lock, to: outputURL)
        print("Signed participant split created in the private study vault.")

    case "audit":
        let lock = try StudySplitLocker.loadLock(
            from: StudyPaths.resolveInput(
                try arguments.required("--lock"),
                under: privateRoot
            )
        )
        let report = try StudyRunner.audit(
            manifest: manifest,
            lock: lock,
            privateRoot: privateRoot,
            keyURL: keyURL
        )
        let outputURL = try StudyPaths.resolveOutput(
            try arguments.required("--output"),
            under: privateRoot
        )
        try StudySplitLocker.write(report, to: outputURL)
        print("Aggregate schema audit written in the private study vault.")

    case "fit":
        let lock = try StudySplitLocker.loadLock(
            from: StudyPaths.resolveInput(
                try arguments.required("--lock"),
                under: privateRoot
            )
        )
        let candidate = try StudyRunner.fitCandidate(
            manifest: manifest,
            lock: lock,
            privateRoot: privateRoot,
            keyURL: keyURL,
            candidateID: try arguments.required("--candidate-id")
        )
        let outputURL = try StudyPaths.resolveOutput(
            try arguments.required("--output"),
            under: privateRoot
        )
        try StudySplitLocker.write(candidate, to: outputURL)
        print("Signed discovery-only candidate written in the private study vault.")

    case "discover", "validate":
        let isValidation = arguments.command == "validate"
        let lock = try StudySplitLocker.loadLock(
            from: StudyPaths.resolveInput(
                try arguments.required("--lock"),
                under: privateRoot
            )
        )
        let candidate: StudyCandidate?
        if let relative = arguments.values["--candidate"] {
            candidate = try StudyCandidateLocker.load(
                from: StudyPaths.resolveInput(relative, under: privateRoot)
            )
        } else {
            candidate = nil
        }
        let validationRevealURL: URL?
        if isValidation {
            validationRevealURL = try StudyPaths.resolveOutput(
                try arguments.required("--reveal-lock"),
                under: privateRoot
            )
        } else {
            validationRevealURL = nil
        }
        let artifacts = try StudyRunner.compare(
            manifest: manifest,
            lock: lock,
            cohort: isValidation ? .validation : .discovery,
            privateRoot: privateRoot,
            keyURL: keyURL,
            candidate: candidate,
            acknowledgeHoldoutReveal: arguments.switches.contains(
                "--acknowledge-holdout-reveal"
            ),
            validationRevealURL: validationRevealURL
        )
        let outputRelative = try arguments.required("--output")
        let outputURL = try StudyPaths.resolveOutput(outputRelative, under: privateRoot)
        try StudySplitLocker.write(artifacts.report, to: outputURL)

        let privateAuditRelative = arguments.values["--audit-output"]
            ?? outputRelative + ".private-audit.json"
        let privateAuditURL = try StudyPaths.resolveOutput(
            privateAuditRelative,
            under: privateRoot
        )
        try StudySplitLocker.write(artifacts.privateAudit, to: privateAuditURL)
        print("Aggregate comparison and private reproducibility receipt written in the study vault.")

    default:
        throw StudyError.badArguments(Arguments.usage)
    }
} catch {
    fputs("noop-study: \(error.localizedDescription)\n", stderr)
    exit(2)
}
