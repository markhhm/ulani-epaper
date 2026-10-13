package io.github.markhhm.paperhue;

import android.Manifest;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CalendarContract;
import android.provider.CalendarContract.Instances;
import androidx.core.content.ContextCompat;
import java.util.Locale;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * The phone's own calendars (every account the user has on the phone), read from
 * CalendarContract.Instances in the form src/core/sources.ts takes (PhoneCalendars). Read in
 * memory for one drawing; nothing is kept.
 */
final class PhoneCalendar {

    private PhoneCalendar() {}

    static boolean allowed(Context context) {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED;
    }

    /**
     * {calendars, events: [{title, begin, end, allDay, calendar, location, color}]}: the occurrences
     * overlapping [from, to) (epoch ms) in the calendars the phone shows, cancelled ones left out.
     */
    static JSONObject events(Context context, long from, long to) throws JSONException {
        ContentResolver resolver = context.getContentResolver();
        int calendars = 0;
        try (
            Cursor cursor = resolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                new String[] { CalendarContract.Calendars._ID },
                CalendarContract.Calendars.VISIBLE + " = 1",
                null,
                null
            )
        ) {
            if (cursor != null) calendars = cursor.getCount();
        }
        Uri.Builder uri = Instances.CONTENT_URI.buildUpon();
        ContentUris.appendId(uri, from);
        ContentUris.appendId(uri, to);
        String[] columns = {
            Instances.TITLE,
            Instances.BEGIN,
            Instances.END,
            Instances.ALL_DAY,
            Instances.CALENDAR_DISPLAY_NAME,
            Instances.EVENT_LOCATION,
            Instances.DISPLAY_COLOR,
        };
        String shown =
            Instances.VISIBLE + " = 1 AND (" + Instances.STATUS + " IS NULL OR " + Instances.STATUS + " != " + Instances.STATUS_CANCELED + ")";
        JSONArray events = new JSONArray();
        try (Cursor cursor = resolver.query(uri.build(), columns, shown, null, Instances.BEGIN + " ASC")) {
            while (cursor != null && cursor.moveToNext()) {
                events.put(
                    new JSONObject()
                        .put("title", text(cursor, 0))
                        .put("begin", cursor.getLong(1))
                        .put("end", cursor.getLong(2))
                        .put("allDay", cursor.getInt(3) == 1)
                        .put("calendar", text(cursor, 4))
                        .put("location", text(cursor, 5))
                        .put("color", cursor.isNull(6) ? "" : String.format(Locale.ROOT, "#%06x", cursor.getInt(6) & 0xFFFFFF))
                );
            }
        }
        return new JSONObject().put("calendars", calendars).put("events", events);
    }

    private static String text(Cursor cursor, int column) {
        String value = cursor.getString(column);
        return value == null ? "" : value;
    }
}
