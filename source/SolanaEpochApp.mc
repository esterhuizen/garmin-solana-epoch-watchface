//! Solana epoch watch face - application entry point.
//!
//! The whole class is annotated (:background) because the background service lives in
//! the same app: Connect IQ loads this Application class in the background process too,
//! so anything it touches has to be legal there. Calls into WatchUi are therefore routed
//! through the (:typecheck(disableBackgroundCheck)) helper at the bottom of this file -
//! WatchUi.requestUpdate() is marked disableBackgroundBeforeVersion="5.1.0" in the API
//! and the fenix 6 family is on 3.4.5.

import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Background;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! Storage keys, tuning constants, palette, settings accessors and the shared state
//! reader. Annotated (:background) because BackgroundService reads RpcUrl through it and
//! because the (:background) Application class calls into it.
(:background)
module Se {

    // ---- Application.Storage keys -------------------------------------------------
    // Two keys only. Everything the face draws lives in one Dictionary under KEY_STATE,
    // written with a single setValue() so it can never half-update: a new `epoch` paired
    // with an old `fetchTs` reads as a huge `elapsed` in the view and an inflated
    // `timeDelta` in the calibrator. The error code keeps its own key because it is
    // written on a different path (a failed fetch leaves the last good state alone).
    const KEY_STATE = "state";
    const KEY_ERR = "err";

    // ---- Field names inside the state Dictionary ----------------------------------
    // The background process puts these same names in the Background.exit() payload, so
    // the payload fields and the stored fields are deliberately identical.
    const F_EPOCH = "epoch";
    const F_SLOT_INDEX = "slotIndex";
    const F_SLOTS_IN_EPOCH = "slotsInEpoch";
    const F_FETCH_TS = "fetchTs";
    const F_SLOT_SECS = "slotSecs";

    // ---- Application.Properties keys ---------------------------------------------
    const PROP_RPC_URL = "RpcUrl";
    const PROP_REFRESH_MINUTES = "RefreshMinutes";
    const PROP_ACCENT_COLOR = "AccentColor";

    const DEFAULT_RPC_URL = "https://api.mainnet-beta.solana.com";

    // Anything below 5 minutes throws Background.InvalidBackgroundTimeException. The
    // upper clamp matters too: RefreshMinutes is untrusted input from the same source as
    // RpcUrl, and a huge value overflows refreshSecs * 3 in the view's staleness check
    // into a negative, which pins the stale marker on permanently.
    const MIN_REFRESH_MINUTES = 5;
    const MAX_REFRESH_MINUTES = 240;
    const DEFAULT_REFRESH_MINUTES = 15;

    // ---- Slot-time calibration ----------------------------------------------------
    // The only seed there is. Mainnet's target moved to 350 ms (SIMD-0525) and the
    // measured rate on 2026-09-18 was 0.3145 s/slot; the epoch-delta calibration in
    // onBackgroundData() takes over from the second delivery onwards.
    const DEFAULT_SLOT_SECS = 0.315;
    // Plausibility window for any measured or stored slot time. Deliberately wide rather
    // than tight around today's 0.315: Solana has already gone 400 -> 350 ms and publicly
    // targets 200 ms, so a tight band would reject a real future slot-time cut. The band
    // only has to catch absurd values.
    const MIN_SLOT_SECS = 0.08;
    const MAX_SLOT_SECS = 1.5;
    // A measurement needs this many slots and this many seconds of separation to count.
    // 240 s rather than 60: over a minute-long window the one-second quantisation of the
    // two timestamps dominates the quotient. It cannot go to 600 either, because the
    // minimum refresh setting is 5 minutes and a 600 s floor would reject every
    // measurement at that setting, leaving the face permanently uncalibrated.
    const MIN_SLOT_DELTA = 300;
    const MIN_TIME_DELTA = 240;
    // Bounds that together keep the calibration multiply
    // (newEpoch - oldEpoch) * slotsInEpoch + slotIndex inside a 32-bit signed Number.
    // Worst case 1000 * 2000000 + 2000000 = 2.002e9 < 2.147e9. Mainnet slotsInEpoch is
    // 432000, but RpcUrl is user-settable so the response is untrusted input.
    const MAX_EPOCH_DELTA = 1000;
    const MAX_SLOTS_IN_EPOCH = 2000000;

    // ---- Palette ------------------------------------------------------------------
    // Every value is an exact entry of the fenix 6 64-colour palette (components drawn
    // from 00/55/AA/FF) so nothing dithers on the MIP display.
    // Night (19:00-07:00): black field, white type.
    const COLOR_BG = 0x000000;
    const COLOR_PRIMARY = 0xFFFFFF;
    const COLOR_SECONDARY = 0xAAAAAA;
    const COLOR_TRACK = 0x555555;
    const COLOR_WARNING = 0xFFAA00;
    // Day (07:00-19:00): white field, black type. MIP is reflective, so a light
    // face is the one that stays readable outdoors. Warning is 0xFF5500 rather
    // than 0xFFAA00 so it still reads on white.
    const COLOR_DAY_BG = 0xFFFFFF;
    const COLOR_DAY_PRIMARY = 0x000000;
    const COLOR_DAY_SECONDARY = 0x555555;
    const COLOR_DAY_TRACK = 0xAAAAAA;
    const COLOR_DAY_WARNING = 0xFF5500;
    // Nearest palette entry to Solana purple 0x9945FF.
    const DEFAULT_ACCENT = 0xAA55FF;

    // ---- Error codes we invent ------------------------------------------------------
    // Fallback for an HTTP 200 whose body carries neither a usable `result` nor a numeric
    // JSON-RPC `error.code` - the captive-portal case. Real codes never collide with 1:
    // JSON-RPC uses -32768..-32000, Connect IQ transport uses -101/-300/-400/-402/-403
    // and HTTP uses 1xx..5xx.
    const ERR_BAD_BODY = 1;

    //! Bumped whenever the stored state or the settings change, so the view knows its
    //! cached copy is stale. Foreground only: onBackgroundData() and onSettingsChanged()
    //! both run in the main process, and the background process has its own VM.
    var stateVersion as Number = 0;

    //! Read an application property, tolerating an absent key.
    //!
    //! Properties.getValue() throws InvalidKeyException when the key is not in the
    //! settings XML (api.mir documents it). Two of the callers below are on the
    //! onUpdate() path, where an uncaught throw kills the face.
    //! @param key One of the PROP_* keys
    //! @return The stored value, or null if it is missing or unreadable
    public function propertyValue(key as String) as Object? {
        var value = null as Object?;
        try {
            value = Properties.getValue(key);
        } catch (ex instanceof Properties.InvalidKeyException) {
            // Key absent from the settings XML; the caller's default applies.
        }
        return value;
    }

    //! Configured RPC endpoint.
    //! @return The endpoint URL, or the mainnet-beta default if the setting is unusable
    public function rpcUrl() as String {
        var value = propertyValue(PROP_RPC_URL);
        if (value instanceof String && (value as String).length() > 0) {
            return value as String;
        }
        return DEFAULT_RPC_URL;
    }

    //! Configured refresh interval, clamped to the platform minimum and a sane maximum.
    //! @return Refresh interval in minutes
    public function refreshMinutes() as Number {
        var minutes = numberOr(propertyValue(PROP_REFRESH_MINUTES), DEFAULT_REFRESH_MINUTES);
        if (minutes < MIN_REFRESH_MINUTES) {
            minutes = MIN_REFRESH_MINUTES;
        } else if (minutes > MAX_REFRESH_MINUTES) {
            minutes = MAX_REFRESH_MINUTES;
        }
        return minutes;
    }

    //! Configured accent colour.
    //! @return A palette colour for the progress arc and the epoch label
    public function accentColor() as Number {
        return numberOr(propertyValue(PROP_ACCENT_COLOR), DEFAULT_ACCENT);
    }

    //! Coerce a Storage/Properties value to a 32-bit Number.
    //! Long and Double are rejected rather than truncated: nothing this face stores
    //! needs more than 32 bits, so a wide value means the store is corrupt.
    //! @param value The value read back from Storage or Properties
    //! @param fallback Value to use when the read is missing or of the wrong type
    //! @return The coerced Number
    public function numberOr(value as Object?, fallback as Number) as Number {
        if (value instanceof Number) {
            return value as Number;
        }
        if (value instanceof Float) {
            return (value as Float).toNumber();
        }
        return fallback;
    }

    //! Coerce a Storage value to a Float inside the plausible slot-time window.
    //! @param value The value read back from Storage
    //! @param fallback Value to use when the read is missing, wrongly typed or implausible
    //! @return The coerced Float
    public function slotSecsOr(value as Object?, fallback as Float) as Float {
        var secs = fallback;
        if (value instanceof Float) {
            secs = value as Float;
        } else if (value instanceof Number) {
            secs = (value as Number).toFloat();
        }
        if (secs < MIN_SLOT_SECS || secs > MAX_SLOT_SECS) {
            secs = fallback;
        }
        return secs;
    }

    //! Read the stored face state and validate it as a whole.
    //!
    //! All-or-nothing on purpose: a state Dictionary with any field missing, wrongly
    //! typed or out of range is treated as no data at all, so the face admits it has
    //! nothing rather than rendering a confident-looking 0.0%. This is the only place
    //! those per-field checks live.
    //! @return The validated state Dictionary, or null when there is no usable state
    public function readState() as Dictionary? {
        var stored = Storage.getValue(KEY_STATE);
        if (!(stored instanceof Dictionary)) {
            return null;
        }
        var state = stored as Dictionary;

        var epoch = state.get(F_EPOCH);
        var slotIndex = state.get(F_SLOT_INDEX);
        var slotsInEpoch = state.get(F_SLOTS_IN_EPOCH);
        var fetchTs = state.get(F_FETCH_TS);
        var slotSecs = state.get(F_SLOT_SECS);

        // Kept as short separate statements rather than one long && chain: the 9.2.0
        // type checker runs out of heap combining substitutions across a chain this long.
        var ok = (epoch instanceof Number) && (slotIndex instanceof Number);
        if (ok && !(slotsInEpoch instanceof Number)) {
            ok = false;
        }
        if (ok && !(fetchTs instanceof Number)) {
            ok = false;
        }
        if (ok && !(slotSecs instanceof Float)) {
            ok = false;
        }
        if (!ok) {
            return null;
        }

        var slots = slotsInEpoch as Number;
        var index = slotIndex as Number;
        if (slots <= 0 || slots > MAX_SLOTS_IN_EPOCH) {
            return null;
        }
        if (index < 0 || index > slots) {
            return null;
        }
        if ((epoch as Number) < 0 || (fetchTs as Number) <= 0) {
            return null;
        }
        var secs = slotSecs as Float;
        if (secs < MIN_SLOT_SECS || secs > MAX_SLOT_SECS) {
            return null;
        }
        return state;
    }

    //! Register the repeating temporal event.
    //!
    //! A Duration, not a Moment: a Duration is interval-counted by the system, so a
    //! clock jump cannot defer it and it can never decay into a stale past Moment the
    //! way a computed absolute time can. registerForTemporalEvent() takes either
    //! (Background.html, since 2.3.0) and the SDK's own samples/Notifications registers
    //! a Duration straight from onStart().
    //!
    //! Only one temporal event may exist at a time and registering overwrites the
    //! previous one. That is why the callers matter: onTemporalEvent() and
    //! onSettingsChanged() call this, but onStart() does NOT - re-arming a repeating
    //! Duration restarts its interval countdown, so an onStart() on every wrist raise
    //! would starve the event forever.
    public function scheduleRepeating() as Void {
        try {
            Background.registerForTemporalEvent(new Time.Duration(refreshMinutes() * 60));
        } catch (ex instanceof Background.InvalidBackgroundTimeException) {
            // The documented throws are "occurs less than five minutes after the last
            // temporal event" and "has a duration of less than five minutes".
            // refreshMinutes() is clamped to >= 5, so neither applies; swallowed only so
            // that a failed registration can never propagate out of a background
            // callback or out of onSettingsChanged().
        }
    }

    //! Arm the schedule from onStart(), if and only if nothing is armed yet.
    //!
    //! Connect IQ loads this Application class in the background process too, so
    //! onStart() runs at the start of every temporal-event process as well as on every
    //! foreground start. The "only if nothing is registered" guard is what keeps those
    //! frequent calls from restarting the Duration's interval countdown.
    //!
    //! A fresh install has no stored state, so it gets a Moment of Time.now() - a
    //! past-or-present Moment triggers immediately - rather than staring at a blank face
    //! for a whole interval. onTemporalEvent() then promotes that one-shot onto the
    //! repeating Duration. This is the only place a past Moment is used deliberately.
    public function scheduleInitialEvent() as Void {
        if (Background.getTemporalEventRegisteredTime() != null) {
            return;
        }
        if (readState() != null) {
            scheduleRepeating();
            return;
        }
        try {
            Background.registerForTemporalEvent(Time.now());
        } catch (ex instanceof Background.InvalidBackgroundTimeException) {
            // Fewer than five minutes since the last temporal event fired. Fall back to
            // the repeating interval, which is always at least the 5 minute minimum.
            scheduleRepeating();
        }
    }
}

(:background)
class SolanaEpochApp extends Application.AppBase {

    //! Constructor
    public function initialize() {
        AppBase.initialize();
    }

    //! Handle app startup.
    //! @param state Startup arguments
    public function onStart(state as Dictionary?) as Void {
        $.Se.scheduleInitialEvent();
    }

    //! Handle app shutdown.
    //! @param state Shutdown arguments
    public function onStop(state as Dictionary?) as Void {
    }

    //! Return the initial view for the watch face.
    //!
    //! disableBackgroundCheck because this class is (:background) and SolanaEpochView is
    //! not: the view draws, and Graphics is unavailable to a background process before
    //! CIQ 5.1.0. getInitialView() is only ever called in the foreground process.
    //! @return An array holding the watch face view
    (:typecheck(disableBackgroundCheck))
    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new $.SolanaEpochView()];
    }

    //! Return the background service delegate.
    //! @return An array holding the single service delegate
    public function getServiceDelegate() as [ServiceDelegate] {
        return [new $.BackgroundService()];
    }

    //! Re-read settings when they change in Garmin Connect Mobile.
    public function onSettingsChanged() as Void {
        // RefreshMinutes may have changed, so re-arm unconditionally: this is a rare,
        // user-driven event, not something that fires on every wrist raise, so
        // restarting the interval countdown here is exactly what we want.
        $.Se.scheduleRepeating();
        $.Se.stateVersion += 1;
        $.requestFaceUpdate();
    }

    //! Handle the payload handed over by the background service.
    //!
    //! Runs immediately when the face is active, otherwise the payload is cached by the
    //! system and delivered right after the next onStart(). This is the only writer of
    //! Application.Storage, and the only place slot-time calibration happens.
    //!
    //! Nothing is rescheduled from here. The repeating Duration registered at the top of
    //! onTemporalEvent() keeps itself alive, so there is no chain to maintain.
    //! @param data The Dictionary passed to Background.exit()
    public function onBackgroundData(data as PersistableType) as Void {
        if (!(data instanceof Dictionary)) {
            return;
        }
        var payload = data as Dictionary;

        var errValue = payload.get($.Se.KEY_ERR);
        if (errValue instanceof Number) {
            // Keep the last good epoch numbers; the view will mark them stale on its own.
            Storage.setValue($.Se.KEY_ERR, errValue as Number);
            $.Se.stateVersion += 1;
            $.requestFaceUpdate();
            return;
        }

        var epochValue = payload.get($.Se.F_EPOCH);
        var slotIndexValue = payload.get($.Se.F_SLOT_INDEX);
        var slotsInEpochValue = payload.get($.Se.F_SLOTS_IN_EPOCH);
        if (!(epochValue instanceof Number) || !(slotIndexValue instanceof Number)
                || !(slotsInEpochValue instanceof Number)) {
            return;
        }
        var epoch = epochValue as Number;
        var slotIndex = slotIndexValue as Number;
        var slotsInEpoch = slotsInEpochValue as Number;
        if (slotsInEpoch <= 0 || slotsInEpoch > $.Se.MAX_SLOTS_IN_EPOCH
                || slotIndex < 0 || slotIndex > slotsInEpoch) {
            return;
        }

        // Prefer the timestamp the background process took at fetch time. Delivery can
        // lag the fetch by minutes whenever the face was not active, so Time.now() here
        // is only a fallback - and a future-dated payload (clock moved backwards since
        // the fetch) falls back too.
        var nowTs = Time.now().value();
        var fetchTsValue = payload.get($.Se.F_FETCH_TS);
        if (fetchTsValue instanceof Number) {
            var stamped = fetchTsValue as Number;
            if (stamped > 0 && stamped <= nowTs) {
                nowTs = stamped;
            }
        }
        // Must happen before the new state is written: it measures against the old one.
        var slotSecs = calibrate(epoch, slotIndex, slotsInEpoch, nowTs);

        // One setValue, so the five fields can never be observed half-updated.
        var state = {} as Dictionary<Storage.KeyType, Storage.ValueType>;
        state.put($.Se.F_EPOCH, epoch);
        state.put($.Se.F_SLOT_INDEX, slotIndex);
        state.put($.Se.F_SLOTS_IN_EPOCH, slotsInEpoch);
        state.put($.Se.F_FETCH_TS, nowTs);
        state.put($.Se.F_SLOT_SECS, slotSecs);
        Storage.setValue($.Se.KEY_STATE, state);
        Storage.deleteValue($.Se.KEY_ERR);

        $.Se.stateVersion += 1;
        $.requestFaceUpdate();
    }

    //! Work out the slot time to store, from the previous sample if we have one.
    //!
    //! Must run before the new state overwrites the old one.
    //! @param epoch Epoch number just fetched
    //! @param slotIndex Slot index just fetched
    //! @param slotsInEpoch Slots per epoch just fetched
    //! @param nowTs Timestamp the background process took at fetch time
    //! @return Seconds per slot to store
    private function calibrate(epoch as Number, slotIndex as Number, slotsInEpoch as Number,
            nowTs as Number) as Float {
        var previous = $.Se.readState();
        if (previous == null) {
            // First ever delivery, or a store we could not validate. There is no seeding
            // request any more (see BackgroundService): the constant is the only seed and
            // the epoch-delta measurement below takes over on the next cycle.
            return $.Se.DEFAULT_SLOT_SECS;
        }
        var old = previous as Dictionary;

        // readState() has already validated every field, so these coercions cannot fail.
        var slotSecs = $.Se.slotSecsOr(old.get($.Se.F_SLOT_SECS), $.Se.DEFAULT_SLOT_SECS);
        var oldEpoch = $.Se.numberOr(old.get($.Se.F_EPOCH), epoch);
        var oldIndex = $.Se.numberOr(old.get($.Se.F_SLOT_INDEX), slotIndex);
        var oldTs = $.Se.numberOr(old.get($.Se.F_FETCH_TS), nowTs);

        var epochDelta = epoch - oldEpoch;
        if (epochDelta < 0 || epochDelta > $.Se.MAX_EPOCH_DELTA) {
            // Epoch went backwards, or the stored epoch is nonsense. Either way the
            // multiply below would be meaningless (and could overflow 32 bits).
            return slotSecs;
        }

        var slotDelta = epochDelta * slotsInEpoch + (slotIndex - oldIndex);
        var timeDelta = nowTs - oldTs;
        if (slotDelta <= $.Se.MIN_SLOT_DELTA || timeDelta <= $.Se.MIN_TIME_DELTA) {
            return slotSecs;
        }

        var measured = timeDelta.toFloat() / slotDelta;
        if (measured < $.Se.MIN_SLOT_SECS || measured > $.Se.MAX_SLOT_SECS) {
            // Clock change, epoch rollover glitch, bad sample. Keep the old estimate.
            return slotSecs;
        }
        // Any in-band measurement is accepted and smoothed 0.5/0.5, which is what makes
        // convergence from any starting state guaranteed. Long offline gaps are fine:
        // the average over a long window is still an average.
        return 0.5 * slotSecs + 0.5 * measured;
    }
}

//! Ask the face to redraw.
//!
//! Pulled out of the (:background) app class and marked disableBackgroundCheck because
//! WatchUi.requestUpdate() is not available to a background process before CIQ 5.1.0 and
//! the fenix 6 family is on 3.4.5. It is only ever reached on the foreground side:
//! onBackgroundData() and onSettingsChanged() both run in the main process.
(:typecheck(disableBackgroundCheck))
function requestFaceUpdate() as Void {
    WatchUi.requestUpdate();
}
