package com.twilio.twilio_voice;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.PowerManager;
import android.util.Log;

import com.twilio.voice.Call;

/*
 * Owns device state for the lifetime of a call, regardless of which listener
 * (TwilioVoicePlugin or AnswerJavaActivity) is driving it:
 *  - ActiveCallService keeps the process in the foreground so the mic is not
 *    silenced and the process is not frozen when the screen locks
 *  - Proximity wake lock turns the screen off when held to the ear
 *  - MODE_IN_COMMUNICATION + audio focus, and speaker routing
 */
public final class CallSession {

    private static final String TAG = "CallSession";

    private static Context appContext;
    private static boolean active = false;
    private static boolean speakerOn = false;
    private static Call call;
    private static long startedAt;
    private static PowerManager.WakeLock proximityWakeLock;
    private static AudioFocusRequest audioFocusRequest;
    private static int savedAudioMode = AudioManager.MODE_INVALID;

    private CallSession() {
    }

    /*
     * Must be called while the app is in the foreground (when the call is placed or
     * answered), otherwise Android will not allow the microphone foreground service.
     */
    public static synchronized void start(Context context, Call newCall, String displayName) {
        call = newCall;
        if (active) {
            return;
        }
        Log.d(TAG, "start");
        appContext = context.getApplicationContext();
        active = true;
        startedAt = System.currentTimeMillis();

        AudioManager audioManager = (AudioManager) appContext.getSystemService(Context.AUDIO_SERVICE);
        savedAudioMode = audioManager.getMode();
        audioFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build())
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(focusChange -> {
                })
                .build();
        audioManager.requestAudioFocus(audioFocusRequest);
        audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
        applySpeakerRoute(audioManager, false);

        acquireProximity();
        ActiveCallService.start(appContext, displayName, startedAt);
    }

    public static synchronized void end() {
        call = null;
        if (!active) {
            return;
        }
        Log.d(TAG, "end");
        active = false;

        releaseProximity();
        ActiveCallService.stop(appContext);

        AudioManager audioManager = (AudioManager) appContext.getSystemService(Context.AUDIO_SERVICE);
        applySpeakerRoute(audioManager, false);
        if (savedAudioMode != AudioManager.MODE_INVALID) {
            audioManager.setMode(savedAudioMode);
        }
        if (audioFocusRequest != null) {
            audioManager.abandonAudioFocusRequest(audioFocusRequest);
            audioFocusRequest = null;
        }
    }

    public static synchronized void hangUp() {
        if (call != null) {
            Log.d(TAG, "hangUp");
            call.disconnect();
        }
    }

    public static synchronized long currentSession() {
        return active ? startedAt : 0;
    }

    public static synchronized void endIfSession(long session) {
        if (active && startedAt == session) {
            Log.w(TAG, "Call did not disconnect in time, forcing cleanup");
            end();
        }
    }

    public static synchronized void setSpeakerOn(Context context, boolean on) {
        AudioManager audioManager = (AudioManager) context.getApplicationContext().getSystemService(Context.AUDIO_SERVICE);
        applySpeakerRoute(audioManager, on);
        if (!active) {
            return;
        }
        // Matches the system dialer: no proximity screen-off while on speaker
        if (on) {
            releaseProximity();
        } else {
            acquireProximity();
        }
    }

    public static synchronized boolean isSpeakerOn() {
        return speakerOn;
    }

    private static void applySpeakerRoute(AudioManager audioManager, boolean on) {
        speakerOn = on;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!on) {
                audioManager.clearCommunicationDevice();
                return;
            }
            for (AudioDeviceInfo device : audioManager.getAvailableCommunicationDevices()) {
                if (device.getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                    audioManager.setCommunicationDevice(device);
                    return;
                }
            }
            Log.w(TAG, "No built-in speaker communication device available");
        } else {
            audioManager.setSpeakerphoneOn(on);
        }
    }

    private static void acquireProximity() {
        if (speakerOn) {
            return;
        }
        if (proximityWakeLock == null) {
            PowerManager powerManager = (PowerManager) appContext.getSystemService(Context.POWER_SERVICE);
            if (!powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                Log.w(TAG, "Proximity wake lock not supported on this device");
                return;
            }
            proximityWakeLock = powerManager.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "twilio_voice:incall");
            proximityWakeLock.setReferenceCounted(false);
        }
        if (!proximityWakeLock.isHeld()) {
            Log.d(TAG, "proximity acquire");
            proximityWakeLock.acquire();
        }
    }

    private static void releaseProximity() {
        if (proximityWakeLock != null && proximityWakeLock.isHeld()) {
            Log.d(TAG, "proximity release");
            // Keep the screen off until the phone is moved away from the ear
            proximityWakeLock.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY);
        }
    }
}
