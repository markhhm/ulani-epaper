package io.github.markhhm.paperhue;

import android.Manifest;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.json.JSONException;

/**
 * The app's calendar and schedule (src/app/android.ts): the calendar permission (the app asks at
 * first use), the phone's calendar query, and the scheduled sync's times and log.
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

    private void resolveSchedule(PluginCall call) {
        try {
            call.resolve(new JSObject(SyncScheduler.schedule(getContext()).toString()));
        } catch (JSONException e) {
            call.reject("the schedule could not be read", e);
        }
    }
}
