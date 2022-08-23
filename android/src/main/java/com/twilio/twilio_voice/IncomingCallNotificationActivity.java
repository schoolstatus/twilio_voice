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

        Log.d(TAG, "startForegroundService");
        startForegroundService(newIntent);

        Log.d(TAG, "Finish");
        finish();
    }
}