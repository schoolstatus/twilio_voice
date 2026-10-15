package com.twilio.twilio_voice;

import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

public class IncomingCallNotificationActivity extends AppCompatActivity {
    private static String TAG = "IncomingCallNotificationActivity";

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.d(TAG, "onCreate");

        Intent srcIntent = getIntent();
        String action = srcIntent.getAction();
        Log.d(TAG, "onCreate " + action);
        Intent newIntent = new Intent(getApplicationContext(), IncomingCallNotificationService.class);
        newIntent.setAction(action);
        newIntent.putExtras(srcIntent);

        // This activity is in the foreground, so a plain startService is allowed. The accept
        // path never calls startForeground(), so startForegroundService() would crash the app
        // if the service was not already in the foreground.
        Log.d(TAG, "startService");
        startService(newIntent);

        Log.d(TAG, "Finish");
        finish();
    }
}