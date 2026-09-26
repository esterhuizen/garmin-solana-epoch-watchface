//! Solana epoch watch face - the view.
//!
//! One layout for all three fenix 6 screen sizes (240, 260 and 280 px round). Nothing is
//! hardcoded to a pixel count: every coordinate comes off dc.getWidth()/getHeight() and
//! the lower three rows are stacked from measured font heights rather than screen
//! fractions, so no assumed font metric can make two rows collide.
//!
//! Day (07:00-19:00) is a white field with black type and a black Solana mark, because
//! MIP is reflective and a light face is the one that stays readable outdoors. Night
//! keeps the original black field. HR and steps sit in the spare lower third.
//!
//! There is no onPartialUpdate(). The countdown only needs minute resolution, onUpdate()
//! already runs at the top of every minute in low-power mode on this always-on MIP
//! display, and not implementing it removes the whole per-second power-budget risk.
//!
//! Storage and Properties are read once into the cache below, not once per draw:
//! onUpdate() runs about once a second for ten seconds after every wrist raise.

import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Application.Storage;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.SensorHistory;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Weather;

class SolanaEpochView extends WatchUi.WatchFace {

    // ---- Cached state ----------------------------------------------------------------
    // Refreshed in onShow() and whenever Se.stateVersion moves on, which onBackgroundData()
    // and onSettingsChanged() bump. Starts at -1 so the first onUpdate() always refreshes
    // even if onShow() never ran. A stale accent colour for a single draw is harmless.
    private var _cacheVersion as Number = -1;
    private var _accent as Number = $.Se.DEFAULT_ACCENT;
    private var _refreshSecs as Number = $.Se.DEFAULT_REFRESH_MINUTES * 60;
    private var _haveData as Boolean = false;
    private var _epoch as Number = 0;
    private var _slotIndex as Number = 0;
    private var _slotsInEpoch as Number = 0;
    private var _fetchTs as Number = 0;
    private var _slotSecs as Float = $.Se.DEFAULT_SLOT_SECS;
    private var _haveError as Boolean = false;
    private var _errCode as Number = 0;
    private var _markBlack as BitmapResource?;
    private var _markWhite as BitmapResource?;

    //! Constructor
    public function initialize() {
        WatchFace.initialize();
    }

    //! Handle layout. Load the official Solana logomark bitmaps once.
    //! @param dc The drawing context
    public function onLayout(dc as Dc) as Void {
        _markBlack = WatchUi.loadResource(Rez.Drawables.SolanaMarkBlack) as BitmapResource;
        _markWhite = WatchUi.loadResource(Rez.Drawables.SolanaMarkWhite) as BitmapResource;
    }

    //! Called when the face becomes visible.
    public function onShow() as Void {
        refreshCache();
    }

    //! Called when the face is hidden.
    public function onHide() as Void {
    }

    //! Called when the device wakes into high power mode.
    //!
    //! Deliberately empty. The spec asked for a flag to be flipped here, but the face
    //! renders identically in both power modes so nothing would ever read it, and the
    //! compiler correctly flags a write-only member at -l 3. What matters is that these
    //! handlers stay trivial and that onPartialUpdate() is not implemented at all, which
    //! is what keeps this face out of the per-second power budget.
    public function onExitSleep() as Void {
    }

    //! Called when the device drops into low power mode.
    public function onEnterSleep() as Void {
    }

    //! Re-read Storage and Properties into the cache.
    private function refreshCache() as Void {
        _accent = $.Se.accentColor();
        _refreshSecs = $.Se.refreshMinutes() * 60;

        // One validated read of the single state key. readState() returns null unless
        // every field is present, correctly typed and in range.
        var state = $.Se.readState();
        _haveData = (state != null);
        if (state != null) {
            var s = state as Dictionary;
            _epoch = $.Se.numberOr(s.get($.Se.F_EPOCH), 0);
            _slotIndex = $.Se.numberOr(s.get($.Se.F_SLOT_INDEX), 0);
            _slotsInEpoch = $.Se.numberOr(s.get($.Se.F_SLOTS_IN_EPOCH), 0);
            _fetchTs = $.Se.numberOr(s.get($.Se.F_FETCH_TS), 0);
            _slotSecs = $.Se.slotSecsOr(s.get($.Se.F_SLOT_SECS), $.Se.DEFAULT_SLOT_SECS);
        }

        var errValue = Storage.getValue($.Se.KEY_ERR);
        _haveError = (errValue instanceof Number);
        _errCode = $.Se.numberOr(errValue, 0);

        _cacheVersion = $.Se.stateVersion;
    }

    //! Draw the face.
    //! @param dc The drawing context
    public function onUpdate(dc as Dc) as Void {
        if (_cacheVersion != $.Se.stateVersion) {
            refreshCache();
        }

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centreX = width / 2;
        var centreY = height / 2;
        var radius = width / 2 - 5;
        var penWidth = width / 28;
        if (penWidth < 6) {
            penWidth = 6;
        }
        // Gap between the stacked lower rows: 3 px at 240 and 260, 4 px at 280.
        var gap = width / 70;
        if (gap < 3) {
            gap = 3;
        }

        var nowTs = Time.now().value();
        var clockInfo = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var day = isDaytime(clockInfo);
        var bg = day ? $.Se.COLOR_DAY_BG : $.Se.COLOR_BG;
        var primary = day ? $.Se.COLOR_DAY_PRIMARY : $.Se.COLOR_PRIMARY;
        var secondary = day ? $.Se.COLOR_DAY_SECONDARY : $.Se.COLOR_SECONDARY;
        var track = day ? $.Se.COLOR_DAY_TRACK : $.Se.COLOR_TRACK;
        var warning = day ? $.Se.COLOR_DAY_WARNING : $.Se.COLOR_WARNING;

        // ---- Estimated position in the epoch --------------------------------------
        var progress = 0.0;
        var secsLeft = 0.0;
        var rollover = false;
        // Clamped once, here, and reused by the staleness check below so both use the
        // same number. Note this is consistency only, not a fix: after a backwards clock
        // jump the stale indicator stays hidden either way, because a negative delta and
        // a clamped zero are both under the threshold. Detecting that would need a
        // monotonic clock, and CIQ 3.4 exposes none - Time.now() is the system clock.
        var elapsed = nowTs - _fetchTs;
        if (elapsed < 0) {
            // The clock moved backwards since the fetch (time zone or NTP resync).
            elapsed = 0;
        }
        if (_haveData) {
            var estIndex = _slotIndex + (elapsed / _slotSecs);
            if (estIndex >= _slotsInEpoch) {
                // Clamped so secsLeft never goes negative. The real epoch has almost
                // certainly advanced already and we simply have not refetched yet.
                estIndex = _slotsInEpoch.toFloat();
                rollover = true;
            }
            secsLeft = (_slotsInEpoch - estIndex) * _slotSecs;
            progress = estIndex / _slotsInEpoch;
            if (progress < 0.0) {
                progress = 0.0;
            } else if (progress > 1.0) {
                progress = 1.0;
            }
        }

        // ---- Ring -----------------------------------------------------------------
        dc.setColor(bg, bg);
        dc.clear();
        dc.setPenWidth(penWidth);
        dc.setColor(track, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(centreX, centreY, radius);
        // drawArc() truncates every parameter towards zero, so round the sweep here
        // (+ 0.5) instead of losing up to a whole degree on every draw.
        var sweep = (progress * 360.0 + 0.5).toNumber();
        if (sweep >= 360) {
            // Full circle. Also the only safe way to render a sweep that rounds up to
            // 360: drawArc() with equal start and end angles draws a complete circle,
            // so feeding it 90..90 would be indistinguishable from "no progress at all".
            dc.setColor(_accent, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(centreX, centreY, radius);
        } else if (sweep > 0) {
            // 0 degrees is 3 o'clock, so 12 o'clock is 90 and clockwise means counting
            // down from there. sweep is 1..359 here, so the angles can never coincide.
            var endDegree = 90 - sweep;
            if (endDegree < 0) {
                endDegree += 360;
            }
            dc.setColor(_accent, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(centreX, centreY, radius, Graphics.ARC_CLOCKWISE, 90, endDegree);
        }
        dc.setPenWidth(1);

        // ---- Text stack -----------------------------------------------------------
        // Logo sits above the date. Date and clock stay anchored to screen fractions.
        // Everything below the clock is stacked downward from the measured bottom of
        // the clock row, so no assumed font metric can overlap two rows. HR and steps
        // occupy the spare lower third as a two-column row.
        var mark = day ? _markBlack : _markWhite;
        if (mark != null) {
            var bitmap = mark as BitmapResource;
            dc.drawBitmap(
                centreX - bitmap.getWidth() / 2,
                centreY - (height * 0.40).toNumber() - bitmap.getHeight() / 2,
                bitmap);
        }

        drawRow(dc, centreX, centreY - (height * 0.30).toNumber(),
            Graphics.FONT_XTINY, dateString(clockInfo), secondary);

        // FIRST THING TO CHECK ON REAL HARDWARE: the clock's vertical placement.
        // FONT_NUMBER_* glyph boxes are reported to carry more padding above the ascent
        // than getFontHeight() implies, so the digits may sit visibly low inside the row.
        // If they do, nudge this fraction up; the stack below follows automatically.
        var clockCentre = centreY - (height * 0.16).toNumber();
        var clockHeight = Graphics.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        drawRow(dc, centreX, clockCentre, Graphics.FONT_NUMBER_MEDIUM,
            timeString(clockInfo), primary);

        var rowTop = clockCentre + clockHeight / 2 + gap;

        var epochHeight = Graphics.getFontHeight(Graphics.FONT_SMALL);
        drawRow(dc, centreX, rowTop + epochHeight / 2, Graphics.FONT_SMALL,
            _haveData ? "EPOCH " + _epoch.format("%d") : "EPOCH --", _accent);
        rowTop += epochHeight + gap;

        var countdown = "no data";
        if (_haveData) {
            countdown = rollover ? "rollover" : formatCountdown(secsLeft);
        }
        var countdownHeight = Graphics.getFontHeight(Graphics.FONT_TINY);
        drawRow(dc, centreX, rowTop + countdownHeight / 2, Graphics.FONT_TINY,
            countdown, primary);
        rowTop += countdownHeight + gap;

        // ---- Status line ----------------------------------------------------------
        var status = "--";
        var statusColor = secondary;
        if (_haveError) {
            // Shown verbatim: a JSON-RPC error.code (-32768..-32000), a Connect IQ
            // transport code, an HTTP status, or 1 for an unusable body.
            status = "RPC " + _errCode.format("%d");
            statusColor = warning;
        } else if (_haveData) {
            status = (progress * 100.0).format("%.1f") + "%";
        }
        if (_haveData && elapsed > 3 * _refreshSecs) {
            status += " !";
            statusColor = warning;
        }
        if (!System.getDeviceSettings().phoneConnected) {
            status += " x";
        }
        var statusHeight = Graphics.getFontHeight(Graphics.FONT_XTINY);
        drawRow(dc, centreX, rowTop + statusHeight / 2, Graphics.FONT_XTINY,
            status, statusColor);
        rowTop += statusHeight + gap * 2;

        // ---- HR / weather / steps -------------------------------------------------
        // One row, stacked under status (not a second independent Y). Values only:
        // labels on a 280 round collided with the % line. x-offset 0.20 stays inside
        // the inner ring (the old 0.28 columns clipped on the Enduro bezel).
        var valueHeight = Graphics.getFontHeight(Graphics.FONT_SMALL);
        var statsY = rowTop + valueHeight / 2;
        var statsXOff = (width * 0.20).toNumber();
        drawRow(dc, centreX - statsXOff, statsY, Graphics.FONT_SMALL, heartRateText(), primary);
        drawRow(dc, centreX, statsY, Graphics.FONT_SMALL, weatherText(), primary);
        drawRow(dc, centreX + statsXOff, statsY, Graphics.FONT_SMALL, stepCountText(), primary);
    }

    //! Daytime is 07:00-18:59 local. MIP does not emit light, so the white field is for
    //! outdoor contrast, not a flashlight; after 19:00 the original black field returns.
    //! @param info Gregorian info for the current minute
    //! @return true when the light palette should be used
    private function isDaytime(info as Gregorian.Info) as Boolean {
        var hour = info.hour;
        return hour >= 7 && hour < 19;
    }

    //! Latest heart rate, or "--" when the sensor has not produced a sample yet.
    //! Prefers the live Activity value, then the most recent SensorHistory sample.
    //! @return A digits-only string, or "--"
    private function heartRateText() as String {
        var activity = Activity.getActivityInfo();
        if (activity != null && activity.currentHeartRate != null) {
            return (activity.currentHeartRate as Number).format("%d");
        }
        if ((Toybox has :SensorHistory) && (SensorHistory has :getHeartRateHistory)) {
            var iter = SensorHistory.getHeartRateHistory({:period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST});
            if (iter != null) {
                var sample = iter.next();
                if (sample != null && sample.data != null) {
                    return (sample.data as Number).format("%d");
                }
            }
        }
        return "--";
    }

    //! Today's step count from ActivityMonitor.
    //! @return A digits-only string, "0" before the first step
    private function stepCountText() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && info.steps != null) {
            var steps = info.steps as Number;
            if (steps >= 100000) {
                return (steps / 1000).format("%d") + "k";
            }
            return steps.format("%d");
        }
        return "0";
    }

    //! Current temperature from Garmin Connect weather, in the watch's C/F setting.
    //! @return e.g. "18C" / "64F", or "--" when the phone has not delivered weather
    private function weatherText() as String {
        if (!((Toybox has :Weather) && (Weather has :getCurrentConditions))) {
            return "--";
        }
        var cond = Weather.getCurrentConditions();
        if (cond == null || cond.temperature == null) {
            return "--";
        }
        var celsius = (cond.temperature as Number);
        if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) {
            return ((celsius * 9) / 5 + 32).format("%d") + "F";
        }
        return celsius.format("%d") + "C";
    }

    //! Draw one centre-justified row of text.
    //!
    //! drawText() takes the top of the font box, so the glyph block is centred on
    //! yCentre using getFontHeight(), which api.mir documents as exactly ascent plus
    //! descent.
    //! @param dc The drawing context
    //! @param centreX Horizontal centre of the screen
    //! @param yCentre Desired vertical centre of the glyphs
    //! @param font A Graphics.FONT_* constant
    //! @param text The string to draw
    //! @param color Foreground colour
    private function drawRow(dc as Dc, centreX as Number, yCentre as Number,
            font as FontDefinition, text as String, color as ColorType) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centreX, yCentre - Graphics.getFontHeight(font) / 2, font, text,
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Format the date line, e.g. "THU 18 SEP".
    //! @param info Gregorian info built with Time.FORMAT_MEDIUM
    //! @return The formatted date
    private function dateString(info as Gregorian.Info) as String {
        // FORMAT_MEDIUM gives day_of_week and month as abbreviated Strings.
        var dayOfWeek = info.day_of_week;
        var month = info.month;
        var dayText = (dayOfWeek instanceof String) ? (dayOfWeek as String) : "";
        var monthText = (month instanceof String) ? (month as String) : "";
        return dayText.toUpper() + " " + info.day.format("%d") + " " + monthText.toUpper();
    }

    //! Format the clock line, honouring the device's 12/24 hour setting.
    //! @param info Gregorian info built with Time.FORMAT_MEDIUM
    //! @return "HH:MM", with no leading zero on the hour in 12-hour mode
    private function timeString(info as Gregorian.Info) as String {
        var hour = info.hour;
        if (System.getDeviceSettings().is24Hour) {
            return hour.format("%02d") + ":" + info.min.format("%02d");
        }
        hour = hour % 12;
        if (hour == 0) {
            hour = 12;
        }
        return hour.format("%d") + ":" + info.min.format("%02d");
    }

    //! Format the remaining time, adaptively.
    //! @param secsLeft Seconds until the epoch ends
    //! @return "Xd Yh left" above a day, "Xh Ym left" above an hour, "Ym left" above a
    //!  minute, else "<1m left"
    private function formatCountdown(secsLeft as Float) as String {
        var total = secsLeft.toNumber();
        if (total < 60) {
            // Never "0m left": there is still time on the clock, just under a minute.
            return "<1m left";
        }
        var days = total / 86400;
        var hours = (total % 86400) / 3600;
        var minutes = (total % 3600) / 60;
        if (days > 0) {
            return days.format("%d") + "d " + hours.format("%d") + "h left";
        }
        if (hours > 0) {
            return hours.format("%d") + "h " + minutes.format("%d") + "m left";
        }
        return minutes.format("%d") + "m left";
    }
}
