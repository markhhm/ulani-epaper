package io.github.markhhm.paperhue;

import android.app.Activity;
import android.view.WindowManager;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * Keeps the screen on while the web code asks for it (src/keepAwake.ts), so
 * the screen does not lock in the middle of an upload. The flag only applies
 * while the app is in the foreground and needs no permission.
 */
@CapacitorPlugin(name = "ScreenAwake")
public class ScreenAwakePlugin extends Plugin {

    @PluginMethod
    public void keepOn(PluginCall call) {
        setKeepScreenOn(call, true);
    }

    @PluginMethod
    public void allowOff(PluginCall call) {
        setKeepScreenOn(call, false);
    }

    private void setKeepScreenOn(PluginCall call, boolean on) {
        Activity activity = getActivity();
        if (activity == null) {
            call.reject("no activity");
            return;
        }
        activity.runOnUiThread(() -> {
            if (on) {
                activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            } else {
                activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            }
            call.resolve();
        });
    }
}
