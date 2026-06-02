// ============================================================================
// Vector Framebuffer — DDRAM Pixel Renderer by Videodr0me 2026:
//
// Vector-to-raster interface convention (X/Y/Z/RGB/BEAM_ON/BEAM_ENA)
// follows the pattern established by Dave Wood's Black Widow renderer.
//
// Renders Atari AVG vector output into a 980×720 32bpp framebuffer
// stored in DDRAM, using MISTER_FB for display.
//
//   Vector Generator (12 MHz)         DDRAM Controller (50 MHz)
//   ┌───────────────────┐           ┌─────────────────────────────┐
//   │ AVG + Drawer      │  Async    │  Stage 1: FIFO Pop          │
//   │ X/Y/Z/RGB/BEAM_ON ┼──FIFO───> │  Stage 2: Decode + Address  │
//   │ FRAME_DONE (EOF)  │  (8K×28b) │  Stage 3: DDRAM Write       │
//   └───────────────────┘  CDC      └─────────────────────────────┘
//
// Clock domain crossing:
//   Entries are pushed into an 8K-deep async FIFO using Gray-coded pointers 
//   for safe CDC to the 50 MHz DDRAM domain (clk_sys).
//
// Pixel pipeline (3 stages, clk_sys):
//   Stage 1 — FIFO FETCH: Pop one 28-bit entry.
//   Stage 2 — DECODE/ADDR: If EOF → trigger buffer swap + clear.
//             If pixel → compute DDRAM word address and byte lane:
//             addr = (Y×1024 + X) / 8,  byte_enable = 1 << (addr % 8).
//             Y×1024 = Y<<10 (stride is power of 2, no decomposition needed).
//   Stage 3 — DDRAM WRITE: Issue a single-beat Avalon-MM write with
//             byte enables (no read-modify-write needed).
//
// Triple buffering:
//   980×700 framebuffers (stride 1024) at DDRAM byte offsets 0x30000000,
//   0x300B0000, 0x30160000 (700 KB each, ~2.1 MB total):
//     display_buf      — being scanned out by the MiSTer scaler
//     draw_buf         — receiving new pixels from the pipeline
//     ready_buf        — completed frame waiting for next VBL swap
//     clear_target_buf — being zeroed after a swap
//   On EOF: draw_buf → ready_buf, free buffer → draw_buf + clear_target_buf.
//   On VBL: ready_buf → display_buf (if valid). Guarantees tear-free output.
//
// OSD_FLICKER mode:
//   When enabled, bypasses triple buffering and uses simple double-buffer.
//   This produces visible (fake) vector flicker, looking best in 120hz.
// ============================================================================

module vector_fb_ddram (
	input         clk_sys,  // Master DDRAM clock (50MHz)
	input         clk_12,   // Vector generator clock
	input         reset,
	
	// Vector inputs
	input  [9:0]  X_VECTOR,
	input  [9:0]  Y_VECTOR,
	input  [4:0]  Z_VECTOR,
	input  [2:0]  RGB,
	input         BEAM_ON,
	input         BEAM_ENA,

	// DDRAM Framebuffer Interface
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

	// MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	// Custom frame sync signals
	input         START_FRAME,
	input         FRAME_DONE,
	input         OSD_FLICKER,
	output        FIFO_FULL_LED,
	output        CLEAR_BUSY        // 1 while a buffer is being cleared (present-gate handshake:
	                                // hold the beam off until the clear actually finishes -> no overrun-drop)
);

	// ------------------------------------------------------------------------
	// MISTER_FB Configuration
	// ------------------------------------------------------------------------
	assign FB_EN     = 1'b1;
	assign FB_FORMAT = 5'b00110; // 32bpp RGBA8888 ([4]=0 RGB; ascal reads byte0=R)
	assign FB_WIDTH  = 980;
	assign FB_HEIGHT = 720;      // 720 (not 700) -> clean 4K integer scale: 720*3=2160 exact
	assign FB_STRIDE = 4096;     // 980*4=3920 bytes/line, padded to 2^12 (Y<<12 addressing)
	assign FB_FORCE_BLANK = 1'b0;

	// ------------------------------------------------------------------------
	// DDRAM Clock
	// ------------------------------------------------------------------------
	assign DDRAM_CLK = clk_sys;
	// DDRAM_RD is now driven by the RMW state machine (was tied 0 in the
	// fire-and-forget 8bpp writer). See ddram_rd_reg below.
	reg ddram_rd_reg = 1'b0;
	assign DDRAM_RD = ddram_rd_reg;

	// ------------------------------------------------------------------------
	// Triple Buffers
	// ------------------------------------------------------------------------
	reg [1:0] display_buf;
	reg [1:0] draw_buf;
	reg [1:0] ready_buf;
	reg [1:0] clear_target_buf;

	reg [2:0] vbl_sync;
	wire vbl_edge = vbl_sync[1] && !vbl_sync[2];

	// ===== DISPLAY-PATH DIAGNOSTIC #2 — AVG LIVENESS (temporary; set to 0 to revert) =====
	// Blue test PASSED (ascal scans the FB).  Now: is the Tempest CPU/AVG generating
	// vectors on this chassis?  DIAG_FB_SCANOUT=1 forces FB_BASE to buf1 AND makes buf1
	// STATIC (the EOF handler below skips buffer rotation + re-clear), so vectors
	// accumulate on a black buf1 and stay.  Combined with the present-gate forced bypassed
	// (tempest_sw DIAG_BYPASS), vectors flow continuously.  HW: steady ATTRACT on buf1 =>
	// CPU/AVG run + render works on real HW => the present-gate FSM is the bug.  Pure BLACK
	// => no vectors generated => CPU/AVG/ROM/reset integration issue (chase dbg next).
	localparam        DIAG_FB_SCANOUT = 1'b0;   // 0 = normal (swap-driven FB_BASE, black clear, rotation)
	localparam [63:0] FILL_WORD       = {2{32'h00FF0000}};  // (unused now; kept for the blue test)

	// FB_BASE outputs the ACTIVE buffer for display (byte address),
	// while DDRAM_ADDR is a 64-bit word index (8 bytes per unit).
	// 32bpp buffers are 720*4096 = 0x2D0000 bytes (0x5A000 words) each.
	assign FB_BASE = DIAG_FB_SCANOUT      ? 32'h302D0000 :  // DIAG: force buf1 (reset-cleared)
	                 (display_buf == 2'd2) ? 32'h305A0000 :
	                 (display_buf == 2'd1) ? 32'h302D0000 :
	                                         32'h30000000;

	// Drawing occurs on the INACTIVE buffer
	wire [28:0] draw_base_word = (draw_buf == 2'd2) ? 29'h060B4000 :
	                             (draw_buf == 2'd1) ? 29'h0605A000 :
	                                                  29'h06000000;

	// Clear target buffer immediately after a swap
	wire [28:0] clear_base_word = (clear_target_buf == 2'd2) ? 29'h060B4000 :
	                              (clear_target_buf == 2'd1) ? 29'h0605A000 :
	                                                           29'h06000000;

	// ------------------------------------------------------------------------
	// Palette Initialization
	// ------------------------------------------------------------------------
	reg [7:0] pal_addr = 0;
	reg       pal_wr = 0;

	// 8 primary/secondary colors * 32 intensity levels = 256 Palette entries
	wire [2:0] pal_rgb = pal_addr[7:5];
	wire [4:0] pal_int = pal_addr[4:0];
	wire [7:0] channel_val = {pal_int, pal_int[4:2]};

	assign FB_PAL_DOUT = {
		pal_rgb[2] ? channel_val : 8'h00, // Red
		pal_rgb[1] ? channel_val : 8'h00, // Green
		pal_rgb[0] ? channel_val : 8'h00  // Blue
	};

	assign FB_PAL_CLK  = clk_sys;
	assign FB_PAL_ADDR = pal_addr;
	assign FB_PAL_WR   = pal_wr;
	
	reg pal_init_done = 0;
	always @(posedge clk_sys) begin
		if (reset) begin
			pal_addr <= 0;
			pal_wr <= 0;
			pal_init_done <= 0;
		end else if (!pal_init_done) begin
			pal_wr <= 1'b1;
			if (pal_addr == 8'd255) begin
				pal_init_done <= 1'b1;
				pal_wr <= 1'b0;
			end else begin
				pal_addr <= pal_addr + 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------------
	// Async FIFO (Vector Gen -> DDRAM Controller)
	// ------------------------------------------------------------------------
	(* ramstyle = "M10K" *) reg [27:0] fifo_mem [0:8191]; 
	reg [13:0] wr_ptr = 0, wr_ptr_g = 0;
	reg [13:0] rd_ptr = 0, rd_ptr_g = 0;
	
	function [13:0] b2g(input [13:0] b);
		b2g = b ^ (b >> 1);
	endfunction
	
	function [13:0] g2b(input [13:0] g);
		reg [13:0] b;
		begin
			b[13] = g[13];
			b[12] = b[13] ^ g[12];
			b[11] = b[12] ^ g[11];
			b[10] = b[11] ^ g[10];
			b[9]  = b[10] ^ g[9];
			b[8]  = b[9]  ^ g[8];
			b[7]  = b[8]  ^ g[7];
			b[6]  = b[7]  ^ g[6];
			b[5]  = b[6]  ^ g[5];
			b[4]  = b[5]  ^ g[4];
			b[3]  = b[4]  ^ g[3];
			b[2]  = b[3]  ^ g[2];
			b[1]  = b[2]  ^ g[1];
			b[0]  = b[1]  ^ g[0];
			g2b = b;
		end
	endfunction

	// --- WRITE SIDE (clk_12) ---
	reg [9:0] last_x, last_y;
	reg       last_beam_on;
	reg       last_frame_done;
	
	// Synchronize read pointer to write domain
	reg [13:0] rd_ptr_g_sync1 = 0, rd_ptr_g_sync2 = 0;
	always @(posedge clk_12) begin
		rd_ptr_g_sync1 <= rd_ptr_g;
		rd_ptr_g_sync2 <= rd_ptr_g_sync1;
	end
	
	wire [13:0] rd_ptr_bin = g2b(rd_ptr_g_sync2);
	wire [13:0] fifo_used = wr_ptr - rd_ptr_bin;
	wire fifo_full_flag = (fifo_used > 14'd8100);

	reg [19:0] led_timer = 0;
	always @(posedge clk_12) begin
		if (fifo_full_flag) led_timer <= 20'hFFFFF;
		else if (led_timer != 0) led_timer <= led_timer - 1'b1;
	end
	assign FIFO_FULL_LED = (led_timer != 0);
	
	// Pre-calculate conditions to ensure a SINGLE RAM assignment
	wire push_eof = (FRAME_DONE && !last_frame_done);
	wire sample_lit = BEAM_ON && (Z_VECTOR != 5'd0);
	// Z==0 BLANK: bwidow_dw blanked pixels where Z==0 (beam moves + dim-to-black draws).
	// vector_fb_ddram replaced bwidow_dw and lost that blank.  In overwrite mode (USE_RMW=0)
	// a Z==0 write deposits BLACK and ERASES the geometry it crosses -> dotted lines.  Restore
	// the blank by not pushing invisible (Z==0) points (correct for additive mode too -- a
	// Z==0 pixel adds nothing).  Also cuts FIFO/DDR write traffic.  Sim: +5% retention.
	wire push_pix = (sample_lit && (X_VECTOR != last_x || Y_VECTOR != last_y || !last_beam_on));

	// === Write-side Bresenham LINE-FILL (solid lines at Vector Scale > x1) ===================
	// The AVG drawer steps at avg_ena = clk/4, so a new vector point arrives only every ~4
	// clk_12 cycles (3 idle).  Scaling the walked points up (mhavoc_sw Vector Scale > x1)
	// spreads consecutive points >1 px apart -> dotted.  Fill the gap HERE on the write side
	// (the 50 MHz read pipeline is UNTOUCHED): when a CONTINUATION point (no beam-off/move
	// since the last push, small gap) arrives >1 px from the last pushed pixel, walk Bresenham
	// last->new pushing each intermediate pixel into the FIFO across the idle cycles.
	//   * At x1 the points are <=1 px apart -> fill NEVER triggers -> default path byte-identical.
	//   * Only SMALL gaps (2..3 px) are filled -> fits the clk/4 slack; bigger gaps (= a pen-up
	//     move, or extreme scale) fall through to a plain push (no spurious connecting line).
	//   * beam_gap breaks continuity on any non-lit sample so we never fill across a move.
	reg        beam_gap;                       // a move/blank happened since last push => new segment
	reg        fill_active;
	reg  [9:0] fcx, fcy, ftx, fty;             // Bresenham current / target
	reg  [4:0] fz;  reg [2:0] frgb;            // fill colour = the new point's
	reg signed [12:0] ferr;                    // Bresenham error term
	reg  [9:0] fdx, fdy;                        // |dx|, |dy|
	reg        fsx, fsy;                        // step direction (1 = +)
	reg  [2:0] fcount;
	localparam [2:0] FILL_CAP = 3'd3;           // <=3 injected px/gap -> fits the 3 idle clk_12 cycles

	wire signed [13:0] f_e2  = ferr <<< 1;
	wire        f_sx  = (f_e2 > -$signed({4'b0, fdy}));
	wire        f_sy  = (f_e2 <  $signed({4'b0, fdx}));
	wire [9:0]  f_nx  = f_sx ? (fsx ? fcx + 10'd1 : fcx - 10'd1) : fcx;
	wire [9:0]  f_ny  = f_sy ? (fsy ? fcy + 10'd1 : fcy - 10'd1) : fcy;
	wire signed [12:0] f_nerr = ferr - (f_sx ? $signed({4'b0, fdy[8:0]}) : 13'sd0)
	                                 + (f_sy ? $signed({4'b0, fdx[8:0]}) : 13'sd0);
	wire f_done = (f_nx == ftx && f_ny == fty) || (fcount >= FILL_CAP);

	// chebyshev gap between the last pushed pixel and the incoming point
	wire [9:0] g_dx = (X_VECTOR > last_x) ? (X_VECTOR - last_x) : (last_x - X_VECTOR);
	wire [9:0] g_dy = (Y_VECTOR > last_y) ? (Y_VECTOR - last_y) : (last_y - Y_VECTOR);
	wire start_fill = push_pix && !beam_gap && last_beam_on
	                  && (g_dx > 10'd1 || g_dy > 10'd1)    // a gap to fill
	                  && (g_dx <= 10'd3 && g_dy <= 10'd3); // small enough to be a real continuation

	always @(posedge clk_12) begin
		last_frame_done <= FRAME_DONE;   // EOF edge-detect: must sample every cycle

		if (reset) begin
			wr_ptr <= 0;  wr_ptr_g <= 0;
			last_beam_on <= 1'b0;  beam_gap <= 1'b0;  fill_active <= 1'b0;  fcount <= 3'd0;
		end else begin
			// continuity: a non-lit sample (move/blank) breaks the line (no fill across it)
			if (!fill_active && !sample_lit) beam_gap <= 1'b1;

			if (push_eof) begin
				fifo_mem[wr_ptr[12:0]] <= 28'hFFFFFFF;
				wr_ptr <= wr_ptr + 1'b1;  wr_ptr_g <= b2g(wr_ptr + 1'b1);
				fill_active <= 1'b0;                       // EOF aborts any in-flight fill
			end else if (fill_active) begin
				// inject the next Bresenham pixel toward the target
				fifo_mem[wr_ptr[12:0]] <= {fz, frgb, f_ny, f_nx};
				wr_ptr <= wr_ptr + 1'b1;  wr_ptr_g <= b2g(wr_ptr + 1'b1);
				fcx <= f_nx;  fcy <= f_ny;  ferr <= f_nerr;  fcount <= fcount + 3'd1;
				if (f_done) begin
					last_x <= ftx;  last_y <= fty;  last_beam_on <= 1'b1;
					beam_gap <= 1'b0;  fill_active <= 1'b0;
				end
			end else if (start_fill) begin
				// set up Bresenham from the last pushed pixel toward the new point; the first
				// injected pixel is pushed next cycle (fill_active branch).
				fcx  <= last_x;  fcy <= last_y;  ftx <= X_VECTOR;  fty <= Y_VECTOR;
				fz   <= Z_VECTOR;  frgb <= RGB;
				fdx  <= g_dx;  fdy <= g_dy;
				fsx  <= (X_VECTOR > last_x);  fsy <= (Y_VECTOR > last_y);
				ferr <= $signed({4'b0, g_dx[8:0]}) - $signed({4'b0, g_dy[8:0]});
				fcount <= 3'd0;  fill_active <= 1'b1;
			end else if (push_pix) begin
				// normal single-pixel push (adjacent point, or new segment after a move)
				fifo_mem[wr_ptr[12:0]] <= {Z_VECTOR, RGB, Y_VECTOR, X_VECTOR};
				wr_ptr <= wr_ptr + 1'b1;  wr_ptr_g <= b2g(wr_ptr + 1'b1);
				last_x <= X_VECTOR;  last_y <= Y_VECTOR;  last_beam_on <= BEAM_ON;
				beam_gap <= 1'b0;
			end
		end
	end
	// --- READ SIDE (clk_sys, 50MHz) ---
	// Pipeline Stages
	reg        stage2_valid;
	reg [27:0] stage2_data;
	
	reg        stage3_valid;
	reg [28:0] stage3_addr;      // full DDR word address of the target pixel's word
	reg [18:0] stage3_off;       // SELECTIVE-ERASE: within-buffer word offset (= computed_pixel_addr[22:3]),
	                             //   carried to the write stage so it can be recorded into the dirty list
	reg        stage3_slot;      // which 4-byte half of the 64-bit word (byte_offset[2])
	reg [31:0] stage3_pixel;     // RGBA8888 word to write: {8'h00, B, G, R} (byte0=R)

	// Pipeline Data Signals Here
	logic [4:0]  pixel_z;
	logic [2:0]  pixel_c;
	logic [9:0]  pixel_y;
	logic [9:0]  pixel_x;
	logic [22:0] computed_pixel_addr;  // byte offset within buffer: Y*4096 + X*4
	logic [7:0]  chan;                 // 8-bit channel value = {z[4:0], z[4:2]}

	// --- Read-modify-write (RMW) pixel writer ---
	// 32bpp pixels are 4-byte aligned (2 per 64-bit word) -> never straddle a word.
	// Phase 2 merges by OVERWRITE; Phase 3 = saturating-ADD (one-line change here).
	// USE_RMW=0 selects the proven sub-word byte-enable overwrite fallback (no read).
	localparam       USE_RMW   = 1'b0;   // fire-and-forget byte-enable write (no per-pixel
	                                     // read) -- the RMW read stalled + dropped ~75% of
	                                     // pixels under real shared-DDR contention (sim-confirmed)
	localparam [1:0] RMW_IDLE  = 2'd0,
	                 RMW_READ  = 2'd1,
	                 RMW_WRITE = 2'd2;
	reg  [1:0]  rmw_state = RMW_IDLE;
	reg  [63:0] rmw_rdword;
	// --- Phase 3a: additive (saturating-ADD) overlap ---
	// ADD_MODE=1: beams deposit light additively -- crossings sum + color-mix,
	// repeated/over-driven hits brighten and clamp toward white.  =0 = overwrite
	// (Phase-2 parity).  Later this becomes the OSD "Beam overlap" toggle.
	localparam ADD_MODE = 1'b1;

	// per-channel saturating add (8-bit, clamp at 255)
	function automatic [7:0] sat8(input [7:0] a, input [7:0] b);
		logic [8:0] s;
		begin
			s = {1'b0, a} + {1'b0, b};
			sat8 = s[8] ? 8'hFF : s[7:0];
		end
	endfunction

	// old pixel currently in the target 4-byte slot of the read-back word
	wire [31:0] old_pix = stage3_slot ? rmw_rdword[63:32] : rmw_rdword[31:0];
	// saturating-add the new beam contribution onto it, per RGB channel ({00,B,G,R})
	wire [31:0] add_pix = { 8'h00,
	                        sat8(old_pix[23:16], stage3_pixel[23:16]),   // B
	                        sat8(old_pix[15:8],  stage3_pixel[15:8]),    // G
	                        sat8(old_pix[7:0],   stage3_pixel[7:0]) };   // R
	wire [31:0] new_slot = ADD_MODE ? add_pix : stage3_pixel;
	// merge the (additive or overwrite) pixel into the correct slot of the word
	wire [63:0] merged_word = stage3_slot ? {new_slot,         rmw_rdword[31:0]}
	                                      : {rmw_rdword[63:32], new_slot};

	reg [13:0] wr_ptr_g_sync1 = 0, wr_ptr_g_sync2 = 0;
	always @(posedge clk_sys) begin
		wr_ptr_g_sync1 <= wr_ptr_g;
		wr_ptr_g_sync2 <= wr_ptr_g_sync1;
	end
	
	wire fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);

	// stage2_data read pipeline is gated below (see s2_advance, after `clearing` is declared).
	// DDRAM Registers
	reg [63:0] ddram_din_reg;
	reg [28:0] ddram_addr_reg;
	reg [7:0]  ddram_be_reg;
	reg [7:0]  ddram_burst_reg;
	reg        ddram_we_reg;

	assign DDRAM_DIN = ddram_din_reg;
	assign DDRAM_ADDR = ddram_addr_reg;
	assign DDRAM_BE = ddram_be_reg;
	assign DDRAM_BURSTCNT = ddram_burst_reg;
	
	// SAFETY CLAMP — covers 3x 32bpp buffers (word 0x06000000..0x060B4000+0x5A000 = 0x0610E000 end)
	wire safe_address = (ddram_addr_reg >= 29'h06000000) && (ddram_addr_reg <= 29'h0610DFFF);
	assign DDRAM_WE = ddram_we_reg && safe_address;

	// Clear State
	reg clearing;
	reg [18:0] clear_addr; // 368640 words = 720*4096 bytes = ~2.95MB buffer (368639 fits in 19 bits)
	assign CLEAR_BUSY = clearing;   // present-gate handshake: beam stays off until this drops

	// ============================================================================
	// SELECTIVE-ERASE (refresh-ceiling fix) — replay-as-black instead of full clear
	// ----------------------------------------------------------------------------
	// The full/band clear writes up to 368640 zero words = ~8-16ms, which caps the
	// present rate well under the 60Hz scanout.  STATIC content fuses regardless, but
	// MOTION below 60Hz, combined with the present_gate's N-redraw accumulation,
	// reads as smear/strobe -- the "side-scroll flicker" (confirmed: doesn't flicker
	// when nothing moves).  Lowering N to shrink the period instead goes BLACK,
	// because the fixed ~16ms clear then dominates the beam-off duty.
	//
	// FIX: remember EXACTLY which words each buffer wrote (a per-buffer dirty list),
	// and on recycle replay just those as black (~1-2ms at 20-30k px) instead of
	// zeroing the whole buffer.  ~10x faster erase -> the present_gate blank shrinks
	// -> the present rate reaches the 60Hz cap -> ONE redraw per displayed frame fuses
	// cleanly.  Use with persistence N=1 (crisp motion).
	//
	// SCOPE / FALLBACK: tied to N=1.  At N>1 the gate accumulates N redraws into the
	// buffer with no clear between, so the list grows ~Nx and overflows CAP -> we fall
	// back to the proven full/band clear for that buffer (today's behaviour = phosphor
	// glow).  So persistence=1 => selective erase (crisp 60Hz); persistence>1 => glow.
	// Also: boot clears (clr_full) and any single frame > CAP use the full clear.
	// Toggleable -- USE_SELECTIVE_ERASE=0 reverts to the proven full/band clear.
	localparam        USE_SELECTIVE_ERASE = 1'b1;
	localparam int    DIRTY_CAP = 32768;               // max recorded px / buffer / frame (N=1 ~20-30k)
	(* ramstyle = "M10K" *)
	reg [18:0] dirty_mem [0:3*DIRTY_CAP-1];            // [{buf,idx}] = within-buffer WORD offset
	reg [15:0] dirty_wptr [0:2];                        // per-buffer recorded count (0..CAP)
	reg        dirty_ovf  [0:2];                        // per-buffer overflow -> full-clear fallback
	reg [18:0] last_off;                                // dedup-vs-previous (kills slot0/slot1 dup of a word)
	reg        use_replay;                              // this clear is a replay-erase (else full/band clear)
	reg [15:0] erase_idx;                               // replay read index
	reg [18:0] erase_rdata;                             // dirty_mem read register (1-clk latency)
	localparam E_READ = 1'b0, E_WRITE = 1'b1;
	reg        estate;                                  // replay 2-phase: READ offset / WRITE zero

	// Content-adaptive clear: track the min/max ROW actually drawn into each buffer, and clear
	// ONLY that band when the buffer is recycled (vs the fixed rows 88..613).  All clk_sys (no CDC).
	// Shrinks the clear to the content's vertical extent (attract ~rows 203..467) so it finishes
	// INSIDE the present-gate blank (the fixed clear overran it under contention -> early-beam drop)
	// AND lets the blank shorten -> higher present rate.  No trails: clear band = drawn band.
	reg [9:0] cur_ymin, cur_ymax;     // running row-extent of the frame currently being drawn
	reg [9:0] buf_ymin [0:2];         // per physical buffer: the row band it holds (when last drawn)
	reg [9:0] buf_ymax [0:2];

	// stage2_data must update ONLY when the read pipeline actually advances (consumes
	// stage2), so it stays paired with stage2_valid.  The original unconditional
	// `stage2_data <= fifo_mem[rd_ptr]` re-read rd_ptr every cycle; during a stall
	// (DDRAM_BUSY or a pending stage3 write) rd_ptr had already moved on, so stage2_data
	// decoupled from stage2_valid -> the held pixel's data was clobbered (often with the
	// empty-slot X) before decode, and the bounds check then silently dropped it.
	// This is the contention-only pixel loss (sim: 1373/6846 lost at 50% DDR busy).
	// `s2_advance` matches EXACTLY the condition under which the advance branch runs below.
	wire s2_advance = !DDRAM_BUSY && !clearing && (rmw_state == RMW_IDLE) && !stage3_valid;
	always @(posedge clk_sys) begin
		if (s2_advance) stage2_data <= fifo_mem[rd_ptr[12:0]];
	end

	// --- Phase 3b burst-WRITE spike (self-contained, default OFF) ---
	// USE_BURST_CLEAR=1 bursts the buffer-clear: one DDRAM_BURSTCNT=CLEAR_BURST
	// command then CLEAR_BURST zero-word beats, vs single-word writes.  It's the
	// minimal hardware test of burst writes on the emu DDR port (ram1): if the
	// screen still clears with it on, bursts work here (BW's v3.7 scramble was an
	// FSM bug, not a hw wall -> the halation bloom_engine can use bursts).  Left
	// OFF so the default Phase-3 build is the proven single-word clear.
	localparam       USE_BURST_CLEAR = 1'b1;   // burst the clear (16 words/cmd) so it finishes
	                                           // under DDR contention; now verifiable in the FB sim
	localparam [7:0] CLEAR_BURST     = 8'd16;   // 368640/16 = 23040 bursts (exact)
	reg [7:0] clear_beat;                        // beat within the current clear burst

	// --- ROW-RANGE clear (projectile-flicker fix) ---------------------------------------
	// The /2-scaled content only occupies rows ~95..606 of the 700-row buffer.  Clearing the
	// FULL buffer (~10ms) leaves too little beam-on time at 60Hz, so the END of the display list
	// (the late-drawn projectiles) gets cut off when the list grows from firing -> NES-style
	// flicker.  Clear ONLY rows 88..613 per frame (~7.5ms) -> the paint window grows ~6.6->9.1ms
	// -> the whole list (projectiles included) draws every frame.  BOOT: the first 4 clears stay
	// FULL so every buffer's unused rows get zeroed once (else they'd show DDR garbage).
	reg [2:0] clear_cnt = 3'd0;
	// FULL-buffer clear bounds (boot clears): 720*4096/8 = 368640 words.
	localparam [18:0] CLR_BURST_END_FULL = 19'd368624;   // 368640-16
	localparam [18:0] CLR_SINGLE_END_FULL= 19'd368639;   // 368640-1
	// NOTE (MH): the CLR_*_ROW fixed-window constants are DEAD here -- MH uses the
	// content-adaptive ct_lo/ct_hi band (below), which auto-tracks the drawn rows.
	localparam [18:0] CLR_ROW_LO         = 19'd45056;    // (dead) old fixed row 88 * 512
	localparam [18:0] CLR_BURST_END_ROW  = 19'd314352;   // (dead)
	localparam [18:0] CLR_SINGLE_END_ROW = 19'd314367;   // (dead)
`ifdef SIM_ROWCLEAR
	localparam [2:0] CLR_FULL_N = 3'd1;   // sim: only the reset clear is full -> exercise row-range fast
`else
	localparam [2:0] CLR_FULL_N = 3'd4;   // boot: first 4 clears full (all 3 buffers' unused rows zeroed)
`endif
	wire        clr_full      = (clear_cnt < CLR_FULL_N);
	// content-adaptive band of the buffer being cleared (clear_target_buf), with a +/-2-row margin,
	// clamped to [0,699].  These wires track clear_target_buf, which == next_free_buf DURING the
	// clear -> the band matches the buffer's actual content.  (The START address is latched from
	// next_free_buf directly in the EOF handler, since clear_target_buf updates one cycle later.)
	wire [9:0]  ct_lo = (buf_ymin[clear_target_buf] >= 10'd2)   ? buf_ymin[clear_target_buf] - 10'd2 : 10'd0;
	wire [9:0]  ct_hi = (buf_ymax[clear_target_buf] <= 10'd717) ? buf_ymax[clear_target_buf] + 10'd2 : 10'd719;
	wire [18:0] clr_start     = clr_full ? 19'd0 : {ct_lo, 9'd0};               // ct_lo * 512
	wire [18:0] clr_burst_end = clr_full ? CLR_BURST_END_FULL  : ({ct_hi, 9'd0} + 19'd512 - 19'd16); // (ct_hi+1)*512-16
	wire [18:0] clr_single_end= clr_full ? CLR_SINGLE_END_FULL : ({ct_hi, 9'd0} + 19'd512 - 19'd1);
	reg       clear_setup;                       // 1=SETUP (latch addr, we=0); 0=DATA (stream)

	always @(posedge clk_sys) begin
		vbl_sync <= {vbl_sync[1:0], FB_VBL};

		if (!DDRAM_BUSY) begin
			ddram_we_reg <= 1'b0;
			ddram_rd_reg <= 1'b0;
		end

		if (reset) begin
			display_buf <= 2'd0;
			draw_buf <= 2'd1;
			ready_buf <= 2'd3;
			clear_target_buf <= 2'd1;
			
			clearing <= 1'b1;
			clear_addr <= 0;
			
			rd_ptr <= 0;
			rd_ptr_g <= 0;
			stage2_valid <= 1'b0;
			stage3_valid <= 1'b0;
			ddram_we_reg <= 0;
			ddram_rd_reg <= 0;
			rmw_state <= RMW_IDLE;
			clear_beat <= 0;
			clear_setup <= 1'b1;
			clear_cnt <= 3'd0;       // boot: force the first clears full (clear_addr<=0 above)
			cur_ymin <= 10'd719; cur_ymax <= 10'd0;                 // inverted = "nothing drawn yet"
			buf_ymin[0] <= 10'd0; buf_ymax[0] <= 10'd719;           // default = full band (safe until a
			buf_ymin[1] <= 10'd0; buf_ymax[1] <= 10'd719;           //   buffer is drawn + its band recorded;
			buf_ymin[2] <= 10'd0; buf_ymax[2] <= 10'd719;           //   the boot full-clears cover this too)
			// SELECTIVE-ERASE: empty all dirty lists; boot clears are full (clr_full) so this is safe.
			dirty_wptr[0] <= 16'd0; dirty_wptr[1] <= 16'd0; dirty_wptr[2] <= 16'd0;
			dirty_ovf[0]  <= 1'b0;  dirty_ovf[1]  <= 1'b0;  dirty_ovf[2]  <= 1'b0;
			last_off   <= 19'h7FFFF;
			use_replay <= 1'b0;     // reset clear is a FULL clear (clear_cnt=0 => clr_full)
			erase_idx  <= 16'd0;
			estate     <= E_READ;
		end else begin
		
			// -------------------------------------------------------------
			// VBLANK (Output Side)
			// -------------------------------------------------------------
			if (OSD_FLICKER) begin
				// Unbuffered On
				if (vbl_edge) begin
					display_buf <= draw_buf;
					draw_buf <= (draw_buf == 2'd0) ? 2'd1 : 2'd0;
					clear_target_buf <= (draw_buf == 2'd0) ? 2'd1 : 2'd0;
					clearing <= 1'b1;
					clear_addr <= clr_start;
				end
			end else begin
				// Unbuffered Off: TRIPLE BUFFER
				if (vbl_edge && ready_buf != 2'd3) begin
					display_buf <= ready_buf;
					ready_buf <= 2'd3; // Invalidate
				end
			end

			// -------------------------------------------------------------
			// CLEARING LOGIC
			// -------------------------------------------------------------
			if (DDRAM_BUSY) begin
				// Wait
			end else if (clearing) begin
				// CLEAR the new draw buffer (zeros) before accepting pixels.  All three clear
				// strategies write ZERO words; they differ only in WHICH words + addressing.
				ddram_din_reg <= 64'd0;  // black (ascal scanout already confirmed via blue test)
				ddram_be_reg  <= 8'hFF;

				if (use_replay) begin
					// ---- REPLAY-ERASE (selective): zero ONLY the words this buffer recorded ----
					// 2-phase/entry because the dirty-list RAM read has 1-clk latency.  Both phases
					// run only on !DDRAM_BUSY (outer guard), so DDR contention just stretches it.
					// ~2 clk/px -> ~1-2ms for 20-30k px (vs ~8-16ms full clear) -> the present-gate
					// blank shrinks -> present rate reaches 60Hz -> motion fuses (use at N=1).
					ddram_burst_reg <= 8'd1;
					case (estate)
					E_READ: begin
						ddram_we_reg <= 1'b0;
						if (erase_idx >= dirty_wptr[clear_target_buf]) begin
							// every recorded word zeroed -> recycle this buffer's dirty list
							clearing                     <= 1'b0;
							dirty_wptr[clear_target_buf] <= 16'd0;
							dirty_ovf[clear_target_buf]  <= 1'b0;
							last_off                     <= 19'h7FFFF;
							if (clear_cnt < 3'd7) clear_cnt <= clear_cnt + 3'd1;
						end else begin
							erase_rdata <= dirty_mem[{clear_target_buf, erase_idx[14:0]}];
							estate      <= E_WRITE;
						end
					end
					E_WRITE: begin
						ddram_addr_reg <= clear_base_word + erase_rdata;   // zero-extends to 29b
						ddram_we_reg   <= 1'b1;
						erase_idx      <= erase_idx + 1'b1;
						estate         <= E_READ;
					end
					endcase

				end else if (USE_BURST_CLEAR) begin
					// 2-state burst writer modelled on ascal's sIDLE/sWRITE master.
					ddram_burst_reg <= CLEAR_BURST;
					if (clear_setup) begin
						// SETUP: latch addr + burstcount one cycle BEFORE asserting we,
						// so the burst command carries a stable address (kills the
						// registered-output address skew). we stays 0 this cycle.
						ddram_addr_reg <= clear_base_word + clear_addr;
						ddram_we_reg   <= 1'b0;
						clear_beat     <= 8'd0;
						clear_setup    <= 1'b0;
					end else begin
						// DATA: stream CLEAR_BURST zero words.  Advance the beat ONLY on a
						// CONFIRMED transfer -- this is the !DDRAM_BUSY branch, so
						// ddram_we_reg=1 means the beat presented last cycle was accepted
						// (== ascal avl_rad_c: write && !waitrequest).  Counting cycles
						// instead was the v1 bug that hung the burst -> black.
						ddram_we_reg <= 1'b1;
						if (ddram_we_reg) begin
							if (clear_beat == CLEAR_BURST - 8'd1) begin
								ddram_we_reg <= 1'b0;       // 16th beat done -> end burst
								clear_setup  <= 1'b1;        // next burst re-enters SETUP
								if (clear_addr == clr_burst_end) begin
									clearing <= 1'b0;
									// full clear wiped the buffer -> empty its dirty list (record fresh)
									dirty_wptr[clear_target_buf] <= 16'd0;
									dirty_ovf[clear_target_buf]  <= 1'b0;
									last_off                     <= 19'h7FFFF;
									if (clear_cnt < 3'd7) clear_cnt <= clear_cnt + 3'd1;  // past boot -> row-range
								end else clear_addr <= clear_addr + CLEAR_BURST;
							end else begin
								clear_beat <= clear_beat + 8'd1;
							end
						end
					end
				end else begin
					ddram_burst_reg <= 8'd1;
					ddram_addr_reg  <= clear_base_word + clear_addr;
					ddram_we_reg    <= 1'b1;
					if (clear_addr == clr_single_end) begin
						clearing <= 1'b0;
						dirty_wptr[clear_target_buf] <= 16'd0;
						dirty_ovf[clear_target_buf]  <= 1'b0;
						last_off                     <= 19'h7FFFF;
						if (clear_cnt < 3'd7) clear_cnt <= clear_cnt + 3'd1;
					end else clear_addr <= clear_addr + 1'b1;
				end

				// FLUSH pipeline stages from the previous frame.
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;
				rmw_state    <= RMW_IDLE;

			end else begin
				// --- RMW pixel writer + FIFO pipeline (replaces fire-and-forget) ---
				// 32bpp pixels are 4 bytes in one 64-bit word (slot 0 or 1).  The FSM
				// owns DDR; the pipeline advances only while IDLE so a pending pixel is
				// never overwritten mid-RMW.  Phase 3 changes the WRITE merge to sat-ADD.
				case (rmw_state)
				RMW_IDLE: if (stage3_valid) begin
					if (USE_RMW) begin
						ddram_addr_reg  <= stage3_addr;      // issue read of target word
						ddram_be_reg    <= 8'hFF;
						ddram_burst_reg <= 8'd1;
						ddram_rd_reg    <= 1'b1;
						rmw_state       <= RMW_READ;
					end else begin
						ddram_addr_reg  <= stage3_addr;      // FALLBACK: BE overwrite (no read)
						ddram_din_reg   <= {2{stage3_pixel}};
						ddram_be_reg    <= stage3_slot ? 8'hF0 : 8'h0F;
						ddram_burst_reg <= 8'd1;
						ddram_we_reg    <= 1'b1;
						stage3_valid    <= 1'b0;
						// SELECTIVE-ERASE: record this word into draw_buf's dirty list so the
						// next recycle can replay-erase it.  Dedup the consecutive same-word hit
						// (a horizontal run writes slot0 then slot1 of one word).  Overflow ->
						// flag the buffer; its next recycle falls back to a full clear (no trails).
						if (USE_SELECTIVE_ERASE && stage3_off != last_off) begin
							if (dirty_wptr[draw_buf] < 16'd32768) begin   // == DIRTY_CAP
								dirty_mem[{draw_buf, dirty_wptr[draw_buf][14:0]}] <= stage3_off;
								dirty_wptr[draw_buf] <= dirty_wptr[draw_buf] + 1'b1;
							end else
								dirty_ovf[draw_buf] <= 1'b1;
							last_off <= stage3_off;
						end
					end
				end else begin

				// --- STAGE 2: DECODE TOKEN OR CALCULATE ADDRESS ---
				stage3_valid <= 1'b0;
				if (stage2_valid) begin
					if (stage2_data == 28'hFFFFFFF) begin
						// RECEIVED EOF TOKEN!
						// DIAG_FB_SCANOUT: skip rotation+reclear so buf1 stays static (vectors accumulate).
						if (!OSD_FLICKER && !DIAG_FB_SCANOUT) begin
							logic [1:0] next_free_buf;

							// 1. Stash the pointer of the buffer we just finished drawing
							ready_buf <= draw_buf;

							// 2. Find the 3rd unused buffer.
							// We cannot use the currently displayed buffer (display_buf)
							// We cannot use the buffer we JUST finished (draw_buf, which is becoming ready_buf)
							if      (display_buf != 2'd0 && draw_buf != 2'd0) next_free_buf = 2'd0;
							else if (display_buf != 2'd1 && draw_buf != 2'd1) next_free_buf = 2'd1;
							else                                              next_free_buf = 2'd2;

							// 2b. Record the drawn-row band of the buffer we just finished (draw_buf is
							// still the OLD/finished buffer here), then reset for the next frame.
							if (cur_ymin <= cur_ymax) begin
								buf_ymin[draw_buf] <= cur_ymin;  buf_ymax[draw_buf] <= cur_ymax;
							end else begin
								buf_ymin[draw_buf] <= 10'd0;     buf_ymax[draw_buf] <= 10'd719;  // nothing drawn -> full
							end
							cur_ymin <= 10'd719; cur_ymax <= 10'd0;

							// 3. Assign BOTH registers to the newly calculated free buffer
							draw_buf         <= next_free_buf;
							clear_target_buf <= next_free_buf;

							// 4. Trigger clear over the NEW buffer's tracked band.  The START address is
							// latched from next_free_buf HERE (clear_target_buf only updates next cycle, so
							// the clr_start wire still reflects the old target this cycle); the END
							// (clr_burst_end, = f(clear_target_buf)) is valid by the time it is compared.
							clearing   <= 1'b1;
							clear_addr <= clr_full ? 19'd0
							            : { ((buf_ymin[next_free_buf] >= 10'd2) ? (buf_ymin[next_free_buf] - 10'd2) : 10'd0), 9'd0 };
							// SELECTIVE-ERASE: replay next_free's recorded words as black (fast) UNLESS
							// this is a boot full-clear or that buffer's last frame overflowed the list.
							// next_free_buf becomes clear_target_buf next cycle, so the replay reads
							// dirty_wptr[clear_target_buf] = next_free's stale (= current-content) count.
							use_replay <= USE_SELECTIVE_ERASE && !clr_full && !dirty_ovf[next_free_buf];
							erase_idx  <= 16'd0;
							estate     <= E_READ;
						end
					end  else begin
						// Normal Pixel Assignments
						// stage2_data: {Z[4:0], RGB[2:0], Y[9:0], X[9:0]}
						pixel_z = stage2_data[27:23];
						pixel_c = stage2_data[22:20];
						pixel_y = stage2_data[19:10];
						pixel_x = stage2_data[9:0];
						
						// Safety bounds check (defense-in-depth)
						if (pixel_x < 10'd980 && pixel_y < 10'd720) begin
							// byte offset within buffer = Y*4096 + X*4 (stride 4096 = 2^12)
							computed_pixel_addr = {pixel_y, 12'd0} + {pixel_x, 2'd0};
							chan = {pixel_z, pixel_z[4:2]};  // == old palette channel_val
							
							stage3_addr  <= draw_base_word + computed_pixel_addr[22:3];
							stage3_off   <= computed_pixel_addr[22:3];   // SELECTIVE-ERASE: word offset to record
							stage3_slot  <= computed_pixel_addr[2];
							stage3_pixel <= {8'h00,
							                 pixel_c[0] ? chan : 8'h00,   // B (23:16)
							                 pixel_c[1] ? chan : 8'h00,   // G (15:8)
							                 pixel_c[2] ? chan : 8'h00};  // R (7:0)
							stage3_valid <= 1'b1;
							// content-adaptive clear: grow this frame's drawn-row band
							if (pixel_y < cur_ymin) cur_ymin <= pixel_y;
							if (pixel_y > cur_ymax) cur_ymax <= pixel_y;
						end
					end
				end

				// --- STAGE 1: FETCH FROM FIFO ---
				stage2_valid <= !fifo_empty;
				
				if (!fifo_empty) begin
					rd_ptr <= rd_ptr + 1'b1;
					rd_ptr_g <= b2g(rd_ptr + 1'b1);
				end
				end // RMW_IDLE: pipeline-advance else

				// ---- READ: capture the target word, then write ----
				RMW_READ: begin
					ddram_rd_reg <= 1'b0;
					if (DDRAM_DOUT_READY) begin
						rmw_rdword <= DDRAM_DOUT;
						rmw_state  <= RMW_WRITE;
					end
				end

				// ---- WRITE: merged full word (overwrite slot; Phase 3 = sat-ADD) ----
				RMW_WRITE: begin
					ddram_addr_reg  <= stage3_addr;
					ddram_din_reg   <= merged_word;
					ddram_be_reg    <= 8'hFF;
					ddram_burst_reg <= 8'd1;
					ddram_we_reg    <= 1'b1;
					stage3_valid    <= 1'b0;
					rmw_state       <= RMW_IDLE;
				end
				endcase
			end
		end
	end

endmodule