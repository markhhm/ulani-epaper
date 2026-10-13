package io.github.markhhm.paperhue;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;
import android.util.Base64;
import androidx.activity.result.ActivityResult;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.json.JSONException;

/**
 * The app's calendar and schedule (src/app/android.ts): the calendar permission (the app asks at
 * first use), the phone's calendar query, the scheduled sync's times and log, and saving a file
 * (a WebView cannot download one): the page sends the bytes in chunks, then the system's "save as"
 * screen asks where to put them.
 */
@CapacitorPlugin(name = "Paperhue", permissions = @Permission(alias = "calendar", strings = { Manifest.permission.READ_CALENDAR }))
public class PaperhuePlugin extends Plugin {

    @Override
    public void load() {
        // Alarms are gone after the app was force-stopped: plan the next run again.
        SyncScheduler.plan(getContext());
    }

    @PluginMethod
    public void phoneEvents(PluginCall call) {
        Long from = call.getLong("from");
        Long to = call.getLong("to");
        if (from == null || to == null) {
            call.reject("from and to are needed");
            return;
        }
        if (getPermissionState("calendar") != PermissionState.GRANTED) {
            call.reject("no permission to read the calendars");
            return;
        }
        try {
            call.resolve(new JSObject(PhoneCalendar.events(getContext(), from, to).toString()));
        } catch (JSONException | RuntimeException e) {
            call.reject("the calendars could not be read", e);
        }
    }

    @PluginMethod
    public void getSchedule(PluginCall call) {
        resolveSchedule(call);
    }

    /** Keep the times ({times: ["HH:MM"], locale}) and plan the next run; the first time there are times, ask once about battery optimisation. */
    @PluginMethod
    public void setSchedule(PluginCall call) {
        List<String> times = new ArrayList<>();
        try {
            for (Object time : call.getArray("times", new JSArray()).toList()) {
                if (time instanceof String && ((String) time).matches("([01]\\d|2[0-3]):[0-5]\\d") && !times.contains(time)) times.add((String) time);
            }
        } catch (JSONException e) {
            call.reject("times must be a list of HH:MM");
            return;
        }
        Collections.sort(times);
        SyncScheduler.setTimes(getContext(), times, call.getString("locale", "en"));
        if (!times.isEmpty() && SyncScheduler.firstBatteryQuestion(getContext())) {
            Intent ask = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getContext().getPackageName()));
            try {
                getActivity().startActivity(ask);
            } catch (ActivityNotFoundException | SecurityException e) {
                // The app's note says where the setting is.
            }
        }
        resolveSchedule(call);
    }

    /** The file being saved, kept in the app's cache until the user has chosen where it goes. */
    private File staged() {
        return new File(getContext().getCacheDir(), "paperhue-save.tmp");
    }

    /** Keep one chunk ({data: base64, first}) of a file to save; the first chunk starts a new file. */
    @PluginMethod
    public void stageFile(PluginCall call) {
        String data = call.getString("data");
        if (data == null) {
            call.reject("data is needed");
            return;
        }
        boolean first = Boolean.TRUE.equals(call.getBoolean("first", false));
        try (FileOutputStream out = new FileOutputStream(staged(), !first)) {
            out.write(Base64.decode(data, Base64.DEFAULT));
            call.resolve();
        } catch (IOException | IllegalArgumentException e) {
            call.reject("the file could not be kept", e);
        }
    }

    /** Ask where to save the kept file ({name, type}) with the system's "save as" screen; resolves {saved}. */
    @PluginMethod
    public void saveFile(PluginCall call) {
        String name = call.getString("name");
        if (name == null || name.isEmpty() || !staged().exists()) {
            call.reject("there is no file to save");
            return;
        }
        Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(call.getString("type", "application/octet-stream"))
            .putExtra(Intent.EXTRA_TITLE, name);
        startActivityForResult(call, save, "fileSaved");
    }

    @ActivityCallback
    private void fileSaved(PluginCall call, ActivityResult result) {
        if (call == null) return;
        Uri uri = result.getResultCode() == Activity.RESULT_OK && result.getData() != null ? result.getData().getData() : null;
        try {
            JSObject answer = new JSObject();
            if (uri == null) {
                answer.put("saved", false); // the user backed out
            } else {
                try (InputStream in = new FileInputStream(staged()); OutputStream out = getContext().getContentResolver().openOutputStream(uri)) {
                    if (out == null) throw new IOException("no place to write to");
                    byte[] buffer = new byte[64 * 1024];
                    for (int n = in.read(buffer); n >= 0; n = in.read(buffer)) out.write(buffer, 0, n);
                }
                answer.put("saved", true);
            }
            call.resolve(answer);
        } catch (IOException | RuntimeException e) {
            call.reject("the file could not be saved", e);
        } finally {
            staged().delete();
        }
    }

    private void resolveSchedule(PluginCall call) {
        try {
            call.resolve(new JSObject(SyncScheduler.schedule(getContext()).toString()));
        } catch (JSONException e) {
            call.reject("the schedule could not be read", e);
        }
    }
}
