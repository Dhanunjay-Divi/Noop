package com.noop.ble.veepoo.vendor

import android.content.Context
import android.text.format.DateFormat
import com.inuker.bluetooth.library.Code
import com.inuker.bluetooth.library.Constants
import com.inuker.bluetooth.library.log.VPLocalLogger
import com.inuker.bluetooth.library.search.SearchResult
import com.inuker.bluetooth.library.search.response.SearchResponse
import com.inuker.bluetooth.library.utils.BluetoothLog
import com.noop.ble.veepoo.VeepooBridge
import com.noop.ble.veepoo.VeepooBridgeProvider
import com.noop.ble.veepoo.VeepooFailure
import com.veepoo.protocol.VPOperateManager
import com.veepoo.protocol.listener.base.IABleConnectStatusListener
import com.veepoo.protocol.listener.base.IBleWriteResponse
import com.veepoo.protocol.listener.base.IConnectResponse
import com.veepoo.protocol.listener.base.INotifyResponse
import com.veepoo.protocol.listener.data.IBatteryDataListener
import com.veepoo.protocol.listener.data.ICustomSettingDataListener
import com.veepoo.protocol.listener.data.IDeviceFuctionDataListener
import com.veepoo.protocol.listener.data.IHeartDataListener
import com.veepoo.protocol.listener.data.IPwdCheckTimeoutListener
import com.veepoo.protocol.listener.data.IPwdDataListener
import com.veepoo.protocol.listener.data.ISocialMsgDataListener
import com.veepoo.protocol.model.datas.BatteryData
import com.veepoo.protocol.model.datas.DeviceFunctionPackage1
import com.veepoo.protocol.model.datas.DeviceFunctionPackage2
import com.veepoo.protocol.model.datas.DeviceFunctionPackage3
import com.veepoo.protocol.model.datas.DeviceFunctionPackage4
import com.veepoo.protocol.model.datas.DeviceFunctionPackage5
import com.veepoo.protocol.model.datas.FunctionDeviceSupportData
import com.veepoo.protocol.model.datas.FunctionSocailMsgData
import com.veepoo.protocol.model.datas.HeartData
import com.veepoo.protocol.model.datas.PwdData
import com.veepoo.protocol.model.enums.EHeartStatus
import com.veepoo.protocol.model.enums.EPwdStatus
import com.veepoo.protocol.model.settings.CustomSettingData
import com.veepoo.protocol.util.VPLogger
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The reflected supplier provider. This class exists only in the locally enabled Full source set.
 */
class VeepooBridgeProviderImpl : VeepooBridgeProvider {
    override fun create(context: Context): VeepooBridge =
        VeepooVendorBridge(VpOperateClient(context.applicationContext))
}

internal class VpOperateClient(
    private val appContext: Context,
) : VeepooVendorClient {
    private var manager: VPOperateManager? = null

    override fun initialize() {
        BluetoothLog.setDebug(false)
        VPLogger.setDebug(false)
        VPLocalLogger.stopMonitor()
        VPOperateManager.setShowFunctionNotSupportToast(false)
        manager = VPOperateManager.getInstance().also {
            it.init(appContext)
            it.setAutoConnectBTBySdk(false)
        }
    }

    override fun startScan(callback: VeepooVendorScanCallback) {
        val operateManager = requireManager()
        if (!operateManager.isBluetoothOpened) {
            callback.onFailure(VeepooFailure.UNAVAILABLE)
            return
        }
        operateManager.startScanDevice(
            SCAN_SECONDS,
            object : SearchResponse {
                override fun onSearchStarted() = Unit

                override fun onDeviceFounded(result: SearchResult?) {
                    try {
                        val scanRecord = result?.scanRecord ?: return
                        if (!operateManager.isVPDevice(scanRecord)) return
                        val address = result.address?.takeIf(String::isNotBlank) ?: return
                        callback.onCandidate(address)
                    } catch (failure: Throwable) {
                        callback.onFailure(failure.toVeepooFailure())
                    }
                }

                override fun onSearchStopped() {
                    callback.onFinished()
                }

                override fun onSearchCanceled() {
                    callback.onFinished()
                }
            },
        )
    }

    override fun stopScan() {
        requireManager().stopScanDevice()
    }

    override fun connect(
        address: String,
        requireDeviceConfirmation: Boolean,
        callback: VeepooVendorConnectionCallback,
    ): VeepooVendorConnectionRegistration {
        val operateManager = requireManager()
        if (!operateManager.isBluetoothOpened) {
            callback.onFailure(VeepooFailure.UNAVAILABLE)
            return VeepooVendorConnectionRegistration {}
        }
        operateManager.setDeviceShowConfirm(requireDeviceConfirmation)
        val statusListener = object : IABleConnectStatusListener() {
            override fun onConnectStatusChanged(reportedAddress: String?, status: Int) {
                if (!sameVeepooAddress(address, reportedAddress)) return
                if (status == Constants.STATUS_DISCONNECTED) callback.onDisconnected()
            }
        }
        val registration = VpConnectionRegistration(
            operateManager,
            address,
            statusListener,
        )
        operateManager.registerConnectStatusListener(address, statusListener)
        try {
            operateManager.connectDevice(
                address,
                IConnectResponse { code, _, isOadModel ->
                    if (code == Code.REQUEST_SUCCESS) {
                        callback.onConnected(isOadModel)
                    } else {
                        callback.onFailure(mapVeepooCode(code))
                    }
                },
                INotifyResponse { code ->
                    if (code == Code.REQUEST_SUCCESS) {
                        callback.onNotifyReady()
                    } else {
                        callback.onFailure(mapVeepooCode(code))
                    }
                },
            )
        } catch (failure: Throwable) {
            registration.unregister()
            throw failure
        }
        return registration
    }

    override fun authenticate(
        password: CharArray,
        callback: VeepooVendorAuthenticationCallback,
    ) {
        val operateManager = requireManager()
        cancelAuthentication()
        operateManager.setPwdCheckTimeoutListener(
            object : IPwdCheckTimeoutListener {
                override fun onPwdCheckTimeout() {
                    callback.onFailure(VeepooFailure.TIMEOUT)
                }
            },
        )
        var reportedHeartCapability: Boolean? = null
        operateManager.confirmDevicePwd(
            writeResponse(callback::onFailure),
            object : IPwdDataListener {
                override fun onPwdDataChange(data: PwdData?) {
                    val value = data ?: return callback.onFailure(VeepooFailure.INTERNAL)
                    when (value.getmStatus()) {
                        EPwdStatus.CHECK_SUCCESS,
                        EPwdStatus.CHECK_AND_TIME_SUCCESS,
                        -> {
                            // The supplier documents deviceNumber as firmware
                            // product metadata, not the identifier printed on
                            // an individual band.
                            val modelCode = value.getDeviceNumber()
                            callback.onIdentity(
                                VeepooVendorIdentity(
                                    deviceNumber = modelCode,
                                    hardwareRevision = value.getDeviceTestVersion(),
                                    firmwareVersion = value.getDeviceVersion(),
                                ),
                            )
                        }
                        EPwdStatus.CHECK_FAIL ->
                            callback.onFailure(VeepooFailure.AUTHENTICATION)
                        else -> callback.onFailure(VeepooFailure.INTERNAL)
                    }
                }

                override fun onConnectionConfirmTimeout() {
                    callback.onFailure(VeepooFailure.TIMEOUT)
                }
            },
            object : IDeviceFuctionDataListener {
                override fun onFunctionSupportDataChange(data: FunctionDeviceSupportData?) {
                    data?.getHeartDetect()?.let {
                        reportedHeartCapability = it.isHaveFunction
                        callback.onHeartRateCapability(it.isHaveFunction)
                    }
                }

                override fun onDeviceFunctionPackage1Report(data: DeviceFunctionPackage1?) {
                    data?.getHeartRateDetect()?.let {
                        reportedHeartCapability = it.isHaveFunction
                        callback.onHeartRateCapability(it.isHaveFunction)
                    }
                }

                override fun onDeviceFunctionPackage2Report(data: DeviceFunctionPackage2?) = Unit
                override fun onDeviceFunctionPackage3Report(data: DeviceFunctionPackage3?) = Unit
                override fun onDeviceFunctionPackage4Report(data: DeviceFunctionPackage4?) = Unit
                override fun onDeviceFunctionPackage5Report(data: DeviceFunctionPackage5?) = Unit
            },
            object : ISocialMsgDataListener {
                override fun onSocialMsgSupportDataChange(data: FunctionSocailMsgData?) = Unit
                override fun onSocialMsgSupportDataChange2(data: FunctionSocailMsgData?) = Unit
            },
            object : ICustomSettingDataListener {
                override fun OnSettingDataChange(data: CustomSettingData?) {
                    val capability = try {
                        operateManager.getFunctionCheck().checkRate()
                    } catch (failure: Throwable) {
                        reportedHeartCapability
                            ?: return callback.onFailure(failure.toVeepooFailure())
                    }
                    callback.onHeartRateCapability(capability)
                    callback.onComplete()
                }
            },
            password.concatToString(),
            DateFormat.is24HourFormat(appContext),
        )
    }

    override fun cancelAuthentication() {
        manager?.removePwdCheckTimeoutListener()
        manager?.removeConnectionConfirmationTask()
    }

    override fun readBattery(callback: VeepooVendorBatteryCallback) {
        requireManager().readBattery(
            writeResponse(callback::onFailure),
            object : IBatteryDataListener {
                override fun onDataChange(data: BatteryData?) {
                    when (val result = decodeVeepooBattery(data)) {
                        is VeepooBatteryResult.Reading -> callback.onReading(result.percent)
                        is VeepooBatteryResult.Failure -> callback.onFailure(result.failure)
                    }
                }
            },
        )
    }

    override fun startLiveHeartRate(callback: VeepooVendorHeartRateCallback) {
        val operateManager = requireManager()
        if (!operateManager.getFunctionCheck().checkRate()) {
            callback.onFailure(VeepooFailure.UNSUPPORTED)
            return
        }
        operateManager.startDetectHeart(
            writeResponse(callback::onFailure),
            object : IHeartDataListener {
                override fun onDataChange(data: HeartData?) {
                    when (val result = decodeVeepooHeartRate(data)) {
                        VeepooHeartRateResult.Pending -> Unit
                        is VeepooHeartRateResult.Reading ->
                            callback.onReading(result.beatsPerMinute)
                        is VeepooHeartRateResult.Failure ->
                            callback.onFailure(result.failure)
                    }
                }
            },
        )
    }

    override fun stopLiveHeartRate() {
        requireManager().stopDetectHeart(IBleWriteResponse { })
    }

    override fun disconnect() {
        requireManager().disconnectWatch(IBleWriteResponse { })
    }

    override fun close() {
        val operateManager = manager
        manager = null
        if (operateManager != null) {
            runCatching { operateManager.removePwdCheckTimeoutListener() }
            runCatching { operateManager.removeConnectionConfirmationTask() }
            runCatching { operateManager.release() }
        }
        runCatching { VPLocalLogger.stopMonitor() }
    }

    private fun requireManager(): VPOperateManager =
        checkNotNull(manager) { "Veepoo client is not initialized" }

    private fun writeResponse(
        onFailure: (VeepooFailure) -> Unit,
    ): IBleWriteResponse = IBleWriteResponse { code ->
        if (code != Code.REQUEST_SUCCESS) onFailure(mapVeepooCode(code))
    }

    companion object {
        private const val SCAN_SECONDS = 8
    }
}

private class VpConnectionRegistration(
    private val manager: VPOperateManager,
    private val address: String,
    private val listener: IABleConnectStatusListener,
) : VeepooVendorConnectionRegistration {
    private val registered = AtomicBoolean(true)

    override fun unregister() {
        if (registered.compareAndSet(true, false)) {
            manager.unregisterConnectStatusListener(address, listener)
        }
    }
}

internal fun mapVeepooCode(code: Int): VeepooFailure = when (code) {
    Code.BLE_NOT_SUPPORTED -> VeepooFailure.UNSUPPORTED
    Code.BLUETOOTH_DISABLED,
    Code.SERVICE_UNREADY,
    -> VeepooFailure.UNAVAILABLE
    Code.REQUEST_TIMEDOUT -> VeepooFailure.TIMEOUT
    Code.REQUEST_CANCELED,
    Code.ILLEGAL_ARGUMENT,
    Code.REQUEST_DENIED,
    -> VeepooFailure.REJECTED
    else -> VeepooFailure.INTERNAL
}

internal fun sameVeepooAddress(expected: String, reported: String?): Boolean =
    reported == null || reported.equals(expected, ignoreCase = true)

internal sealed interface VeepooBatteryResult {
    data class Reading(val percent: Int) : VeepooBatteryResult
    data class Failure(val failure: VeepooFailure) : VeepooBatteryResult
}

internal fun decodeVeepooBattery(data: BatteryData?): VeepooBatteryResult {
    val value = data ?: return VeepooBatteryResult.Failure(VeepooFailure.INTERNAL)
    val percent = if (value.isPercent) {
        value.batteryPercent
    } else {
        value.batteryLevel * 25
    }
    return if (percent in 0..100) {
        VeepooBatteryResult.Reading(percent)
    } else {
        VeepooBatteryResult.Failure(VeepooFailure.REJECTED)
    }
}

internal sealed interface VeepooHeartRateResult {
    data object Pending : VeepooHeartRateResult
    data class Reading(val beatsPerMinute: Int) : VeepooHeartRateResult
    data class Failure(val failure: VeepooFailure) : VeepooHeartRateResult
}

internal fun decodeVeepooHeartRate(data: HeartData?): VeepooHeartRateResult {
    val value = data ?: return VeepooHeartRateResult.Failure(VeepooFailure.INTERNAL)
    return when (value.heartStatus) {
        EHeartStatus.STATE_INIT,
        EHeartStatus.STATE_HEART_BUSY,
        EHeartStatus.STATE_HEART_DETECT,
        EHeartStatus.STATE_HEART_WEAR_ERROR,
        EHeartStatus.STATE_LOW_BATTERY,
        -> VeepooHeartRateResult.Pending
        EHeartStatus.STATE_HEART_NORMAL -> {
            if (value.data in 20..300) {
                VeepooHeartRateResult.Reading(value.data)
            } else {
                VeepooHeartRateResult.Failure(VeepooFailure.REJECTED)
            }
        }
        null -> VeepooHeartRateResult.Failure(VeepooFailure.INTERNAL)
    }
}
