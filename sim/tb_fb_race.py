#!/usr/bin/env python3
"""Triple-buffer race testbench for vector_fb_ddram.sv.

Event-driven model of the triple-buffer state machine (EOF + vbl_edge
+ clearing).  Events: FB_VBL rising edge, EOF reaching stage 2, clear
completion.  Between events the state is constant; we integrate the
assertion duration analytically.

Asserted bug condition:
  display_buf == clear_target_buf  AND  clearing == 1
The scaler is reading from the buffer being actively zero'd = visible
black flash.  We count clk_sys cycles spent in this state.

A/B between race_fix=True (current rtl/vector_fb_ddram.sv) and
race_fix=False (pre-patch behaviour) at multiple FB_VBL/EOF rate
combinations.

Usage:
  python tb_fb_race.py [vbl_hz eof_hz duration_sec]
"""
import heapq
import sys

CLK_SYS_HZ = 50_000_000
CLEAR_CYCLES = 89600                  # ~1.79 ms at 50 MHz
INVALID = 3

# Event types
VBL_RISE = 1
EOF_HEAD = 2
CLEAR_DONE = 3


class FBModel:
    def __init__(self, race_fix=True):
        self.race_fix = race_fix
        self.display_buf = 0
        self.draw_buf = 1
        self.ready_buf = INVALID
        self.clear_target_buf = 1
        self.clearing = True
        self.clear_start = 0           # cycle when current clear started
        self.last_state_t = 0          # last time we accounted for
        # Pending EOFs that arrived while clearing (FIFO order preserved)
        self.pending_eofs = []
        # Stats
        self.black_cycles = 0
        self.swap_eof = 0
        self.swap_vbl = 0
        self.skipped_vbl = 0
        self.deferred_eofs = 0
        self.vbl_eof_coincident = 0

    def _integrate_black(self, until_t):
        """Add black cycles from last_state_t..until_t if conditions hold."""
        if self.clearing and self.display_buf == self.clear_target_buf:
            self.black_cycles += until_t - self.last_state_t
        self.last_state_t = until_t

    def _next_free(self, effective_display):
        if effective_display != 0 and self.draw_buf != 0:
            return 0
        if effective_display != 1 and self.draw_buf != 1:
            return 1
        return 2

    def on_vbl_edge(self, t, eof_same_cycle=False):
        """vbl_edge fires at clk_sys cycle t.

        In RTL, the vbl_edge branch executes BEFORE the EOF branch in
        source order within the same always block.  If both fire in
        same cycle, EOF's later non-blocking write to ready_buf
        overrides vbl_edge's.  We model that by deferring the ready_buf
        invalidation until after EOF processing.
        """
        self._integrate_black(t)
        if self.ready_buf != INVALID:
            self.display_buf = self.ready_buf
            if not eof_same_cycle:
                self.ready_buf = INVALID
            self.swap_vbl += 1
        else:
            self.skipped_vbl += 1

    def on_eof(self, t, vbl_same_cycle=False):
        """EOF reaches stage 2 at clk_sys cycle t."""
        self._integrate_black(t)
        if vbl_same_cycle:
            self.vbl_eof_coincident += 1

        # Effective display_buf calculation
        if self.race_fix:
            if vbl_same_cycle and self.ready_buf != INVALID:
                # ready_buf is about to become new display_buf
                effective_display = self.ready_buf
            else:
                effective_display = self.display_buf
        else:
            effective_display = self.display_buf

        # ready_buf <= draw_buf (the swap)
        self.ready_buf = self.draw_buf
        self.swap_eof += 1
        # Pick next_free, switch draw_buf, start clearing
        nf = self._next_free(effective_display)
        self.draw_buf = nf
        self.clear_target_buf = nf
        self.clearing = True
        self.clear_start = t

    def on_clear_done(self, t):
        self._integrate_black(t)
        self.clearing = False

    def can_process_eof(self):
        return not self.clearing


def run(fb_vbl_hz, eof_hz, duration_sec, race_fix):
    model = FBModel(race_fix=race_fix)
    total_cycles = int(duration_sec * CLK_SYS_HZ)

    # Event schedule
    fb_vbl_period = CLK_SYS_HZ / fb_vbl_hz       # cycles between VBL rises
    eof_period = CLK_SYS_HZ / eof_hz

    # Build event queue using small-tolerance integer cycles
    # (heapq comparison on tuples needs deterministic tiebreak)
    events = []
    # FB_VBL rise events — sync delay is 1 clk_sys, so vbl_edge effective
    # cycle = vbl_rise + 1
    t = 0.0
    eseq = 0
    while t < total_cycles:
        c = int(round(t)) + 1   # +1 for the sync flop delay
        heapq.heappush(events, (c, VBL_RISE, eseq))
        eseq += 1
        t += fb_vbl_period
    # EOF arrival events
    t = 0.0
    while t < total_cycles:
        c = int(round(t))
        heapq.heappush(events, (c, EOF_HEAD, eseq))
        eseq += 1
        t += eof_period

    # Clear completion event scheduled dynamically (we start with clearing=True)
    heapq.heappush(events, (CLEAR_CYCLES, CLEAR_DONE, eseq))
    eseq += 1

    # Process events in time order, handling same-cycle coincidence
    pending_eofs = []          # deferred EOFs waiting for clear

    while events:
        t, ev_type, _ = heapq.heappop(events)
        if t >= total_cycles:
            break

        # Collect all events at this cycle (for same-cycle handling)
        same_cycle = [(t, ev_type)]
        while events and events[0][0] == t:
            _t, _ty, _ = heapq.heappop(events)
            same_cycle.append((_t, _ty))

        has_vbl = any(et == VBL_RISE for _, et in same_cycle)
        has_eof_event = any(et == EOF_HEAD for _, et in same_cycle)
        has_clear_done = any(et == CLEAR_DONE for _, et in same_cycle)

        # Order matters: handle clear_done FIRST (frees stage 2 to
        # process pending EOFs and the just-arrived EOF), THEN vbl
        # (source-order vbl_edge), THEN EOF.
        if has_clear_done:
            model.on_clear_done(t)
            # Promote any pending EOF to be processed this cycle
            if pending_eofs:
                pending_eofs.pop(0)
                has_eof_event = True

        # EOF can only fire if not clearing
        eof_fires_now = has_eof_event and model.can_process_eof()
        if has_eof_event and not eof_fires_now:
            pending_eofs.append(t)
            model.deferred_eofs += 1

        if has_vbl:
            model.on_vbl_edge(t, eof_same_cycle=eof_fires_now)

        if eof_fires_now:
            model.on_eof(t, vbl_same_cycle=has_vbl)
            # Schedule new clear_done
            heapq.heappush(events, (t + CLEAR_CYCLES, CLEAR_DONE, eseq))
            eseq += 1

    # Final integration to end of sim
    model._integrate_black(total_cycles)

    return model


def report(label, m, duration_sec):
    rate_cyc = m.black_cycles / duration_sec
    pct = m.black_cycles / (duration_sec * CLK_SYS_HZ) * 100
    # Approximate black flashes per second assuming each flash lasts
    # ~CLEAR_CYCLES.  Very rough -- treats every black-cycle event as
    # contributing to a flash.
    print(f'{label:32s} black_cyc={m.black_cycles:10d} '
          f'({pct:5.2f}%)  eof_swaps={m.swap_eof:4d}  '
          f'vbl_swaps={m.swap_vbl:4d}  coincident={m.vbl_eof_coincident:3d}')


if __name__ == '__main__':
    if len(sys.argv) >= 4:
        vbl_rate = float(sys.argv[1])
        eof_rate = float(sys.argv[2])
        duration = float(sys.argv[3])
    else:
        vbl_rate = 60.00
        eof_rate = 59.50
        duration = 2.0

    print(f'Sim {duration} sec @ FB_VBL={vbl_rate} Hz, EOF={eof_rate} Hz  '
          f'(beat = {abs(vbl_rate - eof_rate):.2f} Hz)')
    print('-' * 88)
    m_fix = run(vbl_rate, eof_rate, duration, race_fix=True)
    m_nofix = run(vbl_rate, eof_rate, duration, race_fix=False)
    report('with race fix',    m_fix,   duration)
    report('without race fix', m_nofix, duration)

    print()
    print('Rate sweep (1 sec each):')
    print('-' * 88)
    for vbl, eof in [
        (60.00, 60.00),
        (60.00, 59.98),
        (60.00, 59.50),
        (60.00, 56.50),
        (60.00, 50.00),
        (60.00, 30.00),       # extreme EOF lag
        (60.00, 120.00),      # EOF ahead of VBL
    ]:
        m1 = run(vbl, eof, 1.0, race_fix=True)
        m2 = run(vbl, eof, 1.0, race_fix=False)
        beat = abs(vbl - eof)
        print(f'  vbl={vbl:6.2f} eof={eof:6.2f} beat={beat:5.2f}  '
              f'fix:{m1.black_cycles/CLK_SYS_HZ*100:6.2f}%  '
              f'nofix:{m2.black_cycles/CLK_SYS_HZ*100:6.2f}%  '
              f'coinc(fix)={m1.vbl_eof_coincident}  '
              f'coinc(nofix)={m2.vbl_eof_coincident}')
