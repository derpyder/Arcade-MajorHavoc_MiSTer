//============================================================================
//  Arcade: Star Wars
//
//  Port to MiSTer FPGA by Videodr0me 2026
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1    = 0;
assign VGA_SCALER= 1;
assign VGA_DISABLE = 0;
assign VGA_SL = 0;
assign USER_OUT  = '1;
wire [2:0] core_led;
assign LED_USER  = core_led[2] | ioctl_download;
assign LED_DISK  = {1'b1, core_led[1]};
assign LED_POWER = {1'b1, core_led[0]};
assign BUTTONS   = 0;
assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;

assign CLK_VIDEO = clk_108; // Direct PLL output (109 MHz)
assign CE_PIXEL = ce_pix;   // Video clock enable: gates CLK_VIDEO to derive 60Hz/120Hz
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_DE = ~(hblank | vblank);
assign VGA_R = 0;
assign VGA_G = 0;
assign VGA_B = 0;

wire [1:0] ar = status[15:14];

// Auto-detect optimal display size from HDMI output resolution.
// Pick the largest clean scale factor that fits the output.
// FB is 980×720. Integer scales: ×1=980×720, ×1.5=1470×1080, ×2=1960×1440, ×3=2940×2160 (exact 4K).
// Thresholds = FB_height(720)×scale = the min OUTPUT height that fits that integer scale.
reg [12:0] auto_arx, auto_ary;
always @(*) begin
	if (HDMI_HEIGHT >= 2160) begin
		// 4K (3840×2160): ×3 integer scale -> 2940×2160 (exact 4K height)
		auto_arx = 13'h1B7C;  // 0x1000 | 2940
		auto_ary = 13'h1870;  // 0x1000 | 2160
	end else if (HDMI_HEIGHT >= 1440) begin
		// 1440p (2560×1440): ×2 integer scale -> 1960×1440
		auto_arx = 13'h17A8;  // 0x1000 | 1960
		auto_ary = 13'h15A0;  // 0x1000 | 1440
	end else if (HDMI_HEIGHT >= 1080) begin
		// 1080p (1920×1080): ×1.5 scale -> 1470×1080
		auto_arx = 13'h15BE;  // 0x1000 | 1470
		auto_ary = 13'h1438;  // 0x1000 | 1080
	end else begin
		// 720p (1280×720) or smaller: 1:1 pixel perfect -> 980×720
		auto_arx = 13'h13D4;  // 0x1000 | 980
		auto_ary = 13'h12D0;  // 0x1000 | 720
	end
end

// Aspect menu = {0:Optimized, 1:Pixel Perfect} (Stretched removed).  ar==0 ->
// auto-detected integer scale; else (ar==1) -> 1:1 pixel-perfect.  Both modes
// HW-tested good; the dropped Stretched arm (was ar==1) is simply gone.
assign VIDEO_ARX = (ar == 0) ? auto_arx :  // Optimized (auto-detect)
                               13'h13D4;   // Pixel Perfect (1:1, 980)

assign VIDEO_ARY = (ar == 0) ? auto_ary :  // Optimized (auto-detect)
                               13'h12D0;   // Pixel Perfect (1:1, 720)

// 120Hz MODE — SAFE ACTIVATION
// The HPS restores saved status bits (including status[25]=120Hz ON)
// during boot, BEFORE HDMI_HEIGHT is valid during initialization → HDMI sync loss.

// --- Stage 1: Boot holdoff (~1.3 seconds after FPGA config) ---
// Core ALWAYS starts outputting 60Hz timing regardless of saved settings.
reg [26:0] boot_cnt = 0;
reg boot_done = 0;
always @(posedge clk_50) begin
	if (!boot_cnt[26])
		boot_cnt <= boot_cnt + 1'd1;
	else
		boot_done <= 1;
end

// --- Stage 2: HDMI_HEIGHT validation
// Require height to be in a valid range (256-720) and stable for ~335ms.
wire is_720p_valid = (HDMI_HEIGHT >= 12'd256) & (HDMI_HEIGHT <= 12'd720);
reg [24:0] stable_720p_cnt = 0;
reg is_720p_stable = 0;
always @(posedge clk_50) begin
	if (!is_720p_valid) begin
		stable_720p_cnt <= 0;
		is_720p_stable <= 0;
	end else if (!stable_720p_cnt[24]) begin
		stable_720p_cnt <= stable_720p_cnt + 1'd1;
	end else begin
		is_720p_stable <= 1;
	end
end

// --- Stage 3: 120Hz mode signal
// If boot holdoff expired, user wants 120Hz, and HDMI_HEIGHT has been stable.
wire osd_120hz_mode = boot_done & status[25] & is_720p_stable;
wire not_720p = ~is_720p_stable;

// --- Video mode change notification ---
reg new_vmode_toggle = 0;
reg mode_120_prev = 0;
reg boot_done_prev = 0;
always @(posedge clk_50) begin
	boot_done_prev <= boot_done;

	if (!boot_done) begin
		// During boot: silently track status[25] without firing vmode
		mode_120_prev <= status[25];
	end else begin
		// After boot: fire vmode on user OSD toggle
		mode_120_prev <= status[25];
		if (mode_120_prev != status[25])
			new_vmode_toggle <= ~new_vmode_toggle;
	end

	// Fire once when boot holdoff expires and 120Hz is activating
	if (boot_done & !boot_done_prev & osd_120hz_mode)
		new_vmode_toggle <= ~new_vmode_toggle;
end

`include "build_id.v" 
localparam CONF_STR = {
	"MajorHavoc;;",
	"-;",
	"OEF,Aspect ratio,Optimized,Pixel Perfect;",
	"D2OP,120Hz (720p only),Off,On;",
	"-;",
	"O56,Rotate,0,90,180,270;",
	"O7,Mirror,Off,On;",
	"OUV,Vector Scale,Fill (1.25x),Full (1x),Three-Qtr,Half;",
	"OA,Frame Gate,On,Off;",
	"ORT,Persistence,12 (default),14,10,8,6,4,2,1 Crisp;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Fire,Shield,Coin,Pause;",
	"jn,A,B,Select,Start;",
	"V,v0.1.",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_6, clk_12, clk_50, clk_108;    // clk_6 unused. (A clk_10 split for authentic MH speed black-
                                        // screened: the clk_12 ROM-download strobe was missed by the
                                        // slower clk_10 game domain. Proper speed fix = gate the game on
                                        // clk_12 with a clock-enable instead -- see HANDOFF 8f.)
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_50),
	.outclk_1(clk_12),
	.outclk_2(clk_6),
	.outclk_3(clk_108),
	.locked(pll_locked)
);


///////////////////////////////////////////////////

wire [31:0] status;   // NOTE: this OSD/firmware will NOT cycle status bits >=32 (tried [34:32] -> the
                      // menu showed but wouldn't move off the default). Persistence is a 3-bit field at
                      // [29:27] ("ORT") -- bit 27 reclaimed (it was a dead `status[27]&nvram_dirty` term,
                      // no menu set it); bits 28/29 are the old 2-bit persistence field.
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;

wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire        ioctl_wr;
wire        ioctl_rd;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;

wire [15:0] joy_0, joy_1;
wire [15:0] joy = joy_0 | joy_1;
wire [15:0] joy_l_analog_0;
wire  [8:0] spinner_0, spinner_1;   // real USB spinner devices (hps_io): [7:0]=signed delta, [8]=toggle-on-update
wire [24:0] ps2_mouse;              // USB/PS2 mouse: [15:8]=signed X, [4]=X sign-ext, [1:0]=R/L btn, [24]=toggle
wire        rom_download = ioctl_download && !ioctl_index;
wire        nvram_download = ioctl_download && (ioctl_index == 8'd4);
wire [24:0] dl_addr = ioctl_addr;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_12),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.status_menumask({not_720p, mod_starwars, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.new_vmode(new_vmode_toggle),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_wr(ioctl_wr),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joy_0),
	.joystick_1(joy_1),
	.joystick_l_analog_0(joy_l_analog_0),
	.spinner_0(spinner_0),         // real USB spinner P1: [7:0]=signed delta, [8]=toggle-on-update
	.spinner_1(spinner_1),         // real USB spinner P2
	.ps2_mouse(ps2_mouse)          // USB/PS2 mouse: X movement -> roller, L/R buttons -> fire/shield
);

// DIP switch loading — currently unused (game settings via Test Mode / NVRAM)
// reg [7:0] sw[8];
// always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

// ===== Tempest inputs =====
// MRA DIP switches (ioctl_index=254): sw[0]=DSW1, sw[1]=DSW2,
// sw[2]=difficulty(1:0)/rating(2)/cabinet(4)  (read via the POKEY pots).
reg [7:0] sw[8];
always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

// ===== Major Havoc inputs =====
// Roller (MH DIAL, 8-bit IPT_DIAL relative).  Sources converge on the SAME 8-bit m_dial
// (the gamma reads $3800 + deltas it for ship/maze movement), GAMEPAD-FIRST:
//   1. Left analog stick: rate-proportional NCO (full throw = fast, feather = fine; ~10%
//      deadzone).  PRIORITY -- works on any gamepad, no spinner needed.
//   2. D-pad L/R: fixed-rate fallback (folded into m_rate/m_inc).
//   3. REAL USB spinner (hps_io spinner_0/1): bit 8 toggles per update; on a toggle edge add
//      the FULL signed 8-bit delta (DIAL is 8-bit -> no >>>2, unlike Tempest's 4-bit knob).
//      Gated on a NONZERO delta AND only when the NCO is idle, so a chatty/zero-delta spinner
//      toggle (the framework can emit these with NO physical spinner) can't starve the gamepad.
//      (That starvation was the "both controls dead" HW bug: the old spinner-FIRST branch ran
//       every cycle on a zero-delta toggle, so the stick/D-pad else-branch never executed.)
// !! HW-VERIFY direction (MAME IPT_DIAL PORT_REVERSE) -- negate sp_delta / flip m_inc if inverted.
wire signed [7:0] m_ax       = $signed(joy_l_analog_0[7:0]);
wire        [7:0] m_amag_raw = m_ax[7] ? (~joy_l_analog_0[7:0] + 8'd1) : joy_l_analog_0[7:0];
wire        [7:0] m_amag     = (m_amag_raw > 8'd12) ? m_amag_raw : 8'd0;
// #2 roller rate: CONCAVE in stick deflection (rate = amag - amag^2/256).  Near-linear at the bottom,
// FLATTENS toward the top -> the fast speeds are squished into the very top of the throw, so MOST of
// the stick maps to SLOW-MEDIUM, and the max is ~HALVED (amag 127 -> 64 vs the old 127 = "extreme less
// fast").  Gentler slope than the old linear everywhere.  (amag 13->13, 64->48, 90->59, 127->64.)
wire       [15:0] m_sq       = m_amag * m_amag;
wire        [7:0] m_rate     = (m_amag != 8'd0) ? (m_amag - m_sq[15:8])
                             : ((joy[1]|joy[0]) ? 8'd40 : 8'd0);  // D-pad = fixed slow-medium (was 80)
// Direction: MH dial is PORT_REVERSE.  HW showed full-RIGHT -> ship LEFT, so flip both the
// analog sign (m_ax[7]) and the D-pad (~joy[0]) so RIGHT -> ship RIGHT.
wire              m_inc      = (m_amag != 8'd0) ? m_ax[7] : ~joy[0];

// ===== MOUSE / SPINNER -> roller (ported from Tempest's "slowgain" build) =====
// #3: accept a USB MOUSE (ps2_mouse) OR a dedicated USB spinner (spinner_0/1), whichever moved.
// SLOWGAIN 3/4 (lossless carry) de-sensitizes slow drags for fine aim; STEP_CAP bounds a fast flick
// (= "extreme less fast"). A RATE-PACED +-1 stepper makes velocity = step RATE, not size: each move
// event queues |gained delta| +-1 steps in its direction; a pacer drains them at one per PACE_DIV.
// MH's DIAL is 8-bit (wraps at 128, vs Tempest's 4-bit at 8) so a brisk pace (~34 steps/60Hz frame)
// stays well under 128 -> no wrap-inversion.  XOR the spinner toggles (one-device updates always edge).
wire        sp_tgl    = spinner_0[8] ^ spinner_1[8];
reg         sp_tgl_d  = 1'b0;
reg         ps2_tgl_d = 1'b0;
wire        ps2_tgl   = ps2_mouse[24];
wire        ps2_evt   = ps2_tgl ^ ps2_tgl_d;
wire        spin_evt  = sp_tgl  ^ sp_tgl_d;
wire signed [8:0] ps2_dx = $signed({ps2_mouse[4], ps2_mouse[15:8]});           // mouse X (Arkanoid decode)
wire signed [8:0] sp_dx  = $signed(spinner_0[7:0]) + $signed(spinner_1[7:0]);  // dedicated spinner X
wire signed [8:0] sp_in  = ps2_evt ? ps2_dx : sp_dx;                           // per-event signed delta
wire        [8:0] sp_mag = sp_in[8] ? (~sp_in + 9'd1) : sp_in;                 // |delta|
// slowgain 3/4: scaled = mag*3 + carry; steps = scaled>>2; remainder kept (small moves never floored)
reg  [1:0]  sp_frac   = 2'd0;
wire [10:0] sp_scaled = {1'b0,sp_mag} + {sp_mag,1'b0} + {9'd0,sp_frac};
wire [8:0]  sp_steps  = sp_scaled[10:2];
wire [1:0]  sp_remn   = sp_scaled[1:0];

localparam [15:0] PACE_DIV = 16'd6000;  // one +-1 every ~0.5ms -> ~34 steps/60Hz frame (<<128, safe)
localparam [9:0]  STEP_CAP = 10'd20;    // bound a hard flick's glide
reg  [9:0]  sp_queue = 10'd0;
reg         sp_qdir  = 1'b0;            // 1 = dial DOWN. MH dial is PORT_REVERSE (old code: m_dial -=
                                        // delta) so a +delta -> down. !! HW-VERIFY: flip ~sp_in[8] if reversed.
reg  [15:0] sp_pace  = 16'd0;

reg  [7:0]  m_dial  = 8'd0;
reg  [18:0] m_phase = 19'd0;
reg         m_pamsb = 1'b0;
always @(posedge clk_12) begin
	sp_tgl_d  <= sp_tgl;
	ps2_tgl_d <= ps2_tgl;
	m_pamsb   <= m_phase[18];
	m_phase   <= m_phase + m_rate;

	if ((ps2_evt | spin_evt) && (sp_mag != 9'd0)) begin
		// new mouse/spinner movement: queue the gained +-1 steps in its (reversed) direction
		if ((~sp_in[8]) == sp_qdir) begin
			sp_frac  <= sp_remn;
			sp_queue <= (sp_queue + sp_steps > STEP_CAP) ? STEP_CAP : (sp_queue + sp_steps);
		end else begin
			sp_qdir  <= ~sp_in[8];
			sp_frac  <= sp_remn;
			sp_queue <= ({1'b0,sp_steps} > STEP_CAP) ? STEP_CAP : {1'b0,sp_steps};
		end
	end else if (sp_queue != 10'd0) begin
		// drain at one +-1 per PACE_DIV ticks (velocity = step rate) -- direction-safe on the 8-bit dial
		if (sp_pace == 16'd0) begin
			sp_pace  <= PACE_DIV;
			sp_queue <= sp_queue - 10'd1;
			m_dial   <= m_dial + (sp_qdir ? -8'sd1 : 8'sd1);
		end else sp_pace <= sp_pace - 16'd1;
	end else if (m_phase[18] & ~m_pamsb) begin
		// analog-stick NCO tick (or D-pad fallback) when no mouse/spinner queue is draining
		m_dial <= m_dial + (m_inc ? 8'd1 : -8'd1);
	end
end

// Buttons (CONF_STR J1: Fire,Shield,Coin,Pause -> joy[4..7]).  MH starts on FIRE
// after a coin (no separate Start input on this PCB).
wire m_fire   = joy[4] | ps2_mouse[0];   // gamepad A or mouse LMB
wire m_shield = joy[5] | ps2_mouse[1];   // gamepad B or mouse RMB
wire m_coin   = joy[6];

// IN0 (alpha $1200, active-low): b7=COIN2(right), b6=COIN1(left), b5=service1, b4=diag.
// b3:0 are supplied INSIDE majorhavoc (avg-done/2.4kHz/comms) -> don't-care here (=1).
// coin_service player_1 mux not modelled yet -> COIN reads work; service phase reads the
// same (credit-to-start default).  !! map a service button if the cab needs it.
wire [7:0] mh_in0 = {1'b1, ~m_coin, 1'b1, 1'b1, 4'b1111};
// IN1 (gamma $2800, active-low): b7=P1 fire, b6=P1 shield, b5=P2 fire, b4=P2 shield,
// b3:2 unused(=1).  b1:0 supplied inside majorhavoc (comms) -> don't-care (=1).
wire [7:0] mh_in1 = {~m_fire, ~m_shield, 1'b1, 1'b1, 2'b11, 2'b11};
// DSW2 (gamma $4000) coinage from the MRA DIPs (sw[1]); default 0 = 1C/2C (lenient).
wire [7:0] mh_dsw2 = sw[1];

wire mod_starwars = 1'b0;

// ESB mod selector.  The MRA's <rom index="1"><part>1</part></rom>
// drives ioctl_index=1 with data=0x01 when ESB is loaded; mod=0 (the
// default at boot) selects Star Wars.  Sticky after rom_download
// completes so the value survives once the MRA is in.
reg [7:0] mod_byte = 8'h00;
always @(posedge clk_12) begin
	if (ioctl_wr && (ioctl_index == 8'd1)) mod_byte <= ioctl_dout;
end
wire mod_esb = (mod_byte == 8'h01);

// Video signals
wire hblank, vblank;
wire hs, vs;
wire [3:0] r,g,b;

// CE_PIXEL generation on CLK_VIDEO domain (109 MHz)
reg ce_pix;
always @(posedge clk_108) begin
	if (osd_120hz_mode)
		ce_pix <= 1'b1;       // Full 109 MHz → 120Hz
	else
		ce_pix <= ~ce_pix;    // ~54.5 MHz → 60Hz
end

wire reset = (RESET | status[0] |  buttons[1] | rom_download | nvram_download);
wire [15:0] audio_l, audio_r;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_S = 0;   // Tempest POKEY audio is UNSIGNED (pokey.vhd: 0=silence..255=max).
                      // (Was 1/signed from the Star Wars core -> samples >=0x80 folded negative
                      //  -> torn waveform = harsh/thin "half the chip" sound.  Both POKEYs are fine.)
wire vgade;

wire [7:0] m_dsw0 = {
	~status[16],       // [7] Freeze (OG, 0=Off, 1=On -> ~0 = 1 = Off)
	status[13],        // [6] Demo Sounds (OD, 0=On, 1=Off)
	status[12:11],     // [5:4] Bonus Shields (OBC)
	status[10:9] + 2'd1,   // [3:2] Difficulty (O9A, rotated +1: 0=Mod,1=Hard,2=Hrd+,3=Easy)
	status[8:7]        // [1:0] Starting Shields (O78)
};

wire [7:0] m_dsw1 = {
	status[24:22],     // [7:5] Bonus Coin Adder (OMNO)
	status[21],        // [4] Left Coin (OL)
	status[20:19],     // [3:2] Right Coin (OJK)
	status[18:17] + 2'd2   // [1:0] Coinage (OHI, rotated +2: 0=1P/C,1=2C/P,2=Free,3=2P/C)
};

mhavoc_sw mhavoc_core
(
	.clk_12(clk_12),               // game on clk_12 (12.096 MHz). Runs ~21% fast (MH native 10 MHz);
	                               // proper fix = gate clkdiv/irq5k with a clock-enable (HANDOFF 8f).
	.clk_50(clk_50),
	.clk_vid(clk_108),
	.reset(reset),

	.osd_raster_flicker(status[2]),
	.osd_120hz_mode(osd_120hz_mode),
	.osd_rotate(status[6:5]),
	.osd_flip(status[7]),
	.osd_scale(status[31:30]),     // Vector Scale OSD: 0=Fill(1.25x,default,SOLID via line-fill),1=Full,2=3/4,3=Half
	.osd_gate_bypass(status[10]),
	.osd_persist(status[29:27]),   // Persistence (ORT=bits29:27): 0=12(default),1=14,2=10,3=8,4=6,5=4,6=2,7=1 Crisp(selective-erase)

	// DDRAM Framebuffer Interface (proven SW DDR renderer)
	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.FB_EN(FB_EN),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),
	.FB_FORCE_BLANK(FB_FORCE_BLANK),
`ifdef MISTER_FB_PALETTE
	.FB_PAL_CLK(FB_PAL_CLK),
	.FB_PAL_ADDR(FB_PAL_ADDR),
	.FB_PAL_DOUT(FB_PAL_DOUT),
	.FB_PAL_DIN(FB_PAL_DIN),
	.FB_PAL_WR(FB_PAL_WR),
`endif

	.audio_out_l(audio_l),
	.audio_out_r(audio_r),

	.video_r(r),
	.video_g(g),
	.video_b(b),
	.hsync(hs),
	.vsync(vs),
	.vblank(vblank),
	.hblank(hblank),

	// Major Havoc inputs (IN0 coins/service, IN1 fire/shield, DSW2 coinage, DIAL roller)
	.in0(mh_in0),
	.in1(mh_in1),
	.dsw2(mh_dsw2),
	.dial(m_dial),

	.led(core_led),

	// ROM Download
	.dn_addr(dl_addr),
	.dn_data(ioctl_dout),
	.dn_wr(ioctl_wr & rom_download)
);

// --- NVRAM Save/Load/Clear Logic ---
wire nvram_cs_ioctl = (ioctl_index == 8'd4);
wire nvram_wr_ioctl = nvram_cs_ioctl && ioctl_download && ioctl_wr;

reg [7:0] clear_addr;
reg clearing;
reg old_clear_req;

always @(posedge clk_12) begin
	old_clear_req <= status[3];
	if (status[3] && !old_clear_req) begin
		clearing <= 1;
		clear_addr <= 0;
	end else if (clearing) begin
		if (clear_addr == 255) clearing <= 0;
		clear_addr <= clear_addr + 8'd1;
	end
end

wire        nvram_wr_ext   = nvram_wr_ioctl || clearing;
wire  [7:0] nvram_addr_ext = clearing ? clear_addr : ioctl_addr[7:0];
wire  [7:0] nvram_din_ext  = clearing ? 8'h00 : ioctl_dout;
wire  [7:0] nvram_dout_ext   = 8'h00;  // Tempest: hiscore/NVRAM stubbed (EAROM = 0xFF stub)
wire        nvram_write_pulse = 1'b0;  // -> upload path pushes zeros, never dirty (harmless)

// --- NVRAM Auto-Save & Manual Save  ---
reg nvram_dirty;
reg force_save;


always @(posedge clk_12) begin
	if (reset) begin
		nvram_dirty <= 0;
		force_save <= 0;
	end else begin
		if (ioctl_upload && ioctl_index == 8'd4) begin
			nvram_dirty <= 0;
			force_save <= 0;
		end else if (nvram_write_pulse) begin
			nvram_dirty <= 1;
		end

		// If NVRAM is cleared we force a save.
		if (clearing && clear_addr == 255) begin
			force_save <= 1;
		end
	end
end

// NOTE: status[27] is now Persistence bit 0 (field moved to [29:27]); its old `& nvram_dirty` term
// here was dead (no menu ever set bit 27).  Save runs off status[4]/force_save, so just drop it
// (else odd persistence values would spuriously fire an nvram upload when dirty).
assign ioctl_upload_req = status[4] | force_save;
assign ioctl_din = (ioctl_index == 8'd4) ? nvram_dout_ext : 8'h00;

endmodule
