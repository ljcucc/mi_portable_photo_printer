package com.example.mi_printer_example

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/**
 * RFCOMM (SPP channel 1) transport for the Mi Portable Photo Printer.
 *
 * MethodChannel  "mi_printer/transport"      : open / write / close / isOpen
 * EventChannel   "mi_printer/transport/rx"   : raw rx bytes (arbitrary chunks)
 *
 * The printer drops an idle link after ~15s; the Dart layer pings it.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MiPrinter"
        private const val CHANNEL = "mi_printer/transport"
        private const val SPP_UUID = "00001101-0000-1000-8000-00805F9B34FB"
        private const val REQ_BT_CONNECT = 1001
    }

    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private var readThread: Thread? = null
    private val writeExecutor = Executors.newSingleThreadExecutor()
    private var pendingConnect: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("bad_args", "address is required", null)
                    } else {
                        openWithPermission(address, result)
                    }
                }
                "write" -> {
                    val data = call.arguments as? ByteArray
                    val s = socket
                    if (data == null || s == null || !s.isConnected) {
                        result.error("not_connected", "socket is not open", null)
                    } else {
                        writeExecutor.execute {
                            try {
                                s.outputStream.write(data)
                                s.outputStream.flush()
                                runOnUiThread { result.success(null) }
                            } catch (e: Exception) {
                                Log.e(TAG, "write failed", e)
                                runOnUiThread {
                                    result.error("write_failed", "${e.javaClass.simpleName}: ${e.message}", null)
                                }
                            }
                        }
                    }
                }
                "close" -> {
                    closeSocket()
                    result.success(null)
                }
                "isOpen" -> result.success(socket?.isConnected == true)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "$CHANNEL/rx").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            },
        )
    }

    private fun openWithPermission(address: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 31) {
            val needed = arrayListOf(Manifest.permission.BLUETOOTH_CONNECT)
            // cancelDiscovery() needs BLUETOOTH_SCAN even for bonded devices.
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                needed.add(Manifest.permission.BLUETOOTH_SCAN)
            }
            val missing = needed.filter {
                checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
            }
            if (missing.isEmpty()) {
                connect(address, result)
            } else {
                pendingConnect = { connect(address, result) }
                requestPermissions(missing.toTypedArray(), REQ_BT_CONNECT)
            }
        } else {
            connect(address, result)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_BT_CONNECT) {
            val cb = pendingConnect
            pendingConnect = null
            val connectGranted = permissions.contains(Manifest.permission.BLUETOOTH_CONNECT) &&
                grantResults[permissions.indexOf(Manifest.permission.BLUETOOTH_CONNECT)] ==
                PackageManager.PERMISSION_GRANTED
            if (connectGranted) {
                cb?.invoke()
            } else {
                // The pending closure already holds the result object; report denial.
                MethodChannel(
                    flutterEngine?.dartExecutor?.binaryMessenger ?: return,
                    CHANNEL,
                ).invokeMethod("permissionDenied", null)
            }
        }
    }

    private fun closeSocket() {
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String, result: MethodChannel.Result) {
        closeSocket()
        Thread {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                val device = adapter.getRemoteDevice(address)
                try {
                    adapter.cancelDiscovery()
                } catch (e: SecurityException) {
                    Log.w(TAG, "cancelDiscovery denied (SCAN permission); continuing")
                }
                val s = device.createRfcommSocketToServiceRecord(UUID.fromString(SPP_UUID))
                s.connect()
                socket = s
                Log.i(TAG, "connected to $address")
                startReadLoop(s)
                runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "connect to $address failed", e)
                closeSocket()
                runOnUiThread {
                    result.error(
                        "connect_failed",
                        "${e.javaClass.simpleName}: ${e.message} " +
                            "(印表機需先開機並已與手機配對)",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun startReadLoop(s: BluetoothSocket) {
        readThread?.interrupt()
        val t = Thread {
            val buf = ByteArray(1024)
            try {
                val input = s.inputStream
                while (s.isConnected) {
                    val n = input.read(buf)
                    if (n > 0) {
                        val chunk = buf.copyOf(n)
                        runOnUiThread { eventSink?.success(chunk) }
                    }
                }
            } catch (_: Exception) {
                // link dropped or thread interrupted
            }
            runOnUiThread { eventSink?.success(ByteArray(0)) } // EOF signal
        }
        t.isDaemon = true
        readThread = t
        t.start()
    }
}
