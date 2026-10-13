package io.github.markhhm.paperhue;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import androidx.core.content.ContextCompat;
import org.json.JSONException;
import org.json.JSONObject;

/** The scheduled sync's alarm went off: plan the next one, then start the run (SyncService), which Android allows from an exact alarm. */
public class SyncAlarmReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        // Plan the next time first: the run may die before it can (the page's renderer crashes, Android
        // needs the memory), and without another alarm the scheduled syncs would silently stop.
        SyncScheduler.plan(context);
        try {
            ContextCompat.startForegroundService(context, new Intent(context, SyncService.class));
        } catch (RuntimeException refused) {
            // Android did not let the run start in the background: log it and plan the next one.
            String result = "";
            try {
                result = new JSONObject()
                    .put("outcome", "error")
                    .put("message", "Android did not let the sync start in the background (" + refused.getClass().getSimpleName() + ")")
                    .toString();
            } catch (JSONException e) {
                // logged as "no readable result"
            }
            SyncScheduler.recordRun(context, System.currentTimeMillis(), result);
        }
    }
}
