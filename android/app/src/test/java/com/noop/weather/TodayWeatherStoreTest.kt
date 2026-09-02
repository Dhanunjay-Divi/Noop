package com.noop.weather

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TodayWeatherStoreTest {
    @Test
    fun parserReadsCurrentConditionsAndPinsObservationTime() {
        val snapshot = TodayWeatherParser.parse(
            payload = """
                {
                  "current": {
                    "time": "2026-09-01T10:15",
                    "temperature_2m": 22.4,
                    "weather_code": 2
                  }
                }
            """.trimIndent(),
            observedAtMs = 1_788_270_000_000,
        )

        assertEquals(22.4, snapshot.temperatureC, 0.0001)
        assertEquals(2, snapshot.weatherCode)
        assertEquals(1_788_270_000_000, snapshot.observedAtMs)
    }

    @Test(expected = IllegalArgumentException::class)
    fun parserRejectsPhysicallyInvalidTemperature() {
        TodayWeatherParser.parse(
            """{"current":{"temperature_2m":999,"weather_code":0}}""",
            observedAtMs = 1,
        )
    }

    @Test
    fun weatherCodesCoverEveryOpenMeteoConditionFamily() {
        assertEquals(TodayWeatherCondition.CLEAR, TodayWeatherCode.condition(0))
        assertEquals(TodayWeatherCondition.PARTLY_CLOUDY, TodayWeatherCode.condition(2))
        assertEquals(TodayWeatherCondition.FOG, TodayWeatherCode.condition(48))
        assertEquals(TodayWeatherCondition.DRIZZLE, TodayWeatherCode.condition(55))
        assertEquals(TodayWeatherCondition.RAIN, TodayWeatherCode.condition(82))
        assertEquals(TodayWeatherCondition.SNOW, TodayWeatherCode.condition(86))
        assertEquals(TodayWeatherCondition.THUNDERSTORM, TodayWeatherCode.condition(99))
        assertEquals(TodayWeatherCondition.UNKNOWN, TodayWeatherCode.condition(40))
    }

    @Test
    fun requestRoundsCoordinatesAndContainsOnlyCurrentWeatherFields() {
        val url = TodayWeatherRequest.url(
            latitude = 40.712_812_345,
            longitude = -74.006_012_345,
        )

        assertEquals("40.71", url.queryParameter("latitude"))
        assertEquals("-74.01", url.queryParameter("longitude"))
        assertEquals("temperature_2m,weather_code", url.queryParameter("current"))
        assertEquals("1", url.queryParameter("forecast_days"))
        assertTrue(url.isHttps)
        assertEquals("api.open-meteo.com", url.host)
        assertFalse(url.queryParameterNames.contains("past_days"))
    }
}
