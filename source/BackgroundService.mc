//! Solana epoch watch face - background service.
//!
//! A watch face cannot do foreground HTTP, so all network access happens here. The
//! process is started by the temporal event, makes ONE JSON-RPC POST, and must reach
//! Background.exit() before the OS force-kills it at 30 s.
//!
//! Invariant: **one HTTP request per background process, ever.** There used to be a
//! chained getRecentPerformanceSamples request behind getEpochInfo to seed the slot-time
//! calibration. It bought about 0.16% accuracy for the first 30 minutes - roughly 12
//! seconds on a two-day epoch - in exchange for a permanent-failure mode: the flag that
//! decided whether to chain was derived from Storage, which only the FOREGROUND writes,
//! so if the two-request cycle never reached Background.exit() nothing was stored and
//! every later cycle chained and failed identically, forever. Se.DEFAULT_SLOT_SECS is now
//! the only seed and the epoch-delta calibration takes over on the second cycle.
//!
//! Only epoch, slotIndex and slotsInEpoch are parsed out of getEpochInfo. absoluteSlot
//! is derivable as epoch * slotsInEpoch + slotIndex and is not needed; transactionCount
//! (~5.5e11) and blockHeight do not fit Monkey C's 32-bit signed Number and are never
//! touched. JSON-RPC batching is not an option either: a batch is a top-level array and
//! makeWebRequest serialises a Dictionary, so one method per request it is.
//!
//! The class-level (:background) annotation is the whole guarantee: it makes the compiler
//! verify, at -l 3, that everything reachable from the background process is legal there.
//! Per-method annotations are not a thing - no such annotation exists anywhere in the
//! SDK 9.2.0 tree, and the SDK's own BackgroundTimer sample marks only the class.

import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

(:background)
class BackgroundService extends System.ServiceDelegate {

    // getEpochInfo results, held between the callback and Background.exit().
    private var _epoch as Number = 0;
    private var _slotIndex as Number = 0;
    private var _slotsInEpoch as Number = 0;

    //! Constructor
    public function initialize() {
        ServiceDelegate.initialize();
    }

    //! Temporal event entry point.
    public function onTemporalEvent() as Void {
        // Register the repeating interval first. This is what promotes the one-shot
        // Moment that a fresh install arms in onStart() onto the repeating schedule, and
        // it also means that if the request below hangs and the OS kills this process at
        // 30 s, the schedule is already safe. Registering a Duration of 5 minutes or more
        // satisfies both documented throws.
        $.Se.scheduleRepeating();

        Communications.makeWebRequest(
            $.Se.rpcUrl(),
            {
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "getEpochInfo"
            },
            {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onEpochInfo));
    }

    //! getEpochInfo response handler. Always ends in an exit.
    //!
    //! Known negative responseCodes: -101 BLE host timeout, -300 request timed out,
    //! -400 invalid HTTP body, -402 response too large, -403 response out of memory.
    //! @param responseCode HTTP status, or a negative Connect IQ transport error
    //! @param data Parsed JSON body
    public function onEpochInfo(responseCode as Number, data as Dictionary or String or Null) as Void {
        if (responseCode != 200) {
            exitWithError(responseCode);
            return;
        }

        var result = null as Dictionary?;
        if (data instanceof Dictionary) {
            var value = (data as Dictionary).get("result");
            if (value instanceof Dictionary) {
                result = value as Dictionary;
            }
        }
        if (result == null) {
            // 200 with no usable result: a JSON-RPC error object, or an intercepting
            // proxy. Pass the server's own error code through when there is one.
            exitWithError(rpcErrorCode(data));
            return;
        }

        var epoch = numberFrom((result as Dictionary).get("epoch"));
        var slotIndex = numberFrom((result as Dictionary).get("slotIndex"));
        var slotsInEpoch = numberFrom((result as Dictionary).get("slotsInEpoch"));
        if (epoch == null || slotIndex == null || slotsInEpoch == null) {
            exitWithError($.Se.ERR_BAD_BODY);
            return;
        }
        _epoch = epoch as Number;
        _slotIndex = slotIndex as Number;
        _slotsInEpoch = slotsInEpoch as Number;
        // RpcUrl is user-settable, so slotsInEpoch is untrusted input. Bounding it here
        // is what keeps the calibration multiply in the app from overflowing 32 bits.
        if (_slotsInEpoch <= 0 || _slotsInEpoch > $.Se.MAX_SLOTS_IN_EPOCH
                || _slotIndex < 0 || _slotIndex > _slotsInEpoch) {
            exitWithError($.Se.ERR_BAD_BODY);
            return;
        }

        exitWithEpoch();
    }

    //! Hand the epoch position to the foreground and terminate.
    private function exitWithEpoch() as Void {
        // Kept deliberately tiny: Background.exit() throws ExitDataSizeLimitException
        // above ~8 KB and then does not exit at all. Raw sample arrays and
        // transactionCount never go in here.
        var payload = {} as Dictionary<PropertyKeyType, PropertyValueType>;
        payload.put($.Se.F_EPOCH, _epoch);
        payload.put($.Se.F_SLOT_INDEX, _slotIndex);
        payload.put($.Se.F_SLOTS_IN_EPOCH, _slotsInEpoch);
        // Stamp the fetch time HERE, not in onBackgroundData(). The payload is only
        // delivered immediately if the watch face is active; otherwise it is cached until
        // after the next onStart(), which on a fenix 6 can be many minutes later (the
        // face is stopped during activities and other apps). Timestamping at delivery
        // would pair a slotIndex from time T with a clock reading from T+delay, which
        // both lags the arc and - worse - poisons the calibration, because the accepted
        // measurement becomes slotSecs * (deliveryDelta / fetchDelta).
        payload.put($.Se.F_FETCH_TS, Time.now().value());
        Background.exit(payload);
    }

    //! Hand an error code to the foreground and terminate.
    //! @param code Response code, JSON-RPC error code, or Se.ERR_BAD_BODY
    private function exitWithError(code as Number) as Void {
        var payload = {} as Dictionary<PropertyKeyType, PropertyValueType>;
        payload.put($.Se.KEY_ERR, code);
        Background.exit(payload);
    }

    //! Pull the JSON-RPC error code out of a 200 response that carried no usable result.
    //!
    //! JSON-RPC codes live in -32768..-32000, so they cannot be confused with the
    //! Connect IQ transport codes or with HTTP statuses, and the view can show them
    //! verbatim.
    //! @param data Parsed JSON body
    //! @return error.code when it is a usable Number, otherwise Se.ERR_BAD_BODY
    private function rpcErrorCode(data as Dictionary or String or Null) as Number {
        if (data instanceof Dictionary) {
            var error = (data as Dictionary).get("error");
            if (error instanceof Dictionary) {
                var code = numberFrom((error as Dictionary).get("code"));
                if (code != null) {
                    return code as Number;
                }
            }
        }
        return $.Se.ERR_BAD_BODY;
    }

    //! Coerce a parsed JSON value to a 32-bit Number.
    //!
    //! Long and Double are rejected rather than truncated. Every field this face reads
    //! (epoch ~1036, slotIndex 0..431999, slotsInEpoch 432000, a JSON-RPC error code)
    //! fits comfortably, so a wide type means the body is not what we expect.
    //! @param value A value out of the parsed response Dictionary
    //! @return The Number, or null if it is absent or not 32-bit safe
    private function numberFrom(value as Object?) as Number? {
        if (value instanceof Number) {
            return value as Number;
        }
        if (value instanceof Float) {
            return (value as Float).toNumber();
        }
        return null;
    }
}
