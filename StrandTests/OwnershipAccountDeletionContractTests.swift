import CryptoKit
import Foundation
import XCTest

final class OwnershipAccountDeletionContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func block(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex
            )
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func testRequestStatusAndCancelRoutesMatchServerContract() throws {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let server = try source("server/app/ownership_api.py")
        let client = try block(
            in: apple,
            from: "private final class OwnershipAPIClient",
            to: "final class OwnershipSecureStore"
        )
        let request = try block(
            in: client,
            from: "    func requestAccountDeletion(",
            to: "    func accountDeletion("
        )
        let status = try block(
            in: client,
            from: "    func accountDeletion(",
            to: "    func cancelAccountDeletion("
        )
        let cancel = try block(
            in: client,
            from: "    func cancelAccountDeletion(",
            to: "    func selectPlan("
        )

        XCTAssertTrue(
            request.contains(
                #"path: "v1/ownership/account/deletion-requests""#
            )
        )
        XCTAssertTrue(request.contains(#"method: "POST""#))
        XCTAssertTrue(
            status.contains(
                #"path: "v1/ownership/account/deletion-requests/""#
            )
        )
        XCTAssertTrue(status.contains(#"method: "GET""#))
        XCTAssertTrue(
            cancel.contains(
                #"+ "/cancel""#
            )
        )
        XCTAssertTrue(cancel.contains(#"method: "POST""#))

        XCTAssertTrue(
            server.contains(
                """
                @router.post(
                        "/account/deletion-requests",
                """
            )
        )
        XCTAssertTrue(
            server.contains(
                #"@router.get("/account/deletion-requests/{deletion_request_id}")"#
            )
        )
        XCTAssertTrue(
            server.contains(
                #""/account/deletion-requests/{deletion_request_id}/cancel""#
            )
        )
    }

    func testStatusOmitsButCancelRestoresInstallationCredentials() throws {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let server = try source("server/app/ownership_api.py")
        let client = try block(
            in: apple,
            from: "private final class OwnershipAPIClient",
            to: "final class OwnershipSecureStore"
        )
        let status = try block(
            in: client,
            from: "    func accountDeletion(",
            to: "    func cancelAccountDeletion("
        )
        let cancel = try block(
            in: client,
            from: "    func cancelAccountDeletion(",
            to: "    func selectPlan("
        )
        let serverStatus = try block(
            in: server,
            from: "    @router.get(\"/account/deletion-requests/",
            to: "    @router.post(\n        \"/account/deletion-requests/"
        )
        let serverCancel = try block(
            in: server,
            from: "    @router.post(\n        \"/account/deletion-requests/",
            to: "    @router.put(\"/plan-selection\")"
        )

        XCTAssertTrue(status.contains("includeInstallation: false"))
        XCTAssertFalse(cancel.contains("includeInstallation: false"))
        XCTAssertTrue(
            serverStatus.contains(
                "Depends(require_account_deletion_principal)"
            )
        )
        XCTAssertFalse(serverStatus.contains("installation_id_header"))
        XCTAssertFalse(serverStatus.contains("installation_token_hash_header"))
        XCTAssertTrue(serverCancel.contains("Depends("))
        XCTAssertTrue(
            serverCancel.contains("require_account_deletion_cancellation")
        )
        XCTAssertTrue(serverCancel.contains("identity.installation_id"))
        XCTAssertTrue(
            serverCancel.contains("identity.installation_token_hash")
        )
        XCTAssertFalse(serverCancel.contains("Depends(require_identity)"))
    }

    func testTypedConfirmationAndHashAreExactAcrossAppleAndServer()
        throws
    {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let serverModels = try source("server/app/ownership_models.py")
        let serverAPI = try source("server/app/ownership_api.py")
        let typedConfirmation = "DELETE MY NOOP OWNERSHIP ACCOUNT"

        XCTAssertEqual(
            sha256(typedConfirmation),
            "906c9d4d0cae69e471be62f9a05278b0c02b5b3e7354265b633e12c37e7ae8e3"
        )
        XCTAssertTrue(
            apple.contains(
                """
                static let accountDeletionConfirmation =
                        "\(typedConfirmation)"
                """
            )
        )
        XCTAssertTrue(
            apple.contains(
                "guard confirmation == Self.accountDeletionConfirmation else"
            )
        )
        XCTAssertTrue(
            apple.contains(
                """
                confirmationSHA256: ownershipSHA256(
                                    Data(Self.accountDeletionConfirmation.utf8)
                                )
                """
            )
        )
        XCTAssertTrue(
            serverModels.contains(#"b"\#(typedConfirmation)""#)
        )
        XCTAssertTrue(
            serverModels.contains(
                "OWNERSHIP_ACCOUNT_DELETION_CONFIRMATION_SHA256 = hashlib.sha256("
            )
        )
        XCTAssertTrue(
            serverAPI.contains(
                """
                hmac.compare_digest(
                            body.confirmation_sha256,
                            OWNERSHIP_ACCOUNT_DELETION_CONFIRMATION_SHA256,
                        )
                """
            )
        )
    }

    func testDeletionRequestIDUsesDurableDeviceOnlyKeychainReference()
        throws
    {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let secureStore = try block(
            in: apple,
            from: "final class OwnershipSecureStore",
            to: "enum OwnershipClientError"
        )
        let lifecycle = try block(
            in: apple,
            from: "    func requestAccountDeletion(",
            to: "    private func loadOverview("
        )

        XCTAssertTrue(
            secureStore.contains(
                #"private let service = "com.noop.band-ownership""#
            )
        )
        XCTAssertTrue(
            secureStore.contains(
                #"account: "account-deletion-\(scope)""#
            )
        )
        XCTAssertTrue(secureStore.contains("kSecClassGenericPassword"))
        XCTAssertTrue(
            secureStore.contains(
                "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
            )
        )
        XCTAssertTrue(
            secureStore.contains(
                "Data(value.uuidString.lowercased().utf8)"
            )
        )
        XCTAssertFalse(secureStore.contains("UserDefaults"))
        let readAttempt = try XCTUnwrap(
            lifecycle.range(of: "readAccountDeletionAttemptID(")
        )
        let writeAttempt = try XCTUnwrap(
            lifecycle.range(
                of: "writeAccountDeletionAttemptID(",
                range: readAttempt.upperBound..<lifecycle.endIndex
            )
        )
        let remoteRequest = try XCTUnwrap(
            lifecycle.range(
                of: "client().requestAccountDeletion(",
                range: writeAttempt.upperBound..<lifecycle.endIndex
            )
        )
        let writeServerReference = try XCTUnwrap(
            lifecycle.range(
                of: "writeAccountDeletionRequestID(",
                range: remoteRequest.upperBound..<lifecycle.endIndex
            )
        )
        let clearAttempt = try XCTUnwrap(
            lifecycle.range(
                of: "deleteAccountDeletionAttemptID(scope: scope)",
                range: writeServerReference.upperBound..<lifecycle.endIndex
            )
        )
        XCTAssertLessThan(readAttempt.lowerBound, writeAttempt.lowerBound)
        XCTAssertLessThan(writeAttempt.lowerBound, remoteRequest.lowerBound)
        XCTAssertLessThan(remoteRequest.lowerBound, writeServerReference.lowerBound)
        XCTAssertLessThan(writeServerReference.lowerBound, clearAttempt.lowerBound)
    }

    func testDeletionUIPreservesLocalHealthDataAndDoesNotReleaseBand()
        throws
    {
        let service = try source("StrandiOS/System/OwnershipService.swift")
        let views = try source("StrandiOS/System/OwnershipViews.swift")
        let deletionUI = try block(
            in: views,
            from: "    private var accountDeletionRequest: some View",
            to: "    private var replacement: some View"
        )
        let deletionLifecycle = try block(
            in: service,
            from: "    func requestAccountDeletion(",
            to: "    private func loadOverview("
        )

        XCTAssertTrue(
            deletionUI.contains(
                "It does not delete local health data from this iPhone."
            )
        )
        XCTAssertTrue(
            deletionUI.contains(
                "A claimed band is not released, transferred, or made resellable here."
            )
        )
        XCTAssertTrue(
            deletionUI.contains(
                "This flow does not unpair or transfer it."
            )
        )
        XCTAssertTrue(
            deletionUI.contains(
                "Local health data stays on this iPhone."
            )
        )
        XCTAssertTrue(
            service.contains(
                "Local health data remains on this iPhone."
            )
        )
        XCTAssertTrue(
            service.contains(
                "local health data was not changed."
            )
        )

        for forbiddenAction in [
            "func unpairBand",
            "func releaseBand",
            "func transferBand",
            "await service.unpair",
            "await service.release",
            "await service.transfer",
        ] {
            XCTAssertFalse(service.contains(forbiddenAction), forbiddenAction)
            XCTAssertFalse(
                deletionUI.contains(forbiddenAction),
                forbiddenAction
            )
            XCTAssertFalse(
                deletionLifecycle.contains(forbiddenAction),
                forbiddenAction
            )
        }
    }

    func testDeletionResponseRequiresNullableBlockersAndConsistentStates()
        throws
    {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let server = try source("server/app/ownership_repository.py")
        let parser = try block(
            in: apple,
            from: "    private func parseAccountDeletion(",
            to: "    private static func isDeletionTimestamp("
        )
        let serverResponse = try block(
            in: server,
            from: "def _public_account_deletion(",
            to: "def _validated_terms_manifest("
        )

        for target in [
            "identity_deletion",
            "band_retirement",
            "control_plane_deletion",
        ] {
            XCTAssertTrue(
                serverResponse.contains(#""\#(target)": {"#),
                target
            )
        }
        XCTAssertGreaterThanOrEqual(
            serverResponse.components(separatedBy: #""blocker":"#).count - 1,
            3
        )

        XCTAssertEqual(
            parser.components(
                separatedBy: "try Self.requiredNullableDeletionToken("
            ).count - 1,
            3
        )
        for blocker in [
            "let identityBlocker = try Self.requiredNullableDeletionToken(",
            "let bandBlocker = try Self.requiredNullableDeletionToken(",
            "let controlBlocker = try Self.requiredNullableDeletionToken(",
        ] {
            XCTAssertTrue(
                parser.contains(blocker),
                "\(blocker) must reject a missing or malformed blocker key"
            )
        }
        XCTAssertTrue(
            parser.contains(
                "private static func requiredNullableDeletionToken("
            )
        )
        XCTAssertTrue(
            parser.contains("guard object.keys.contains(key) else")
        )
        XCTAssertTrue(parser.contains("throw OwnershipClientError.invalidResponse"))
        XCTAssertTrue(
            parser.contains(
                "private static func deletionBlockerIsConsistent("
            )
        )
        XCTAssertEqual(
            parser.components(
                separatedBy: "Self.deletionBlockerIsConsistent("
            ).count - 1,
            3
        )
        XCTAssertTrue(
            parser.contains(
                #"(state == "blocked") == (blocker != nil)"#
            )
        )
        XCTAssertFalse(
            parser.contains(
                "Self.optionalDeletionToken(identity[\"blocker\"])"
            )
        )
        XCTAssertFalse(
            parser.contains(
                "Self.optionalDeletionToken(band[\"blocker\"])"
            )
        )
        XCTAssertFalse(
            parser.contains(
                "Self.optionalDeletionToken(control[\"blocker\"])"
            )
        )
    }

    func testDeletionDiagnosticsStayCategoricalAndIdentifierFree()
        throws
    {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let server = try source("server/app/ownership_api.py")
        let lifecycle = try block(
            in: apple,
            from: "    func requestAccountDeletion(",
            to: "    private func loadOverview("
        )
        let parser = try block(
            in: apple,
            from: "    private func parseAccountDeletion(",
            to: "    private static func isDeletionTimestamp("
        )
        let serverRoutes = try block(
            in: server,
            from: "    @router.post(\n        \"/account/deletion-requests\"",
            to: "    @router.put(\"/plan-selection\")"
        )

        for operation in [
            "ownership.account_deletion.request",
            "ownership.account_deletion.refresh",
            "ownership.account_deletion.cancel",
        ] {
            XCTAssertTrue(lifecycle.contains(#""\#(operation)""#))
        }
        for field in [
            #""failure_kind""#,
            #""deletion_state""#,
            #""band_retirement""#,
        ] {
            XCTAssertTrue(lifecycle.contains(field), field)
        }
        for forbiddenField in [
            #""account_id""#,
            #""deletion_request_id""#,
            #""email""#,
            #""installation_id""#,
            #""password""#,
            #""confirmation_sha256""#,
            #""raw_error""#,
        ] {
            XCTAssertFalse(lifecycle.contains(forbiddenField), forbiddenField)
            XCTAssertFalse(serverRoutes.contains(forbiddenField), forbiddenField)
        }

        for allowedState in [
            "cooling_off",
            "scheduled",
            "blocked",
            "canceled",
            "not_required",
            "processing",
            "completed",
            "failed",
        ] {
            XCTAssertTrue(parser.contains(#""\#(allowedState)""#))
        }
        XCTAssertTrue(
            serverRoutes.contains(
                #"phase="account_deletion""#
            )
        )
        for outcome in [
            "accepted",
            "resumed",
            "policy_changed",
            "conflict",
            "rejected",
            "cancel_rejected",
            "canceled",
        ] {
            XCTAssertTrue(serverRoutes.contains(#""\#(outcome)""#), outcome)
        }
    }

    func testCancellationAlwaysSignsOutAfterBestEffortReferenceCleanup()
        throws
    {
        let apple = try source("StrandiOS/System/OwnershipService.swift")
        let directCancel = try block(
            in: apple,
            from: "    func cancelAccountDeletion(password: String) async",
            to: "    private func loadOverview("
        )
        let applyDeletion = try block(
            in: apple,
            from: "    private func applyAccountDeletion(",
            to: "    private func reconcileRemote(user: User)"
        )

        let serverCancel = try XCTUnwrap(
            directCancel.range(of: "client().cancelAccountDeletion(")
        )
        let cleanup = try XCTUnwrap(
            directCancel.range(
                of: "applyAccountDeletion(",
                range: serverCancel.upperBound..<directCancel.endIndex
            )
        )
        let diagnostics = try XCTUnwrap(
            directCancel.range(
                of: #""cleanup_outcome": cleanupOutcome"#,
                range: cleanup.upperBound..<directCancel.endIndex
            )
        )

        XCTAssertLessThan(serverCancel.lowerBound, cleanup.lowerBound)
        XCTAssertLessThan(cleanup.lowerBound, diagnostics.lowerBound)
        XCTAssertFalse(
            directCancel.contains("deleteAccountDeletionRequestID")
        )

        let requestCleanup = try XCTUnwrap(
            applyDeletion.range(
                of: "secureStore.deleteAccountDeletionRequestID(scope: scope)"
            )
        )
        let attemptCleanup = try XCTUnwrap(
            applyDeletion.range(
                of: "secureStore.deleteAccountDeletionAttemptID(scope: scope)",
                range: requestCleanup.upperBound..<applyDeletion.endIndex
            )
        )
        let signOut = try XCTUnwrap(
            applyDeletion.range(
                of: "try runtime().auth.signOut()",
                range: attemptCleanup.upperBound..<applyDeletion.endIndex
            )
        )
        XCTAssertLessThan(requestCleanup.lowerBound, attemptCleanup.lowerBound)
        XCTAssertLessThan(attemptCleanup.lowerBound, signOut.lowerBound)
        XCTAssertTrue(
            applyDeletion.contains(
                "requestReferenceDeleted && attemptReferenceDeleted"
            )
        )
        XCTAssertFalse(
            applyDeletion.contains(
                "deleteAccountDeletionRequestID(scope: scope)\n"
                    + "                && secureStore"
            )
        )
        XCTAssertTrue(applyDeletion.contains("accountDeletion = nil"))
        XCTAssertTrue(applyDeletion.contains("phase = .signedOut"))
        XCTAssertTrue(
            applyDeletion.contains(
                #"return cleanupCompleted ? "completed" : "deferred""#
            )
        )
        XCTAssertFalse(
            applyDeletion.contains(
                "throw OwnershipClientError.secureStorage"
            )
        )
    }
}
