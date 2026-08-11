package com.noop.widget

import com.noop.ui.NoopNotificationRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WidgetRouteTest {
    @Test
    fun widgetDestinationsAreTrustedTopLevelRoutes() {
        assertEquals(NoopNotificationRoute.TODAY, NoopNotificationRoute.fromRaw("today"))
        assertEquals(NoopNotificationRoute.TRENDS, NoopNotificationRoute.fromRaw("trends"))
        assertEquals(NoopNotificationRoute.SLEEP, NoopNotificationRoute.fromRaw("sleep"))
        assertEquals(NoopNotificationRoute.LIVE, NoopNotificationRoute.fromRaw("live"))
        assertEquals(NoopNotificationRoute.HEALTH, NoopNotificationRoute.fromRaw("health"))
        assertNull(NoopNotificationRoute.fromRaw("https://example.com"))
    }
}
