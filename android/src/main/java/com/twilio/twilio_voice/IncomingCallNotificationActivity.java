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
        Intent newIntent = new Intent(getApplicationContext(), IncomingCallNotificationService.class);
        newIntent.putExtras(srcIntent);
        startService(newIntent);
        finish();
    }
}