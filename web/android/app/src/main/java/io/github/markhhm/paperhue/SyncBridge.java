package io.github.markhhm.paperhue;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * `window.PaperhueSync` in the background sync's page (src/background/native.ts): what the
 * Capacitor plugins do in the app, for a WebView without them. Bluetooth GATT to the device the
 * app connected to last (no scan, no chooser), the phone's calendar query and HTTP for iCal
 * addresses. A call answers later: the answer is stored, the page is told with
 * `paperhueSync.settle(id)` and takes it with take(id). Notifications and a dropped link arrive as
 * `paperhueSync.event({...})`. Bytes travel as hex. Addresses never appear in an error.
 */
@SuppressLint("MissingPermission") // the app asked for Bluetooth before it remembered a device
final class SyncBridge {

    interface Listener {
        /** The page finished: `result` is its JSON result. Called on the main thread. */
        void finished(String result);
    }

    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final int MAX_DOWNLOAD = 20 * 1024 * 1024;

    private final Context context;
    private final WebView web;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Map<String, String> answers = new ConcurrentHashMap<>();
    private boolean closed;

    // One GATT operation at a time: the page's transport queues them.
    private BluetoothGatt gatt;
    private String connecting;
    private String operation;
    private boolean linkUp;
    private int mtu = 23;

    SyncBridge(Context context, WebView web, Listener listener) {
        this.context = context;
        this.web = web;
        this.listener = listener;
    }

    @JavascriptInterface
    public void call(String id, String method, String argsJson) {
        try {
            JSONObject args = new JSONObject(argsJson);
            switch (method) {
                case "ble.isEnabled":
                    BluetoothAdapter adapter = adapter();
                    answer(id, adapter != null && adapter.isEnabled());
                    break;
                case "ble.connect":
                    connect(id, args.getString("deviceId"));
                    break;
                case "ble.disconnect":
                    closeGatt();
                    answer(id, JSONObject.NULL);
                    break;
                case "ble.services":
                    answer(id, services());
                    break;
                case "ble.getMtu":
                    answer(id, mtu);
                    break;
                case "ble.notify":
                    enableNotifications(id, characteristic(args));
                    break;
                case "ble.write":
                    write(id, characteristic(args), fromHex(args.getString("value")), args.getBoolean("withResponse"));
                    break;
                case "ble.read":
                    read(id, characteristic(args));
                    break;
                case "calendar.events":
                    long from = args.getLong("from");
                    long to = args.getLong("to");
                    io.execute(() -> {
                        try {
                            answer(id, PhoneCalendar.allowed(context) ? PhoneCalendar.events(context, from, to) : JSONObject.NULL);
                        } catch (JSONException | RuntimeException e) {
                            fail(id, "the calendars could not be read");
                        }
                    });
                    break;
                case "http.get":
                    String url = args.getString("url");
                    io.execute(() -> {
                        try {
                            answer(id, httpGet(url));
                        } catch (IOException | JSONException | RuntimeException e) {
                            fail(id, "download failed (" + e.getClass().getSimpleName() + ")");
                        }
                    });
                    break;
                default:
                    fail(id, "unknown method " + method);
            }
        } catch (JSONException | RuntimeException e) {
            fail(id, describe(e));
        }
    }

    @JavascriptInterface
    public String take(String id) {
        String answer = answers.remove(id);
        return answer == null ? "{\"error\":\"no answer\"}" : answer;
    }

    @JavascriptInterface
    public void finish(String result) {
        main.post(() -> {
            if (!closed) listener.finished(result);
        });
    }

    /** Disconnect and stop answering (the service is done). */
    void close() {
        closed = true;
        closeGatt();
        io.shutdownNow();
    }

    // --- Answers -------------------------------------------------------------------------------

    private void answer(String id, Object value) {
        try {
            reply(id, new JSONObject().put("value", value));
        } catch (JSONException e) {
            fail(id, "unreadable answer");
        }
    }

    private void fail(String id, String message) {
        try {
            reply(id, new JSONObject().put("error", message));
        } catch (JSONException e) {
            // cannot happen with a string
        }
    }

    private void reply(String id, JSONObject answer) {
        answers.put(id, answer.toString());
        script("window.paperhueSync && window.paperhueSync.settle(" + JSONObject.quote(id) + ")");
    }

    private void event(JSONObject event) {
        script("window.paperhueSync && window.paperhueSync.event(" + event + ")");
    }

    private void script(String code) {
        main.post(() -> {
            if (!closed) web.evaluateJavascript(code, null);
        });
    }

    // --- HTTP ----------------------------------------------------------------------------------

    /** GET an iCal address: {status, text}. No cookies; redirects only within https (HttpURLConnection never follows https to http). */
    static JSONObject httpGet(String address) throws IOException, JSONException {
        URL url = new URL(address);
        if (!"https".equals(url.getProtocol()) && !"http".equals(url.getProtocol())) throw new IOException("not an http address");
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        try {
            connection.setConnectTimeout(30_000);
            connection.setReadTimeout(30_000);
            connection.setUseCaches(false);
            connection.setRequestProperty("Accept", "text/calendar, */*");
            int status = connection.getResponseCode();
            String text = "";
            if (status >= 200 && status < 300) {
                try (InputStream in = connection.getInputStream()) {
                    ByteArrayOutputStream body = new ByteArrayOutputStream();
                    byte[] buffer = new byte[16 * 1024];
                    for (int n; (n = in.read(buffer)) > 0; ) {
                        if (body.size() + n > MAX_DOWNLOAD) throw new IOException("too large");
                        body.write(buffer, 0, n);
                    }
                    text = new String(body.toByteArray(), StandardCharsets.UTF_8);
                }
            }
            return new JSONObject().put("status", status).put("text", text);
        } finally {
            connection.disconnect();
        }
    }

    // --- Bluetooth -----------------------------------------------------------------------------

    private BluetoothAdapter adapter() {
        BluetoothManager manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
        return manager == null ? null : manager.getAdapter();
    }

    private synchronized void connect(String id, String address) {
        closeGatt();
        BluetoothAdapter adapter = adapter();
        if (adapter == null || !adapter.isEnabled()) {
            fail(id, "Bluetooth is off");
            return;
        }
        BluetoothDevice device = adapter.getRemoteDevice(address);
        connecting = id;
        mtu = 23;
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE);
        if (gatt == null) {
            connecting = null;
            fail(id, "connecting failed");
        }
    }

    /** Close the link; a pending connect or operation fails, as a dropped link does. */
    private synchronized void closeGatt() {
        if (gatt != null) {
            gatt.disconnect();
            gatt.close();
            gatt = null;
        }
        linkUp = false;
        settleConnect("disconnected");
        settleOperation("disconnected", null);
    }

    private synchronized void settleConnect(String error) {
        String id = connecting;
        connecting = null;
        if (id == null) return;
        if (error == null) {
            linkUp = true;
            answer(id, JSONObject.NULL);
        } else {
            fail(id, error);
        }
    }

    private synchronized void settleOperation(String error, Object value) {
        String id = operation;
        operation = null;
        if (id == null) return;
        if (error == null) answer(id, value == null ? JSONObject.NULL : value);
        else fail(id, error);
    }

    private synchronized BluetoothGatt link() {
        if (gatt == null || !linkUp) throw new IllegalStateException("not connected");
        return gatt;
    }

    private synchronized JSONArray services() throws JSONException {
        JSONArray list = new JSONArray();
        for (BluetoothGattService service : link().getServices()) {
            JSONArray characteristics = new JSONArray();
            for (BluetoothGattCharacteristic c : service.getCharacteristics()) {
                characteristics.put(new JSONObject().put("uuid", c.getUuid().toString()).put("properties", new JSONObject()).put("descriptors", new JSONArray()));
            }
            list.put(new JSONObject().put("uuid", service.getUuid().toString()).put("characteristics", characteristics));
        }
        return list;
    }

    private synchronized BluetoothGattCharacteristic characteristic(JSONObject args) throws JSONException {
        BluetoothGattService service = link().getService(UUID.fromString(args.getString("service")));
        BluetoothGattCharacteristic characteristic = service == null ? null : service.getCharacteristic(UUID.fromString(args.getString("characteristic")));
        if (characteristic == null) throw new IllegalStateException("the device does not offer " + args.getString("characteristic"));
        return characteristic;
    }

    @SuppressWarnings("deprecation")
    private synchronized void enableNotifications(String id, BluetoothGattCharacteristic characteristic) {
        BluetoothGatt link = link();
        if (!link.setCharacteristicNotification(characteristic, true)) {
            fail(id, "enabling notifications failed");
            return;
        }
        BluetoothGattDescriptor cccd = characteristic.getDescriptor(CCCD);
        if (cccd == null) {
            answer(id, JSONObject.NULL);
            return;
        }
        byte[] value = (characteristic.getProperties() & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
            ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE;
        operation = id;
        boolean started;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            started = link.writeDescriptor(cccd, value) == BluetoothStatusCodes.SUCCESS;
        } else {
            cccd.setValue(value);
            started = link.writeDescriptor(cccd);
        }
        if (!started) settleOperation("enabling notifications failed: the Bluetooth stack is busy", null);
    }

    @SuppressWarnings("deprecation")
    private synchronized void write(String id, BluetoothGattCharacteristic characteristic, byte[] value, boolean withResponse) {
        BluetoothGatt link = link();
        int type = withResponse ? BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT : BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
        operation = id;
        boolean started;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            started = link.writeCharacteristic(characteristic, value, type) == BluetoothStatusCodes.SUCCESS;
        } else {
            characteristic.setWriteType(type);
            characteristic.setValue(value);
            started = link.writeCharacteristic(characteristic);
        }
        if (!started) settleOperation("write failed: the Bluetooth stack is busy", null);
    }

    private synchronized void read(String id, BluetoothGattCharacteristic characteristic) {
        operation = id;
        if (!link().readCharacteristic(characteristic)) settleOperation("read failed: the Bluetooth stack is busy", null);
    }

    private static String statusText(int status) {
        switch (status) {
            case 5:
                return "GATT status 5 (insufficient authentication: pairing)";
            case 15:
                return "GATT status 15 (insufficient encryption: pairing)";
            default:
                return "GATT status " + status;
        }
    }

    private void notified(BluetoothGattCharacteristic characteristic, byte[] value) {
        try {
            event(new JSONObject().put("type", "notify").put("characteristic", characteristic.getUuid().toString()).put("value", toHex(value)));
        } catch (JSONException e) {
            // cannot happen with strings
        }
    }

    private final BluetoothGattCallback callback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            synchronized (SyncBridge.this) {
                if (g != gatt) return;
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    if (!g.discoverServices()) settleConnect("finding the services failed");
                    return;
                }
                if (newState != BluetoothProfile.STATE_DISCONNECTED && status == BluetoothGatt.GATT_SUCCESS) return;
                boolean wasUp = linkUp;
                g.close();
                gatt = null;
                linkUp = false;
                settleConnect("connecting failed (" + statusText(status) + ")");
                settleOperation("the device disconnected", null);
                if (wasUp) {
                    try {
                        event(new JSONObject().put("type", "disconnected"));
                    } catch (JSONException e) {
                        // cannot happen
                    }
                }
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            synchronized (SyncBridge.this) {
                if (g != gatt) return;
                if (status != BluetoothGatt.GATT_SUCCESS) settleConnect("finding the services failed (" + statusText(status) + ")");
                else if (!g.requestMtu(512)) settleConnect(null);
            }
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int newMtu, int status) {
            synchronized (SyncBridge.this) {
                if (g != gatt) return;
                if (status == BluetoothGatt.GATT_SUCCESS) mtu = newMtu;
                settleConnect(null);
            }
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor descriptor, int status) {
            settleOperation(status == BluetoothGatt.GATT_SUCCESS ? null : "enabling notifications failed (" + statusText(status) + ")", null);
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic characteristic, int status) {
            settleOperation(status == BluetoothGatt.GATT_SUCCESS ? null : "write failed (" + statusText(status) + ")", null);
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic characteristic, byte[] value, int status) {
            settleOperation(status == BluetoothGatt.GATT_SUCCESS ? null : "read failed (" + statusText(status) + ")", toHex(value));
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic characteristic, int status) {
            // Android 12 and older.
            onCharacteristicRead(g, characteristic, characteristic.getValue(), status);
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic characteristic, byte[] value) {
            notified(characteristic, value);
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic characteristic) {
            // Android 12 and older.
            notified(characteristic, characteristic.getValue());
        }
    };

    // --- Helpers -------------------------------------------------------------------------------

    private static String toHex(byte[] bytes) {
        if (bytes == null) return "";
        StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) hex.append(String.format("%02x", b & 0xff));
        return hex.toString();
    }

    private static byte[] fromHex(String hex) {
        byte[] bytes = new byte[hex.length() / 2];
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        return bytes;
    }

    private static String describe(Exception e) {
        return e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
    }
}
