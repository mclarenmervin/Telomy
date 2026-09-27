package com.telomy.telomy

import android.bluetooth.BluetoothDevice
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.bonlala.bonlalable.BonlalaOperateManager
import com.bonlala.bonlalable.bean.DeviceInfoBean
import com.bonlala.bonlalable.bean.RecordHeartRateBean
import com.bonlala.bonlalable.bean.RecordHrvBean
import com.bonlala.bonlalable.bean.RecordSleepActivityBean
import com.bonlala.bonlalable.bean.RecordSleepBean
import com.bonlala.bonlalable.bean.RecordSleepStepBean
import com.bonlala.bonlalable.bean.RecordSpo2Bean
import com.bonlala.bonlalable.bean.RecordStepBean
import com.bonlala.bonlalable.bean.RecordStressBean
import com.bonlala.bonlalable.bean.ScanDeviceInfo
import com.bonlala.bonlalable.listener.BleConnStatusListener
import com.bonlala.bonlalable.listener.ConnStatusListener
import com.bonlala.bonlalable.listener.OnRecordDataListener
import com.bonlala.bonlalable.listener.OnRealTimeDataListener
import com.bonlala.bonlalable.listener.OnScanListener
import com.bonlala.bonlalable.listener.OnSourceDataListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "telomy/wearable_sdk"
    private var sessionActive = false
    private val realtimeCharUuid = UUID.fromString("2b2ebf04-1549-4c7e-bca9-0d498500d191")
    private lateinit var methodChannel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var rawReceiverRegistered = false
    private val rawRealtimeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "com.bonlala.blelibrary.measure_spo2") {
                val spo2 = intent.getStringExtra("ble_params")?.toIntOrNull()
                if (sessionActive && spo2 != null && spo2 in 70..100) {
                    mainHandler.post {
                        methodChannel.invokeMethod("wearableRealtime", mapOf(
                            "connected" to true,
                            "spo2" to spo2,
                            "observedAt" to System.currentTimeMillis()
                        ))
                    }
                }
                return
            }
            if (intent?.action != "action.character_changed") return
            val character = intent.getSerializableExtra("extra.character.uuid") as? UUID ?: return
            if (character != realtimeCharUuid) return
            val bytes = intent.getByteArrayExtra("extra.byte.value") ?: return
            handleRawRealtimePacket(bytes)
        }
    }
    private val manager: BonlalaOperateManager
        get() = BonlalaOperateManager.getInstance()


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        manager.initContext(applicationContext)
        registerRawRealtimeReceiver()
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        )
        methodChannel.setMethodCallHandler { call, result ->
            val safeResult = SafeResult(result)
            try {
                when (call.method) {
                    "platformVersion" -> safeResult.success(Build.VERSION.SDK_INT)
                    "readSnapshot" -> { sessionActive = true; readSnapshot(call, safeResult) }
                    "disconnect" -> {
                        sessionActive = false
                        manager.stopScanDevice()
                        mainHandler.removeCallbacksAndMessages(null)
                        manager.clearRealTimeDataListener()
                        manager.startOrEndMeasureHr(false)
                        manager.disConnDevice()
                        safeResult.success(true)
                    }
                    "forgetDevice" -> {
                        sessionActive = false
                        manager.stopScanDevice()
                        mainHandler.removeCallbacksAndMessages(null)
                        manager.clearRealTimeDataListener()
                        manager.startOrEndMeasureHr(false)
                        manager.disConnDevice()
                        safeResult.success(true)
                    }
                    else -> safeResult.notImplemented()
                }
            } catch (error: Throwable) {
                safeResult.error(
                    "wearable_sdk_error",
                    error.message ?: "Wearable SDK failed.",
                    null
                )
            }
        }
    }


    override fun onDestroy() {
        sessionActive = false
        mainHandler.removeCallbacksAndMessages(null)
        manager.clearRealTimeDataListener()
        manager.startOrEndMeasureHr(false)
        manager.disConnDevice()
        if (rawReceiverRegistered) {
            unregisterReceiver(rawRealtimeReceiver)
            rawReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun registerRawRealtimeReceiver() {
        if (rawReceiverRegistered) return
        val filter = IntentFilter("action.character_changed")
        filter.addAction("com.bonlala.blelibrary.measure_spo2")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(rawRealtimeReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(rawRealtimeReceiver, filter)
        }
        rawReceiverRegistered = true
    }

    private fun handleRawRealtimePacket(bytes: ByteArray) {
        if (!sessionActive) return
        if (bytes.size < 12) return
        val heart = bytes[1].toInt() and 0xFF
        val steps = ((bytes[11].toInt() and 0xFF) shl 24) or
            ((bytes[10].toInt() and 0xFF) shl 16) or
            ((bytes[9].toInt() and 0xFF) shl 8) or
            (bytes[8].toInt() and 0xFF)
        val payload = linkedMapOf<String, Any?>(
            "connected" to true,
            "steps" to steps,
            "observedAt" to System.currentTimeMillis()
        )
        if (heart in 30..240) {
            payload["heartRate"] = heart
        }
        
        mainHandler.post {
            methodChannel.invokeMethod("wearableRealtime", payload)
        }
    }

    private fun readSnapshot(call: MethodCall, result: SafeResult) {
        val mac = call.argument<String>("mac").orEmpty()
        val name = call.argument<String>("name").orEmpty()
        val userId: Int? = null
        val day = call.argument<Int>("day") ?: 0

        if (mac.isBlank()) {
            result.error("missing_mac", "Wearable MAC address is required on Android.", null)
            return
        }

        manager.initContext(applicationContext)
        setConnectionStatusListener()
        connectAfterSdkScan(mac, name, userId, day, result)
    }

    private fun connectAfterSdkScan(
        mac: String,
        name: String,
        userId: Int?,
        day: Int,
        result: SafeResult
    ) {
        var matchedDevice: BluetoothDevice? = null
        var completed = false
        val timeout = Runnable {
            if (completed) return@Runnable
            completed = true
            manager.stopScanDevice()
            val device = matchedDevice
            if (device != null) {
                connectDevice(device, userId, day, result)
            } else {
                connectByAddress(mac, name, userId, day, result)
            }
        }
        mainHandler.postDelayed(timeout, 9000)

        manager.stopScanDevice()
        manager.scanBleDevice(object : OnScanListener {
            override fun onSearchStarted() {
            }

            override fun onDeviceFounded(scanDeviceInfo: ScanDeviceInfo?) {
                try {
                    val device = scanDeviceInfo?.bluetoothDevice ?: return
                    val address = device.address ?: return
                    if (!address.equals(mac, ignoreCase = true)) return

                    matchedDevice = device
                    if (completed) return
                    completed = true
                    manager.stopScanDevice()
                    mainHandler.removeCallbacks(timeout)
                    connectDevice(device, userId, day, result)
                } catch (error: Throwable) {
                    if (!completed) {
                        completed = true
                        mainHandler.removeCallbacks(timeout)
                        result.error(
                            "wearable_scan_error",
                            error.message ?: "Wearable SDK scan failed.",
                            null
                        )
                    }
                }
            }

            override fun onSearchStopped() {
            }

            override fun onSearchCanceled() {
            }
        }, 9 * 1000, 1)
    }

    private fun connectDevice(
        device: BluetoothDevice,
        userId: Int?,
        day: Int,
        result: SafeResult
    ) {
        var handedOff = false
        var timedOut = false
        val timeout = Runnable {
            timedOut = true
            if (!handedOff) {
                result.error(
                    "sdk_timeout",
                    "Wearable SDK did not finish connecting before timeout.",
                    null
                )
            }
        }
        mainHandler.postDelayed(timeout, 15000)

        manager.connDevice(device, object : ConnStatusListener {
            override fun connStatus(status: Int) {
            }

            override fun setNoticeStatus(code: Int) {
                if (!sessionActive) return
                if (code != 0) { result.error("notify_failed", "The ring data channel could not be opened.", null); return }
                if (timedOut || handedOff) return
                handedOff = true
                mainHandler.removeCallbacks(timeout)
                setUserInfoThenPrepare(userId, day, result)
            }
        })
    }

    private fun connectByAddress(
        mac: String,
        name: String,
        userId: Int?,
        day: Int,
        result: SafeResult
    ) {
        var handedOff = false
        var timedOut = false
        val timeout = Runnable {
            timedOut = true
            if (!handedOff) {
                result.error(
                    "sdk_timeout",
                    "Wearable SDK did not finish connecting before timeout.",
                    null
                )
            }
        }
        mainHandler.postDelayed(timeout, 15000)

        manager.connDevice(mac, name.ifBlank { "W596" }, object : ConnStatusListener {
            override fun connStatus(status: Int) {
            }

            override fun setNoticeStatus(code: Int) {
                if (!sessionActive) return
                if (code != 0) { result.error("notify_failed", "The ring data channel could not be opened.", null); return }
                if (timedOut || handedOff) return
                handedOff = true
                mainHandler.removeCallbacks(timeout)
                setUserInfoThenPrepare(userId, day, result)
            }
        })
    }

    private fun setUserInfoThenPrepare(userId: Int?, day: Int, result: SafeResult) {
        if (!sessionActive) return
        if (userId == null) {
            prepareDeviceThenRead(day, result)
            return
        }

        var continued = false
        fun continueSetup() {
            if (continued) return
            continued = true
            mainHandler.postDelayed({ prepareDeviceThenRead(day, result) }, 650)
        }

        val timeout = Runnable {
            
            continueSetup()
        }
        mainHandler.postDelayed(timeout, 1800)
        try {
            manager.setUserInfo(userId) {
                
                mainHandler.removeCallbacks(timeout)
                continueSetup()
            }
        } catch (error: Throwable) {
            
            mainHandler.removeCallbacks(timeout)
            continueSetup()
        }
    }

    private fun prepareDeviceThenRead(day: Int, result: SafeResult) {
        if (!sessionActive) return
        var completed = false
        val timeout = Runnable {
            if (completed) return@Runnable
            completed = true
            readConnectedSnapshot(day, result)
        }
        mainHandler.postDelayed(timeout, 4500)

        fun readInfo() {
            manager.getDeviceInfoData {
            if (completed) return@getDeviceInfoData
            if (it == null) {
                
                completed = true
                mainHandler.removeCallbacks(timeout)
                readConnectedSnapshot(day, result)
                return@getDeviceInfoData
            }
            if (!it.isPair) {
                
                manager.readDeviceMac { mac ->
                    manager.toPairDevice(mac)
                }
                mainHandler.postDelayed({
                    if (completed) return@postDelayed
                    completed = true
                    mainHandler.removeCallbacks(timeout)
                    readConnectedSnapshot(day, result)
                }, 3000)
            } else {
                
                completed = true
                mainHandler.removeCallbacks(timeout)
                readConnectedSnapshot(day, result)
            }
            }
        }

        var timeSynced = false
        val timeTimeout = Runnable {
            if (timeSynced || completed) return@Runnable
            timeSynced = true
            
            readInfo()
        }
        mainHandler.postDelayed(timeTimeout, 1800)
        try {
            manager.setDeviceTime {
                if (timeSynced || completed) return@setDeviceTime
                timeSynced = true
                mainHandler.removeCallbacks(timeTimeout)
                
                mainHandler.postDelayed({ readInfo() }, 500)
            }
        } catch (error: Throwable) {
            mainHandler.removeCallbacks(timeTimeout)
            
            readInfo()
        }
    }

    private fun setConnectionStatusListener() {
        manager.setBleConnStatusListener(object : BleConnStatusListener {
            override fun onConnectStatusChanged(mac: String?, status: Int) {
                if (status == 32 || status == 0) mainHandler.post {
                    methodChannel.invokeMethod("wearableDisconnected", null)
                }
            }
        })
    }

    private fun readConnectedSnapshot(day: Int, result: SafeResult) {
        if (!sessionActive) return
        val response = linkedMapOf<String, Any?>()
        response["connected"] = true
        response["dayOffset"] = day
        response["observedAt"] = System.currentTimeMillis()
        var finished = false
        lateinit var partialTimeout: Runnable

        fun finish() {
            if (finished) return
            finished = true
            mainHandler.removeCallbacks(partialTimeout)
            // History and device-info commands can leave the ring outside its
            // continuous measurement mode. Resume it before returning.
            try {
                manager.startOrEndMeasureHr(true)
            } catch (_: Throwable) {
            }
            result.success(response)
        }

        partialTimeout = Runnable {
            finish()
        }
        // A full history frame is ~6 KB and arrives after several control
        // commands. Eighteen seconds regularly returned only device metadata.
        mainHandler.postDelayed(partialTimeout, 48000)

        fun mergeRecord(key: String, value: Any?) {
            val existingRecords = response["records"] as? Map<*, *>
            val records = linkedMapOf<String, Any?>()
            if (existingRecords != null) {
                for ((existingKey, existingValue) in existingRecords) {
                    if (existingKey is String) records[existingKey] = existingValue
                }
            }
            // Source and structured APIs describe the same daily frame. Keep
            // the first complete result instead of duplicating every sample.
            if (records[key].isEmptyMetric()) records[key] = value
            response["records"] = records
        }

        val syncDays = listOf(day) // Keep day provenance; never combine different days.
        var syncDayIndex = 0
        lateinit var readSourceDataThenRecord: () -> Unit

        fun currentSyncDay(): Int = syncDays[syncDayIndex]

        fun tryNextDayOrFinish(message: String? = null): Boolean {
            if (syncDayIndex + 1 >= syncDays.size) {
                message?.let {
                    response["recordError"] = mapOf(
                        "day" to currentSyncDay(),
                        "code" to 6,
                        "message" to it
                    )
                }
                finish()
                return false
            }
            syncDayIndex += 1
            
            mainHandler.postDelayed({ readSourceDataThenRecord() }, 650)
            return true
        }

        fun readRecord(attempt: Int = 1) {
            var completed = false
            val timeout = Runnable {
                if (completed || finished) return@Runnable
                completed = true
                if (attempt < 3) {
                    
                    mainHandler.postDelayed({ readRecord(attempt + 1) }, 1800)
                    return@Runnable
                }
                if (tryNextDayOrFinish("Record read timed out")) return@Runnable
                response["recordError"] = mapOf(
                    "day" to currentSyncDay(),
                    "code" to -1,
                    "message" to "Record read timed out"
                )
                finish()
            }
            mainHandler.postDelayed(timeout, 5000)

            manager.getRecordByData(currentSyncDay(), object : OnRecordDataListener {
                override fun isNoResponseData(dayStr: String, stateCode: Int) {
                    if (completed || finished) return
                    completed = true
                    mainHandler.removeCallbacks(timeout)
                    
                    if ((stateCode == 4 || stateCode == 5) && attempt < 3) {
                        mainHandler.postDelayed({ readRecord(attempt + 1) }, 2200)
                        return
                    }
                    if ((stateCode == 4 || stateCode == 5 || stateCode == 6 || stateCode == 8) &&
                        tryNextDayOrFinish(errorDescription(stateCode))
                    ) {
                        return
                    }
                    response["recordError"] = mapOf(
                        "day" to dayStr,
                        "code" to stateCode,
                        "message" to errorDescription(stateCode)
                    )
                    finish()
                }

                override fun backRecordData(
                    recordHeartBean: RecordHeartRateBean?,
                    recordStepBean: RecordStepBean?,
                    recordSleepBean: RecordSleepBean?,
                    recordSleepStepBean: RecordSleepStepBean,
                    recordStressBean: RecordStressBean?,
                    recordSpo2Bean: RecordSpo2Bean?,
                    recordHrvBean: RecordHrvBean?,
                    recordSleepActivityBean: RecordSleepActivityBean
                ) {
                    if (completed || finished) return
                    completed = true
                    mainHandler.removeCallbacks(timeout)
                    
                    response["recordDate"] = recordHeartBean?.recordDay ?: recordStepBean?.recordDay
                    mergeRecord("heartRate", recordHeartBean?.heartRateSource.orEmpty())
                    mergeRecord("steps", recordStepBean?.stepSource.orEmpty())
                    mergeRecord("sleep", recordSleepBean?.sourceList.orEmpty())
                    mergeRecord("sleepSteps", recordSleepStepBean.sourceList.orEmpty())
                    mergeRecord("stress", recordStressBean?.stressSource.orEmpty())
                    mergeRecord("spo2", recordSpo2Bean?.sourceList.orEmpty())
                    mergeRecord("hrv", recordHrvBean?.hrvSource.orEmpty())
                    mergeRecord("sleepActivity", recordSleepActivityBean.sourceList.orEmpty())
                    if (response["heartRate"] == null) {
                        recordHeartBean?.heartRateSource?.lastMeaningful()
                            ?.let { response["heartRate"] = it }
                    }
                    if (response["steps"] == null) {
                        response["steps"] = recordStepBean?.stepSource.orEmpty().sum()
                    }
                    recordSpo2Bean?.sourceList?.lastMeaningful()?.let { response["spo2"] = it }
                    recordStressBean?.stressSource?.lastMeaningful()?.let { response["stress"] = it }
                    recordHrvBean?.hrvSource?.lastMeaningful()?.let { response["hrv"] = it }

                    val records = response["records"] as? Map<*, *>
                    val hasMissingWellnessData =
                        response["stress"] == null ||
                            response["hrv"] == null ||
                            response["sleep"] == null ||
                            response["temperatureC"] == null ||
                            records?.get("stress").isEmptyMetric() ||
                            records?.get("hrv").isEmptyMetric() ||
                            records?.get("sleep").isEmptyMetric() ||
                            records?.get("temperatureC").isEmptyMetric()
                    if (hasMissingWellnessData && tryNextDayOrFinish()) return
                    finish()
                }
            })
        }

        readSourceDataThenRecord = {
            var completed = false
            val timeout = Runnable {
                if (completed || finished) return@Runnable
                completed = true
                readRecord()
            }
            mainHandler.postDelayed(timeout, 6500)

            manager.getDataForDay(currentSyncDay(), object : OnSourceDataListener {
                override fun isNoResponseData(stateCode: Int) {
                    if (completed || finished) return
                    // ParseUtils emits state 0 immediately before the actual
                    // source arrays. It means success, not "no response".
                    if (stateCode == 0) return
                    completed = true
                    mainHandler.removeCallbacks(timeout)
                    
                    mainHandler.postDelayed({ readRecord() }, 400)
                }

                override fun backSourceData(
                    heartRate: ByteArray,
                    sleep: ByteArray,
                    spo2: ByteArray,
                    temperature: ByteArray,
                    hrv: ByteArray,
                    stress: ByteArray,
                    activity: ByteArray,
                    sleepActivity: ByteArray
                ) {
                    if (completed || finished) return
                    completed = true
                    mainHandler.removeCallbacks(timeout)
                    val heartSeries = heartRate.toUnsignedSeries(30, 240)
                    val heartValues = heartSeries.filter { it > 0 }
                    val stepValues = sleep.map { it.toInt() and 0xFF }
                        .map { if (it <= 250) it else 0 }
                    val sleepValues = sleep.map { it.toInt() and 0xFF }
                        .map { if (it > 250) it - 250 else 0 }
                    val spo2Series = spo2.toUnsignedSeries(70, 100)
                    val hrvSeries = hrv.toUnsignedSeries(1, 250)
                    val stressSeries = stress.toUnsignedSeries(1, 100)
                    val activitySeries = activity.toUnsignedSeries(1, 250)
                    val spo2Values = spo2Series.filter { it > 0 }
                    val hrvValues = hrvSeries.filter { it > 0 }
                    val stressValues = stressSeries.filter { it > 0 }

                    mergeRecord("heartRate", heartSeries)
                    mergeRecord("steps", stepValues)
                    mergeRecord("sleep", sleepValues)
                    mergeRecord("spo2", spo2Series)
                    mergeRecord("hrv", hrvSeries)
                    mergeRecord("stress", stressSeries)
                    mergeRecord("activity", activitySeries)

                    heartValues.lastOrNull()?.let { response.putIfAbsent("heartRate", it) }
                    response.putIfAbsent("steps", stepValues.sum())
                    spo2Values.lastOrNull()?.let { response.putIfAbsent("spo2", it) }
                    hrvValues.lastOrNull()?.let { response.putIfAbsent("hrv", it) }
                    stressValues.lastOrNull()?.let { response.putIfAbsent("stress", it) }
                    val sleepMinutes = sleepValues.count { it > 0 }
                    if (sleepMinutes > 0) response["sleepMinutes"] = sleepMinutes

                    val temperatures = temperature.toTemperatureCList()
                    if (temperatures.isNotEmpty()) {
                        mergeRecord("temperatureC", temperatures)
                        response.putIfAbsent("temperatureC", temperatures.last())
                    }
                    mainHandler.postDelayed({ readRecord() }, 250)
                }
            })
        }

        fun readDeviceInfo() {
            var completed = false
            val timeout = Runnable {
                if (completed || finished) return@Runnable
                completed = true
                readRecord()
            }
            mainHandler.postDelayed(timeout, 3500)

            manager.getDeviceInfoData {
                if (completed || finished) return@getDeviceInfoData
                completed = true
                mainHandler.removeCallbacks(timeout)
                
                response["deviceInfo"] = deviceInfoMap(it)
                mainHandler.postDelayed({ readSourceDataThenRecord() }, 900)
            }
        }

        fun readFirmware() {
            var completed = false
            val timeout = Runnable {
                if (completed || finished) return@Runnable
                completed = true
                readDeviceInfo()
            }
            mainHandler.postDelayed(timeout, 3500)

            manager.getDeviceFirmwareVersion {
                if (completed || finished) return@getDeviceFirmwareVersion
                completed = true
                mainHandler.removeCallbacks(timeout)
                
                response["firmware"] = it
                mainHandler.postDelayed({ readDeviceInfo() }, 300)
            }
        }

        fun readBattery() {
            var completed = false
            val timeout = Runnable {
                if (completed || finished) return@Runnable
                completed = true
                readFirmware()
            }
            mainHandler.postDelayed(timeout, 3500)

            manager.getDeviceBattery {
                if (completed || finished) return@getDeviceBattery
                completed = true
                mainHandler.removeCallbacks(timeout)
                
                response["battery"] = it
                mainHandler.postDelayed({ readFirmware() }, 300)
            }
        }

        fun continueAfterRealtime() {
            try {
                manager.startMeasureSpo2()
                
            } catch (error: Throwable) {
                
            }
            mainHandler.postDelayed({ readBattery() }, 1200)
        }

        fun startHeartMeasurementThenContinue() {
            
            manager.startOrEndMeasureHr(true)
            continueAfterRealtime()
        }

        manager.clearRealTimeDataListener()
        manager.setRealTimeData(object : OnRealTimeDataListener {
            override fun backRealTimeData(heart: Int, countStep: Int) {
                
                if (heart in 30..240) {
                    response["heartRate"] = heart
                }
                response["steps"] = countStep
                val payload = linkedMapOf<String, Any?>(
                    "connected" to true,
                    "steps" to countStep,
                    "observedAt" to System.currentTimeMillis()
                )
                if (heart in 30..240) {
                    payload["heartRate"] = heart
                }
                mainHandler.post {
                    methodChannel.invokeMethod(
                        "wearableRealtime",
                        payload
                    )
                }
            }
        })

        var realTimeStarted = false
        manager.openRealTimeHeartRateSwitch {
            if (realTimeStarted || finished) return@openRealTimeHeartRateSwitch
            realTimeStarted = true
            
            response["realTimeSwitch"] = it
            mainHandler.postDelayed({ startHeartMeasurementThenContinue() }, if (it) 600 else 1100)
        }
        mainHandler.postDelayed({
            if (realTimeStarted || finished) return@postDelayed
            realTimeStarted = true
            response["realTimeSwitch"] = false
            
            startHeartMeasurementThenContinue()
        }, 3500)
    }

    private fun deviceInfoMap(info: DeviceInfoBean): Map<String, Any?> {
        return mapOf(
            "deviceId" to info.deviceId,
            "powerOnTime" to info.powerOnTime,
            "historyDay" to info.historyDay,
            "deviceState" to info.deviceState,
            "deviceStatus" to deviceStatus(info.deviceState),
            "time" to info.time,
            "isPair" to info.isPair
        )
    }

    private fun List<Int>.lastMeaningful(): Int? {
        return lastOrNull { it > 0 }
    }

    private fun appendMetricValues(existing: Any?, incoming: Any?): Any? {
        val merged = mutableListOf<Any?>()
        fun addValue(value: Any?) {
            when (value) {
                null -> Unit
                is Iterable<*> -> value.forEach { addValue(it) }
                is IntArray -> value.forEach { addValue(it) }
                is DoubleArray -> value.forEach { addValue(it) }
                is FloatArray -> value.forEach { addValue(it) }
                is LongArray -> value.forEach { addValue(it) }
                else -> merged.add(value)
            }
        }
        addValue(existing)
        addValue(incoming)
        return merged
    }

    private fun Any?.isEmptyMetric(): Boolean {
        if (this == null) return true
        if (this is Iterable<*>) {
            return none { item ->
                when (item) {
                    is Number -> item.toDouble() > 0.0
                    is String -> item.isNotBlank() && item != "0"
                    else -> item != null
                }
            }
        }
        if (this is Number) return toDouble() <= 0.0
        if (this is String) return isBlank() || this == "0"
        return false
    }

    private fun sleepDuration(values: List<Int>): String? {
        val minutes = values.count { it > 0 }
        if (minutes <= 0) return null
        val hours = minutes / 60
        val remainder = minutes % 60
        return if (hours > 0) "${hours}h ${remainder}m" else "${remainder}m"
    }

    private fun ByteArray.countPositive(): Int {
        return count { (it.toInt() and 0xFF) > 0 }
    }

    private fun ByteArray.countSleepMinutes(): Int {
        return count { (it.toInt() and 0xFF) > 250 }
    }

    private fun ByteArray.toPositiveIntList(): List<Int> {
        return map { it.toInt() and 0xFF }.filter { it > 0 }
    }

    private fun ByteArray.toUnsignedSeries(min: Int, max: Int): List<Int> {
        return map { it.toInt() and 0xFF }.map { if (it in min..max) it else 0 }
    }

    private fun ByteArray.toSleepMinuteMarkers(): List<Int> {
        return map { it.toInt() and 0xFF }.map { if (it > 250) 1 else 0 }
    }

    private fun ByteArray.toTemperatureCList(): List<Double> {
        val values = mutableListOf<Double>()
        for (byte in this) {
            val raw = byte.toInt() and 0xFF
            val temperature = when {
                raw in 30..45 -> raw.toDouble()
                raw in 150..225 -> raw / 5.0
                else -> null
            }
            if (temperature != null) values.add(temperature)
        }
        return values
    }

    private fun deviceStatus(code: Int): String {
        return when (code) {
            0 -> "Heart rate not open"
            1 -> "Normal"
            2 -> "Finger is not on the device during heart-rate measurement"
            3 -> "Charging"
            else -> "Unknown ($code)"
        }
    }

    private fun errorDescription(code: Int): String {
        return when (code) {
            1 -> "Invalid message"
            2 -> "Battery is low"
            3 -> "Data channel is not open"
            4 -> "Device is requesting a communication interval"
            5 -> "Device busy"
            6 -> "No data"
            8 -> "No saved health history yet"
            else -> "Unknown error ($code)"
        }
    }
}

private class SafeResult(private val delegate: MethodChannel.Result) {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var completed = false

    fun success(value: Any?) {
        complete { delegate.success(value) }
    }

    fun error(code: String, message: String?, details: Any?) {
        complete { delegate.error(code, message, details) }
    }

    fun notImplemented() {
        complete { delegate.notImplemented() }
    }

    private fun complete(block: () -> Unit) {
        if (completed) return
        completed = true

        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post { block() }
        }
    }
}

private fun ByteArray.toHexString(): String {
    return joinToString("") { byte ->
        (byte.toInt() and 0xFF).toString(16).padStart(2, '0').uppercase()
    }
}
