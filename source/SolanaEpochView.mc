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
import Toybox.Math;
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
    private var _solUsd as Number = -1;
    private var _markBlack as BitmapResource?;
    private var _markWhite as BitmapResource?;
    private var _heartBlack as BitmapResource?;
    private var _heartWhite as BitmapResource?;
    private var _shoeBlack as BitmapResource?;
    private var _shoeWhite as BitmapResource?;

    //! Constructor
    public function initialize() {
        WatchFace.initialize();
    }

    //! Handle layout. Load the official Solana logomark bitmaps once.
    //! @param dc The drawing context
    public function onLayout(dc as Dc) as Void {
        _markBlack = WatchUi.loadResource(Rez.Drawables.SolanaMarkBlack) as BitmapResource;
        _markWhite = WatchUi.loadResource(Rez.Drawables.SolanaMarkWhite) as BitmapResource;
        _heartBlack = WatchUi.loadResource(Rez.Drawables.HeartBlack) as BitmapResource;
        _heartWhite = WatchUi.loadResource(Rez.Drawables.HeartWhite) as BitmapResource;
        _shoeBlack = WatchUi.loadResource(Rez.Drawables.ShoeBlack) as BitmapResource;
        _shoeWhite = WatchUi.loadResource(Rez.Drawables.ShoeWhite) as BitmapResource;
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
            _solUsd = $.Se.numberOr(s.get($.Se.F_SOL_USD), -1);
        } else {
            _solUsd = -1;
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

        // ---- Compass layout, clipped to the inner edge of the ring --------------
        // Time in the middle. Side complications sit on a chord so wide strings
        // (steps, epoch) cannot enter the stroke. Top/bottom rows stack from the
        // inner radius using measured font heights.
        var inner = radius - (penWidth + 1) / 2 - 8;
        var gap = 3;
        var xtinyH = Graphics.getFontHeight(Graphics.FONT_XTINY);
        var tinyH = Graphics.getFontHeight(Graphics.FONT_TINY);
        var smallH = Graphics.getFontHeight(Graphics.FONT_SMALL);

        var mark = day ? _markBlack : _markWhite;
        var markBottom = centreY - inner + 2;
        if (mark != null) {
            var bitmap = mark as BitmapResource;
            dc.drawBitmap(centreX - bitmap.getWidth() / 2, markBottom, bitmap);
            markBottom += bitmap.getHeight();
        }
        drawRow(dc, centreX, markBottom + gap + xtinyH / 2,
            Graphics.FONT_XTINY, dateString(clockInfo), secondary);

        drawRow(dc, centreX, centreY, Graphics.FONT_NUMBER_MEDIUM,
            timeString(clockInfo), primary);

        var heart = day ? _heartBlack : _heartWhite;
        var shoe = day ? _shoeBlack : _shoeWhite;
        var hrText = heartRateText();
        var stepsText = stepCountText();
        var sideY = centreY - (height * 0.16).toNumber();
        var hrDx = chordDx(inner, sideY - centreY, iconValueWidth(dc, heart, hrText, Graphics.FONT_SMALL) / 2, smallH / 2);
        var stDx = chordDx(inner, sideY - centreY, iconValueWidth(dc, shoe, stepsText, Graphics.FONT_SMALL) / 2, smallH / 2);
        drawIconValue(dc, centreX - hrDx, sideY, heart, hrText, Graphics.FONT_SMALL, primary);
        drawIconValue(dc, centreX + stDx, sideY, shoe, stepsText, Graphics.FONT_SMALL, primary);

        var lowerY = centreY + (height * 0.18).toNumber();
        var solText = (_solUsd >= 0) ? "$" + _solUsd.format("%d") : "$--";
        var epochText = _haveData ? "E " + _epoch.format("%d") : "E --";
        var solDx = chordDx(inner, lowerY - centreY, dc.getTextWidthInPixels(solText, Graphics.FONT_SMALL) / 2, smallH / 2);
        var epDx = chordDx(inner, lowerY - centreY, dc.getTextWidthInPixels(epochText, Graphics.FONT_SMALL) / 2, smallH / 2);
        drawRow(dc, centreX - solDx, lowerY, Graphics.FONT_SMALL, solText, _accent);
        drawRow(dc, centreX + epDx, lowerY, Graphics.FONT_SMALL, epochText, _accent);

        var countdown = "no data";
        if (_haveData) {
            countdown = rollover ? "rollover" : formatCountdown(secsLeft);
        }
        var status = "--";
        var statusColor = secondary;
        if (_haveError) {
            status = "RPC " + _errCode.format("%d");
            statusColor = warning;
        } else if (_haveData) {
            status = (progress * 100.0).format("%.0f") + "%  " + weatherText();
        } else {
            status = weatherText();
        }
        if (_haveData && elapsed > 3 * _refreshSecs) {
            status += " !";
            statusColor = warning;
        }
        if (!System.getDeviceSettings().phoneConnected) {
            status += " x";
        }
        var statusY = centreY + inner - xtinyH / 2 - 2;
        var countY = statusY - xtinyH / 2 - gap - tinyH / 2;
        drawRow(dc, centreX, countY, Graphics.FONT_TINY, countdown, primary);
        drawRow(dc, centreX, statusY, Graphics.FONT_XTINY, status, statusColor);
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
    //! @return e.g. "18°" / "64°", or "--" when the phone has not delivered weather
    private function weatherText() as String {
        if (!((Toybox has :Weather) && (Weather has :getCurrentConditions))) {
            return "--";
        }
        var cond = Weather.getCurrentConditions();
        if (cond == null || cond.temperature == null) {
            return "--";
        }
        var celsius = (cond.temperature as Number);
        var value = celsius;
        if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) {
            value = (celsius * 9) / 5 + 32;
        }
        return value.format("%d") + "°";
    }

    //! Horizontal offset from centre that keeps a W x H box inside the inner radius.
    //! @param inner Usable radius inside the ring stroke
    //! @param dy Vertical offset of the box centre from the screen centre
    //! @param halfW Half the box width
    //! @param halfH Half the box height
    //! @return dx to the box centre, 0 if it cannot fit on a chord
    private function chordDx(inner as Number, dy as Number, halfW as Number, halfH as Number) as Number {
        var ay = dy < 0 ? -dy : dy;
        var reachY = ay + halfH;
        if (reachY >= inner) {
            return 0;
        }
        var chord = Math.sqrt((inner * inner - reachY * reachY).toFloat()).toNumber();
        var dx = chord - halfW;
        return dx < 0 ? 0 : dx;
    }

    //! Pixel width of an icon-plus-value group.
    private function iconValueWidth(dc as Dc, icon as BitmapResource?, text as String,
            font as FontDefinition) as Number {
        var w = dc.getTextWidthInPixels(text, font);
        if (icon != null) {
            w += (icon as BitmapResource).getWidth() + 3;
        }
        return w;
    }

    //! Icon plus value, grouped and centred on (centreX, yCentre).
    //! Falls back to text-only if the bitmap failed to load.
    private function drawIconValue(dc as Dc, centreX as Number, yCentre as Number,
            icon as BitmapResource?, text as String, font as FontDefinition,
            color as ColorType) as Void {
        if (icon == null) {
            drawRow(dc, centreX, yCentre, font, text, color);
            return;
        }
        var bitmap = icon as BitmapResource;
        var gap = 3;
        var total = bitmap.getWidth() + gap + dc.getTextWidthInPixels(text, font);
        var x = centreX - total / 2;
        dc.drawBitmap(x, yCentre - bitmap.getHeight() / 2, bitmap);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + bitmap.getWidth() + gap,
            yCentre - Graphics.getFontHeight(font) / 2, font, text,
            Graphics.TEXT_JUSTIFY_LEFT);
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
