package io.github.markhhm.paperhue;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.PowerManager;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.TimeZone;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The scheduled sync: the times the user chose (none by default: off), the one alarm that starts
 * the next run (SyncAlarmReceiver, then SyncService), the retries when the device was not found
 * (every 15 minutes for up to 2 hours after the chosen time, then the time is skipped) and a short
 * log of the runs, which the app shows (src/app/ui/AndroidView.tsx). Nothing here holds calendar
 * content: a run's result only says what was sent.
 */
final class SyncScheduler {

    static final long RETRY_MS = 15 * 60_000L;
    static final long RETRY_FOR_MS = 2 * 60 * 60_000L;
    private static final int MAX_RUNS = 20;
    private static final String PREFS = "paperhue.sync";
    private static final String TIMES = "times";
    private static final String RUNS = "runs";
    private static final String RETRY_AT = "retryAt";
    private static final String LOCALE = "locale";
    private static final String BATTERY_ASKED = "batteryAsked";

    private SyncScheduler() {}

    // --- The rules (plain Java, unit-tested) ---------------------------------------------------

    /** When to run next: the next chosen time after `now`, or a pending retry before it; -1 without times. */
    static long nextRun(List<String> times, long now, TimeZone zone, long retryAt) {
        long next = -1;
        for (String time : times) {
            for (int day = 0; day <= 1; day++) {
                long at = timeOn(now, day, time, zone);
                if (at > now && (next < 0 || at < next)) next = at;
            }
        }
        if (next >= 0 && retryAt > now && retryAt < next) next = retryAt;
        return next;
    }

    /** The chosen time a run at `now` belongs to: the latest one at or before it; -1 without times. */
    static long lastScheduled(List<String> times, long now, TimeZone zone) {
        long last = -1;
        for (String time : times) {
            for (int day = -1; day <= 0; day++) {
                long at = timeOn(now, day, time, zone);
                if (at <= now && at > last) last = at;
            }
        }
        return last;
    }

    /** After a run at `startedAt` did not find the device: the next quarter hour after `scheduled`, or -1 after 2 hours. */
    static long retryAt(long startedAt, long scheduled) {
        if (scheduled < 0) return -1;
        long next = scheduled + RETRY_MS * ((startedAt - scheduled) / RETRY_MS + 1);
        return next <= scheduled + RETRY_FOR_MS ? next : -1;
    }

    /** "HH:MM" on the day `dayOffset` days from the day of `reference`, in `zone`. */
    private static long timeOn(long reference, int dayOffset, String time, TimeZone zone) {
        Calendar calendar = Calendar.getInstance(zone);
        calendar.setTimeInMillis(reference);
        calendar.add(Calendar.DAY_OF_MONTH, dayOffset);
        calendar.set(Calendar.HOUR_OF_DAY, Integer.parseInt(time.substring(0, 2)));
        calendar.set(Calendar.MINUTE, Integer.parseInt(time.substring(3, 5)));
        calendar.set(Calendar.SECOND, 0);
        calendar.set(Calendar.MILLISECOND, 0);
        return calendar.getTimeInMillis();
    }

    // --- Stored state ----------------------------------------------------------------------------

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static List<String> times(Context context) {
        List<String> times = new ArrayList<>();
        try {
            JSONArray list = new JSONArray(prefs(context).getString(TIMES, "[]"));
            for (int i = 0; i < list.length(); i++) {
                String time = list.getString(i);
                if (time.matches("([01]\\d|2[0-3]):[0-5]\\d")) times.add(time);
            }
        } catch (JSONException e) {
            // no valid times: off
        }
        return times;
    }

    /** Keep the chosen times (sorted "HH:MM"; empty: off) and plan the next run. */
    static void setTimes(Context context, List<String> times, String locale) {
        SharedPreferences.Editor edit = prefs(context).edit().putString(TIMES, new JSONArray(times).toString()).putString(LOCALE, locale);
        if (times.isEmpty()) edit.remove(RETRY_AT);
        edit.apply();
        plan(context);
    }

    static boolean chinese(Context context) {
        return prefs(context).getString(LOCALE, "en").startsWith("zh");
    }

    /** True once: the first time the user may be asked to exempt the app from battery optimisation. */
    static boolean firstBatteryQuestion(Context context) {
        if (!batteryOptimized(context) || prefs(context).getBoolean(BATTERY_ASKED, false)) return false;
        prefs(context).edit().putBoolean(BATTERY_ASKED, true).apply();
        return true;
    }

    static boolean batteryOptimized(Context context) {
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        return power != null && !power.isIgnoringBatteryOptimizations(context.getPackageName());
    }

    /** What the app shows: {times, runs (newest first), batteryOptimized}. */
    static JSONObject schedule(Context context) throws JSONException {
        return new JSONObject()
            .put("times", new JSONArray(times(context)))
            .put("runs", new JSONArray(prefs(context).getString(RUNS, "[]")))
            .put("batteryOptimized", batteryOptimized(context));
    }

    /**
     * Log a run that started at `startedAt` with the background page's result (JSON, see
     * src/background/sync.ts), plan a retry when the device was not found, then the next run.
     */
    static void recordRun(Context context, long startedAt, String resultJson) {
        SharedPreferences prefs = prefs(context);
        SharedPreferences.Editor edit = prefs.edit().remove(RETRY_AT);
        try {
            JSONObject result;
            try {
                result = new JSONObject(resultJson);
            } catch (JSONException e) {
                result = new JSONObject().put("outcome", "error").put("message", "no readable result");
            }
            JSONObject run = new JSONObject().put("at", startedAt).put("result", result);
            if ("notFound".equals(result.optString("outcome"))) {
                long retry = retryAt(startedAt, lastScheduled(times(context), startedAt, TimeZone.getDefault()));
                if (retry > 0) {
                    run.put("retryAt", retry);
                    edit.putLong(RETRY_AT, retry);
                } else {
                    run.put("gaveUp", true);
                }
            }
            JSONArray old = new JSONArray(prefs.getString(RUNS, "[]"));
            JSONArray runs = new JSONArray().put(run);
            for (int i = 0; i < old.length() && runs.length() < MAX_RUNS; i++) runs.put(old.get(i));
            edit.putString(RUNS, runs.toString());
        } catch (JSONException e) {
            edit.remove(RUNS);
        }
        edit.commit();
        plan(context);
    }

    /** Set (or cancel) the one alarm for the next run. */
    static void plan(Context context) {
        long next = nextRun(times(context), System.currentTimeMillis(), TimeZone.getDefault(), prefs(context).getLong(RETRY_AT, 0));
        AlarmManager alarms = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (alarms == null) return;
        Intent intent = new Intent(context, SyncAlarmReceiver.class);
        PendingIntent pending = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        if (next < 0) {
            alarms.cancel(pending);
        } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending);
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending);
        }
    }
}
