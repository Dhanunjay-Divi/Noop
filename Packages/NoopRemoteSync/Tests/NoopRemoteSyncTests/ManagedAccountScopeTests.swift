import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedAccountScopeTests: XCTestCase {
    func testV2ScopeSeparatesProjectTenantAndUID() throws {
        let base = try ManagedAccountScope.identity(
            projectID: "noop-india",
            tenantID: nil,
            uid: "shared-user"
        )
        XCTAssertNotEqual(
            base,
            try ManagedAccountScope.identity(
                projectID: "noop-us",
                tenantID: nil,
                uid: "shared-user"
            )
        )
        XCTAssertNotEqual(
            base,
            try ManagedAccountScope.identity(
                projectID: "noop-india",
                tenantID: "premium",
                uid: "shared-user"
            )
        )
        XCTAssertNotEqual(
            base,
            try ManagedAccountScope.identity(
                projectID: "noop-india",
                tenantID: nil,
                uid: "another-user"
            )
        )
    }

    func testExistingV1EnrollmentKeepsItsDataNamespace() throws {
        let uid = "legacy-user"
        let legacy = try ManagedAccountScope.legacy(uid: uid)
        let binding = try ManagedAccountScope.resolve(
            projectID: "noop-india",
            tenantID: nil,
            uid: uid,
            enrolledDataScopeHash: legacy,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil
        )

        XCTAssertEqual(binding.dataScopeHash, legacy)
        XCTAssertEqual(binding.dataScopeVersion, 1)
        XCTAssertTrue(binding.requiresPersistence)

        let repeated = try ManagedAccountScope.resolve(
            projectID: "noop-india",
            tenantID: nil,
            uid: uid,
            enrolledDataScopeHash: legacy,
            persistedIdentityScopeHash: binding.identityScopeHash,
            persistedDataScopeVersion: binding.dataScopeVersion
        )
        XCTAssertEqual(repeated.dataScopeHash, legacy)
        XCTAssertFalse(repeated.requiresPersistence)
    }

    func testNewEnrollmentUsesV2OnlyAfterCallerPersistsIt() throws {
        let binding = try ManagedAccountScope.resolve(
            projectID: "noop-india",
            tenantID: nil,
            uid: "new-user",
            enrolledDataScopeHash: nil,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil
        )

        XCTAssertEqual(binding.dataScopeHash, binding.identityScopeHash)
        XCTAssertEqual(binding.dataScopeVersion, 2)
        XCTAssertTrue(binding.requiresPersistence)
    }

    func testV1EnrollDisconnectAndSameUserReenrollRecoversDataScope()
        throws
    {
        let suite = "ManagedAccountScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ManagedAccountScopeRecoveryStore(
            defaults: defaults,
            key: "account-scope-recovery"
        )
        let projectID = "noop-india"
        let tenantID = "consumer"
        let uid = "legacy-user"
        let legacyScope = try ManagedAccountScope.legacy(uid: uid)

        let enrolled = try ManagedAccountScope.resolve(
            projectID: projectID,
            tenantID: tenantID,
            uid: uid,
            enrolledDataScopeHash: legacyScope,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil
        )
        XCTAssertEqual(enrolled.dataScopeVersion, 1)
        XCTAssertTrue(try store.preserve(enrolled))

        // Ordinary disconnect clears active enrollment fields, not this mapping.
        let recovered = try ManagedAccountScope.resolve(
            projectID: projectID,
            tenantID: tenantID,
            uid: uid,
            enrolledDataScopeHash: nil,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil,
            recoveryMapping: try store.load()
        )
        XCTAssertEqual(recovered.dataScopeHash, legacyScope)
        XCTAssertEqual(recovered.dataScopeVersion, 1)
        XCTAssertFalse(recovered.requiresPersistence)

        let reenrolled = try ManagedAccountScope.resolve(
            projectID: projectID,
            tenantID: tenantID,
            uid: uid,
            enrolledDataScopeHash: recovered.dataScopeHash,
            persistedIdentityScopeHash: recovered.identityScopeHash,
            persistedDataScopeVersion: recovered.dataScopeVersion,
            recoveryMapping: try store.load()
        )
        XCTAssertEqual(reenrolled.dataScopeHash, legacyScope)
        XCTAssertEqual(reenrolled, recovered)
        XCTAssertFalse(try store.preserve(reenrolled))
    }

    func testRecoveryMappingRejectsForeignUserProjectAndTenant() throws {
        let suite = "ManagedAccountScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ManagedAccountScopeRecoveryStore(
            defaults: defaults,
            key: "account-scope-recovery"
        )
        let binding = try ManagedAccountScope.resolve(
            projectID: "noop-india",
            tenantID: "consumer",
            uid: "legacy-user",
            enrolledDataScopeHash: try ManagedAccountScope.legacy(
                uid: "legacy-user"
            ),
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil
        )
        try store.preserve(binding)
        let mapping = try XCTUnwrap(store.load())

        for identity in [
            (projectID: "noop-india", tenantID: "consumer", uid: "other-user"),
            (projectID: "noop-us", tenantID: "consumer", uid: "legacy-user"),
            (projectID: "noop-india", tenantID: "enterprise", uid: "legacy-user"),
        ] {
            XCTAssertThrowsError(
                try ManagedAccountScope.resolve(
                    projectID: identity.projectID,
                    tenantID: identity.tenantID,
                    uid: identity.uid,
                    enrolledDataScopeHash: nil,
                    persistedIdentityScopeHash: nil,
                    persistedDataScopeVersion: nil,
                    recoveryMapping: mapping
                )
            ) {
                XCTAssertEqual(
                    $0 as? ManagedAccountScopeError,
                    .identityMismatch
                )
            }
        }
    }

    func testConfirmedDeletionRemovesRecoveryMapping() throws {
        let suite = "ManagedAccountScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ManagedAccountScopeRecoveryStore(
            defaults: defaults,
            key: "account-scope-recovery"
        )
        let uid = "legacy-user"
        let legacyScope = try ManagedAccountScope.legacy(uid: uid)
        let binding = try ManagedAccountScope.resolve(
            projectID: "noop-india",
            tenantID: nil,
            uid: uid,
            enrolledDataScopeHash: legacyScope,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil
        )
        try store.preserve(binding)

        store.remove()

        XCTAssertNil(try store.load())
        let fresh = try ManagedAccountScope.resolve(
            projectID: "noop-india",
            tenantID: nil,
            uid: uid,
            enrolledDataScopeHash: nil,
            persistedIdentityScopeHash: nil,
            persistedDataScopeVersion: nil,
            recoveryMapping: try store.load()
        )
        XCTAssertEqual(fresh.dataScopeVersion, 2)
        XCTAssertNotEqual(fresh.dataScopeHash, legacyScope)
    }

    func testForeignOrPartialBindingFailsClosed() throws {
        let v2 = try ManagedAccountScope.identity(
            projectID: "noop-india",
            tenantID: nil,
            uid: "user"
        )
        XCTAssertThrowsError(
            try ManagedAccountScope.resolve(
                projectID: "noop-us",
                tenantID: nil,
                uid: "user",
                enrolledDataScopeHash: v2,
                persistedIdentityScopeHash: v2,
                persistedDataScopeVersion: 2
            )
        ) {
            XCTAssertEqual(
                $0 as? ManagedAccountScopeError,
                .identityMismatch
            )
        }
        XCTAssertThrowsError(
            try ManagedAccountScope.resolve(
                projectID: "noop-india",
                tenantID: nil,
                uid: "user",
                enrolledDataScopeHash: v2,
                persistedIdentityScopeHash: nil,
                persistedDataScopeVersion: 2
            )
        ) {
            XCTAssertEqual(
                $0 as? ManagedAccountScopeError,
                .invalidPersistedBinding
            )
        }
    }
}
