package com.noop.social

import com.noop.sync.RemoteNamespaceCatalog
import com.noop.sync.RemoteSyncException
import java.time.LocalDate
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class FriendsContractTest {
    @Test
    fun automaticRefreshThrottleDoesNotSuppressDueOrRetryWork() {
        val now = 10_000_000L
        assertTrue(FriendsAutomaticRefreshPolicy.isDue(0L, now))
        assertFalse(
            FriendsAutomaticRefreshPolicy.isDue(
                now - FriendsAutomaticRefreshPolicy.INTERVAL_MS + 1L,
                now,
            ),
        )
        assertTrue(
            FriendsAutomaticRefreshPolicy.isDue(
                now - FriendsAutomaticRefreshPolicy.INTERVAL_MS,
                now,
            ),
        )
        assertTrue(
            FriendsRetryPolicy.isRetryableSummaryFailure(
                RemoteSyncException.Network("offline"),
            ),
        )
        assertTrue(
            FriendsRetryPolicy.isRetryableSummaryFailure(
                RemoteSyncException.Server(503, "unavailable"),
            ),
        )
        assertFalse(
            FriendsRetryPolicy.isRetryableSummaryFailure(
                RemoteSyncException.Server(422, "invalid"),
            ),
        )
        assertFalse(
            FriendsRetryPolicy.isRetryableSummaryFailure(
                RemoteSyncException.InvalidResponse("invalid"),
            ),
        )
    }

    @Test
    fun bootstrapAndInviteResponsesRequireStableIdentifiers() {
        val bootstrap = FriendsJson.bootstrap(
            JSONObject(
                """
                {
                  "profile": {
                    "profile_id": "11111111-1111-4111-8111-111111111111",
                    "enrollment_id": "22222222-2222-4222-8222-222222222222",
                    "display_name": "Alex",
                    "installation_id": "install-a",
                    "daily_device_id": "android:install-a:friends"
                  },
                  "member_token": "noop_member_secret"
                }
                """.trimIndent(),
            ),
        )
        assertEquals("Alex", bootstrap.profile.displayName)
        assertEquals("noop_member_secret", bootstrap.memberToken)

        val invite = FriendsJson.invite(
            JSONObject(
                """
                {
                  "invite": {
                    "invite_id": "33333333-3333-4333-8333-333333333333",
                    "expires_at": "2026-08-25T12:00:00Z"
                  },
                  "code": "NOOP-ABCD-EFGH"
                }
                """.trimIndent(),
            ),
            "https://noop.example/base",
        )
        assertEquals("NOOP-ABCD-EFGH", invite.code)
        assertEquals("https://noop.example/base", invite.serverAddress)

        assertThrows(FriendsException.InvalidResponse::class.java) {
            FriendsJson.bootstrap(
                JSONObject(
                    """
                    {
                      "profile": {
                        "profile_id": "not-a-uuid",
                        "enrollment_id": "22222222-2222-4222-8222-222222222222",
                        "display_name": "Alex",
                        "installation_id": "install-a",
                        "daily_device_id": "daily"
                      },
                      "member_token": "token"
                    }
                    """.trimIndent(),
                ),
            )
        }
    }

    @Test
    fun friendsRequestsAndFeedDecodeDirectionalPrivacy() {
        val friends = FriendsJson.friends(
            JSONObject(
                """
                {
                  "friends": [{
                    "profile_id": "11111111-1111-4111-8111-111111111111",
                    "display_name": "Maya",
                    "friends_since": "2026-08-20T12:00:00Z",
                    "sharing": {
                      "charge": true,
                      "effort": false,
                      "rest": true,
                      "sleep_duration": false,
                      "hrv": true,
                      "rhr": false
                    },
                    "shared_with_me": {
                      "charge": false,
                      "effort": true,
                      "rest": true,
                      "sleep_duration": true,
                      "hrv": false,
                      "rhr": true
                    }
                  }]
                }
                """.trimIndent(),
            ),
        )
        assertTrue(friends.single().sharing.hrv)
        assertFalse(friends.single().sharedWithMe.hrv)
        assertTrue(friends.single().sharedWithMe.sleepDuration)

        val requests = FriendsJson.requests(
            JSONObject(
                """
                {
                  "requests": [
                    {
                      "request_id": "22222222-2222-4222-8222-222222222222",
                      "status": "pending",
                      "direction": "incoming",
                      "created_at": "2026-08-22T12:00:00Z",
                      "profile": {"display_name": "Sam"}
                    },
                    {
                      "request_id": "33333333-3333-4333-8333-333333333333",
                      "status": "accepted",
                      "direction": "outgoing",
                      "created_at": "2026-08-21T12:00:00Z",
                      "profile": {"display_name": "Ignored"}
                    }
                  ]
                }
                """.trimIndent(),
            ),
        )
        assertEquals(1, requests.size)
        assertEquals(FriendRequest.Direction.INCOMING, requests.single().direction)

        val latest = FriendsJson.feed(
            JSONObject(
                """
                {
                  "days": [
                    {
                      "profile_id": "11111111-1111-4111-8111-111111111111",
                      "day": "2026-08-20",
                      "summary": {"charge": 71, "hrv": null}
                    },
                    {
                      "profile_id": "11111111-1111-4111-8111-111111111111",
                      "day": "2026-08-22",
                      "summary": {"charge": 84, "effort": 57, "rest": 91}
                    }
                  ]
                }
                """.trimIndent(),
            ),
        ).getValue("11111111-1111-4111-8111-111111111111")
        assertEquals("2026-08-22", latest.day)
        assertEquals(84.0, latest.charge!!, 0.0)
        assertNull(latest.hrv)
    }

    @Test
    fun inviteNormalizationIsReadableButStrict() {
        assertEquals(
            "NOOPABCDEFGH",
            FriendsService.normalizeInviteCode(" noop-abcd-efgh "),
        )
        assertThrows(FriendsException.InvalidInput::class.java) {
            FriendsService.normalizeInviteCode("short")
        }
        assertThrows(FriendsException.InvalidInput::class.java) {
            FriendsService.normalizeInviteCode("NOOP-ABCD-EFGH-IJKL-MNOP-QRST-UVWX-TOO-LONG")
        }
    }

    @Test
    fun privacyUnionIncludesOnlyFieldsNeededByAtLeastOneFriend() {
        val union = FriendsService.sharedFieldUnion(
            listOf(
                contact("A", FriendVisibility(charge = true, effort = false, rest = false)),
                contact(
                    "B",
                    FriendVisibility(
                        charge = false,
                        effort = true,
                        rest = false,
                        sleepDuration = true,
                        hrv = false,
                        rhr = true,
                    ),
                ),
            ),
        )
        assertTrue(union.charge)
        assertTrue(union.effort)
        assertFalse(union.rest)
        assertTrue(union.sleepDuration)
        assertFalse(union.hrv)
        assertTrue(union.rhr)
        assertEquals(FriendVisibility(false, false, false, false, false, false), FriendsService.sharedFieldUnion(emptyList()))
    }

    @Test
    fun replacementWindowKeepsEmptyDaysAsPrivacyTombstones() {
        val payload = FriendsSummaryProjection.replacement(
            LocalDate.parse("2026-08-20"),
            LocalDate.parse("2026-08-22"),
        )
        assertEquals(listOf("2026-08-20", "2026-08-21", "2026-08-22"), payload.keys.toList())
        assertTrue(payload.values.all(Map<*, *>::isEmpty))

        FriendsSummaryProjection.add(payload, "2026-08-21", "recovery", 82.0, 0.0..100.0)
        FriendsSummaryProjection.add(payload, "2026-08-21", "recovery", 10.0, 0.0..100.0)
        FriendsSummaryProjection.add(payload, "2026-08-22", "avg_hrv", 900.0, 0.0..500.0)
        FriendsSummaryProjection.add(payload, "2026-08-23", "recovery", 70.0, 0.0..100.0)

        assertEquals(mapOf("recovery" to 82.0), payload.getValue("2026-08-21"))
        assertTrue(payload.getValue("2026-08-22").isEmpty())
        assertFalse(payload.containsKey("2026-08-23"))
    }

    @Test
    fun socialProducerIdsAreInstallationAndPurposeScoped() {
        val first = RemoteNamespaceCatalog.scopedRemoteId(
            "install-a",
            "whoop-noop-friends-v1",
        )
        val otherInstallation = RemoteNamespaceCatalog.scopedRemoteId(
            "install-b",
            "whoop-noop-friends-v1",
        )
        val fullBackup = RemoteNamespaceCatalog.scopedRemoteId(
            "install-a",
            "whoop-noop",
        )

        assertEquals("android:install-a:whoop-noop-friends-v1", first)
        assertNotEquals(first, otherInstallation)
        assertNotEquals(first, fullBackup)
    }

    private fun contact(name: String, sharing: FriendVisibility) = FriendContact(
        profileId = "11111111-1111-4111-8111-${name.padEnd(12, '1').take(12)}",
        displayName = name,
        friendsSince = "2026-08-20T12:00:00Z",
        sharing = sharing,
        sharedWithMe = FriendVisibility(),
    )
}
