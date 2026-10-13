package io.github.markhhm.paperhue;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.content.res.AssetManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import android.webkit.ConsoleMessage;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.Collections;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * One scheduled sync, without opening the app: a foreground service (connected device) that loads
 * the sync page (background.html, src/background/main.ts) in a WebView without a screen. The page
 * is served from the app's own files at the app's own address (https://localhost), so it reads the
 * app's storage (the page plan, the device and the iCal addresses) and reuses the app's drawing
 * and device session; SyncBridge gives it Bluetooth, the phone's calendars and HTTP. Its result
 * goes to SyncScheduler, which logs it, retries when the device was not found and plans the next run.
 */
public class SyncService extends Service {

    private static final String TAG = "PaperhueSync";
    private static final String CHANNEL = "sync";
    private static final int NOTIFICATION = 1;
    /** A run that takes longer is stopped (an upload of four pages takes a few minutes). */
    private static final long LIMIT_MS = 10 * 60_000L;
    private static final String PAGE = "https://localhost/background.html";

    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable timeout = () -> finished(errorResult("the sync took longer than 10 minutes"));
    private WebView web;
    private SyncBridge bridge;
    private PowerManager.WakeLock wake;
    private long startedAt;
    private boolean running;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        try {
            ServiceCompat.startForeground(this, NOTIFICATION, notification(), connectedDeviceType());
        } catch (RuntimeException refused) {
            // Android refused (no Bluetooth permission, or not allowed from the background).
            SyncScheduler.recordRun(this, System.currentTimeMillis(), errorResult("Android did not let the sync run (" + refused.getClass().getSimpleName() + ")"));
            stopSelf();
            return START_NOT_STICKY;
        }
        if (running) return START_NOT_STICKY;
        running = true;
        startedAt = System.currentTimeMillis();
        PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
        if (power != null) {
            wake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "paperhue:sync");
            wake.acquire(LIMIT_MS + 60_000L);
        }
        main.postDelayed(timeout, LIMIT_MS);
        startPage();
        return START_NOT_STICKY;
    }

    @SuppressLint({ "SetJavaScriptEnabled", "JavascriptInterface" })
    private void startPage() {
        web = new WebView(this);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        bridge = new SyncBridge(this, web, this::finished);
        web.addJavascriptInterface(bridge, "PaperhueSync");
        AssetManager assets = getAssets();
        web.setWebViewClient(
            new WebViewClient() {
                @Override
                public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                    return appFile(assets, request.getUrl());
                }

                @Override
                public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    return true; // the page never navigates
                }

                @Override
                public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                    // Without this the crash of the page's renderer takes the whole app process down with it.
                    finished(errorResult("the sync page crashed" + (detail.didCrash() ? "" : " (Android needed its memory)")));
                    return true;
                }
            }
        );
        web.setWebChromeClient(
            new WebChromeClient() {
                @Override
                public boolean onConsoleMessage(ConsoleMessage message) {
                    Log.d(TAG, message.message());
                    return true;
                }
            }
        );
        web.resumeTimers();
        web.loadUrl(PAGE);
    }

    /** The page's result arrived (or the time ran out): log it, plan what comes next, stop. */
    private void finished(String result) {
        if (!running) return;
        running = false;
        main.removeCallbacks(timeout);
        SyncScheduler.recordRun(this, startedAt, result);
        if (bridge != null) bridge.close();
        if (web != null) web.destroy();
        if (wake != null && wake.isHeld()) wake.release();
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    @Override
    public void onDestroy() {
        finished(errorResult("Android stopped the sync"));
        super.onDestroy();
    }

    /** The app's own files (what `npx cap sync` copied to assets/public) at https://localhost; nothing else loads. */
    static WebResourceResponse appFile(AssetManager assets, Uri url) {
        String path = url.getPath();
        if (!"https".equals(url.getScheme()) || !"localhost".equals(url.getHost()) || path == null || path.contains("..")) {
            return status(403, "Forbidden");
        }
        try {
            return new WebResourceResponse(mimeType(path), null, assets.open("public" + path));
        } catch (IOException e) {
            return status(404, "Not Found");
        }
    }

    private static WebResourceResponse status(int code, String reason) {
        return new WebResourceResponse("text/plain", "utf-8", code, reason, Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
    }

    private static String mimeType(String path) {
        String extension = path.substring(path.lastIndexOf('.') + 1).toLowerCase(java.util.Locale.ROOT);
        switch (extension) {
            case "html":
                return "text/html";
            case "js":
            case "mjs":
                return "text/javascript";
            case "css":
                return "text/css";
            case "json":
                return "application/json";
            case "otf":
                return "font/otf";
            case "png":
                return "image/png";
            case "svg":
                return "image/svg+xml";
            default:
                return "application/octet-stream";
        }
    }

    private static int connectedDeviceType() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ? ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE : 0;
    }

    private Notification notification() {
        boolean chinese = SyncScheduler.chinese(this);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager manager = getSystemService(NotificationManager.class);
            NotificationChannel channel = new NotificationChannel(CHANNEL, chinese ? "定時同步" : "Scheduled sync", NotificationManager.IMPORTANCE_LOW);
            if (manager != null) manager.createNotificationChannel(channel);
        }
        return new NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Paperhue")
            .setContentText(chinese ? "正在更新行事曆頁" : "Updating the calendar pages")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build();
    }

    private static String errorResult(String message) {
        try {
            return new JSONObject().put("outcome", "error").put("message", message).toString();
        } catch (JSONException e) {
            return "";
        }
    }
}
