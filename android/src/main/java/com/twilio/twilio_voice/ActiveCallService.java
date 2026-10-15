package com.twilio.twilio_voice;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Person;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

/*
 * Foreground service (type microphone) held for the whole duration of an active call.
 * Without it Android treats the app as backgrounded once the screen locks, which
 * silences the microphone and lets the process be frozen or killed.
 */
public class ActiveCallService extends Service {

    private static final String TAG = "ActiveCallService";
    private static final String CHANNEL_ID = "notification-channel-active-call";
    private static final int NOTIFICATION_ID = 27400;
    private static final String ACTION_START = "ACTIVE_CALL_START";
    private static final String ACTION_HANG_UP = "ACTIVE_CALL_HANG_UP";
    private static final String EXTRA_DISPLAY_NAME = "DISPLAY_NAME";
    private static final String EXTRA_STARTED_AT = "STARTED_AT";
    private static final long TASK_REMOVED_CLEANUP_DELAY_MS = 5000;

    static void start(Context context, String displayName, long startedAt) {
        Intent intent = new Intent(context, ActiveCallService.class);
        intent.setAction(ACTION_START);
        intent.putExtra(EXTRA_DISPLAY_NAME, displayName);
        intent.putExtra(EXTRA_STARTED_AT, startedAt);
        // Calls are placed/answered while the app is in the foreground, so a plain
        // startService is allowed and avoids the startForegroundService() crash if
        // promotion to the foreground is refused.
        try {
            context.startService(intent);
        } catch (IllegalStateException e) {
            Log.w(TAG, "startService not allowed, falling back to startForegroundService", e);
            try {
                context.startForegroundService(intent);
            } catch (Exception fallbackError) {
                Log.e(TAG, "Unable to start active call service", fallbackError);
            }
        }
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, ActiveCallService.class));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        Log.d(TAG, "onStartCommand " + action);

        if (ACTION_HANG_UP.equals(action)) {
            CallSession.hangUp();
            return START_NOT_STICKY;
        }

        String displayName = intent != null ? intent.getStringExtra(EXTRA_DISPLAY_NAME) : null;
        long startedAt = intent != null ? intent.getLongExtra(EXTRA_STARTED_AT, System.currentTimeMillis()) : System.currentTimeMillis();
        Notification notification = buildNotification(displayName, startedAt);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        } catch (Exception e) {
            Log.e(TAG, "Unable to promote active call service to foreground", e);
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    /*
     * The user swiped the app away from Recents. A new Flutter engine would not know about
     * this call, so end it rather than leave it running with no call screen. The session
     * (and this service) is normally torn down by onDisconnected; keep the process in the
     * foreground until then so the disconnect actually reaches Twilio.
     */
    @Override
    public void onTaskRemoved(Intent rootIntent) {
        super.onTaskRemoved(rootIntent);
        Log.d(TAG, "onTaskRemoved, ending call");
        final long session = CallSession.currentSession();
        CallSession.hangUp();
        new Handler(Looper.getMainLooper()).postDelayed(() -> CallSession.endIfSession(session), TASK_REMOVED_CLEANUP_DELAY_MS);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification buildNotification(String displayName, long startedAt) {
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                getString(R.string.active_call_channel_name), NotificationManager.IMPORTANCE_LOW);
        channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE)).createNotificationChannel(channel);

        String appName = IncomingCallNotificationService.getApplicationName(getApplicationContext());
        String name = displayName == null || displayName.isEmpty() ? appName : displayName;

        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent contentIntent = launchIntent == null ? null : PendingIntent.getActivity(this, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent hangUpIntent = new Intent(this, ActiveCallService.class);
        hangUpIntent.setAction(ACTION_HANG_UP);
        PendingIntent piHangUp = PendingIntent.getService(this, 0, hangUpIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder = new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_phone_call)
                .setContentTitle(name)
                .setContentText(getString(R.string.call_in_progress))
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setWhen(startedAt)
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setContentIntent(contentIntent);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Person caller = new Person.Builder().setName(name).setImportant(true).build();
            builder.setStyle(Notification.CallStyle.forOngoingCall(caller, piHangUp))
                    .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        } else {
            builder.addAction(new Notification.Action.Builder(null, getString(R.string.hang_up), piHangUp).build());
        }
        return builder.build();
    }
}
