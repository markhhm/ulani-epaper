package io.github.markhhm.paperhue;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // The app's own plugins must be registered before the bridge starts.
        registerPlugin(ScreenAwakePlugin.class);
        registerPlugin(PaperhuePlugin.class);
        super.onCreate(savedInstanceState);
    }
}
