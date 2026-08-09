// Pioneer-DDJ-FLX4-rekordbox-patch.js
//
// Override for the stock DDJ-FLX4 mapping: replaces the "floaty" jog-wheel
// pitch bend with a tight one.
//
// Why: turning the side of the jog normally writes to the [ChannelN],jog
// control. In RateControl::getJogFactor() that value is pushed through
// Rotary::filter(), a 25-tap moving average evaluated once per audio buffer.
// The smoothing window is therefore 25 x buffer period -- 0.5-1.2 s at typical
// Raspberry Pi buffer sizes -- which is the ramp-up and the overshoot.
//
// Instead we drive [ChannelN],wheel, which RateControl applies unfiltered and
// additively (`rate += wheelFactor`). A 20 ms timer converts the incoming tick
// stream into a rate offset and zeroes it as soon as the wheel stops.
//
// Written in ES5 so it also runs on Mixxx 2.3's QtScript engine.
//
// See https://github.com/mixxxdj/mixxx/issues/11091

/* global PioneerDDJFLX4, engine */

(function() {
    "use strict";

    if (typeof PioneerDDJFLX4 === "undefined") {
        // Load order is wrong: this file must come AFTER the vendor script
        // in the mapping XML's <scriptfiles> block.
        console.log("rekordbox-patch: PioneerDDJFLX4 not defined, override skipped");
        return;
    }

    // ---- tuning ----------------------------------------------------------
    // Rate offset applied per jog tick counted in one interval.
    // Lower = finer control, higher = stronger nudge. Try 0.01 - 0.05.
    PioneerDDJFLX4.bendSensitivity = 0.02;
    // Update period in ms. 20 is the minimum engine.beginTimer() accepts, and
    // also sets how fast the bend releases after you let go.
    PioneerDDJFLX4.bendInterval = 20;
    // ----------------------------------------------------------------------

    PioneerDDJFLX4.bendTicks = [0, 0];
    PioneerDDJFLX4.bendTimer = [0, 0];

    PioneerDDJFLX4.bend = function(channel, group, ticks) {
        PioneerDDJFLX4.bendTicks[channel] += ticks;
        if (PioneerDDJFLX4.bendTimer[channel] !== 0) {
            return;
        }
        PioneerDDJFLX4.bendTimer[channel] = engine.beginTimer(
            PioneerDDJFLX4.bendInterval,
            function() {
                var t = PioneerDDJFLX4.bendTicks[channel];
                PioneerDDJFLX4.bendTicks[channel] = 0;
                engine.setValue(group, "wheel", t * PioneerDDJFLX4.bendSensitivity);
                if (t === 0) {
                    // Wheel stopped: bend released, park the timer.
                    engine.stopTimer(PioneerDDJFLX4.bendTimer[channel]);
                    PioneerDDJFLX4.bendTimer[channel] = 0;
                }
            });
    };

    PioneerDDJFLX4.resetBend = function() {
        for (var ch = 0; ch < 2; ch++) {
            if (PioneerDDJFLX4.bendTimer[ch] !== 0) {
                engine.stopTimer(PioneerDDJFLX4.bendTimer[ch]);
                PioneerDDJFLX4.bendTimer[ch] = 0;
            }
            PioneerDDJFLX4.bendTicks[ch] = 0;
            engine.setValue("[Channel" + (ch + 1) + "]", "wheel", 0);
        }
    };

    // --- replace jogTurn --------------------------------------------------
    // Same as the stock version except the final else branch.
    PioneerDDJFLX4.jogTurn = function(channel, _control, value, _status, group) {
        var deckNum = channel + 1;
        // wheel center at 64; <64 rew >64 fwd
        var newVal = value - 64;

        // loop_in / out adjust
        if (engine.getValue(group, "loop_enabled") > 0) {
            if (PioneerDDJFLX4.loopAdjustIn[channel]) {
                newVal = newVal * PioneerDDJFLX4.loopAdjustMultiply +
                    engine.getValue(group, "loop_start_position");
                engine.setValue(group, "loop_start_position", newVal);
                return;
            }
            if (PioneerDDJFLX4.loopAdjustOut[channel]) {
                newVal = newVal * PioneerDDJFLX4.loopAdjustMultiply +
                    engine.getValue(group, "loop_end_position");
                engine.setValue(group, "loop_end_position", newVal);
                return;
            }
        }

        if (engine.isScratching(deckNum)) {
            engine.scratchTick(deckNum, newVal);   // top of platter: unchanged
        } else {
            PioneerDDJFLX4.bend(channel, group, newVal);  // side of platter
        }
    };

    // --- wrap init/shutdown so "wheel" can never be left stuck ------------
    var origInit = PioneerDDJFLX4.init;
    PioneerDDJFLX4.init = function() {
        PioneerDDJFLX4.resetBend();
        if (origInit) {
            origInit.apply(PioneerDDJFLX4, arguments);
        }
    };

    var origShutdown = PioneerDDJFLX4.shutdown;
    PioneerDDJFLX4.shutdown = function() {
        PioneerDDJFLX4.resetBend();
        if (origShutdown) {
            origShutdown.apply(PioneerDDJFLX4, arguments);
        }
    };

    console.log("rekordbox-patch: jog bend override active, sensitivity " +
        PioneerDDJFLX4.bendSensitivity);
})();
