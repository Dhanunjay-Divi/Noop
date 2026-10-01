package com.noop.ui

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.AppDiagnosticsRecorder
import com.noop.BuildConfig
import com.noop.R
import java.net.URI

@Composable
internal fun BandOrderLink(
    rawOrderUrl: String = BuildConfig.BAND_ORDER_URL,
) {
    val uriHandler = LocalUriHandler.current
    val orderUrl = remember(rawOrderUrl) {
        validatedBandOrderUrl(rawOrderUrl)
    }

    TextButton(
        onClick = {
            val outcome = runCatching {
                uriHandler.openUri(checkNotNull(orderUrl))
            }.fold(
                onSuccess = { "opened" },
                onFailure = { "failed" },
            )
            AppDiagnosticsRecorder.record(
                "onboarding.band_order",
                fields = mapOf("outcome" to outcome),
            )
        },
        enabled = orderUrl != null,
        modifier = Modifier
            .heightIn(min = 44.dp)
            .testTag("noop.onboarding.order-band"),
    ) {
        Icon(
            Icons.Filled.ShoppingBag,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            stringResource(R.string.appwide_onboarding_get_one_now),
            style = NoopType.subhead,
        )
    }

    if (orderUrl == null) {
        Text(
            stringResource(R.string.appwide_onboarding_order_unavailable),
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

internal fun validatedBandOrderUrl(rawValue: String?): String? {
    val value = rawValue?.trim().orEmpty()
    if (value.isEmpty() || value.contains("\$(")) return null

    val uri = runCatching { URI(value) }.getOrNull() ?: return null
    if (
        !uri.scheme.equals("https", ignoreCase = true) ||
        uri.host.isNullOrBlank() ||
        uri.userInfo != null
    ) {
        return null
    }
    val asciiUrl = uri.toASCIIString()
    return if (uri.rawFragment == null) {
        asciiUrl
    } else {
        asciiUrl.substringBefore('#')
    }
}
