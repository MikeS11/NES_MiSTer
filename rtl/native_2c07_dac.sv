// native_2c07_dac.sv
//
// PAL 2C07 / UA6538-style composite video DAC helper for MiSTer FPGA analog outputs.
//
// MiSTer-oriented output contract:
//   - composite_out is an unsigned 8-bit DAC code, 0..255.
//   - The output layer supplies sync externally. During sync intervals this
//     waveform holds black/blank level while the external sync path supplies
//     the sync tip.
//   - The DAC mapping keeps colorburst-low and $0D below black, matching the
//     relative ordering of NESdev's terminated measurements.
//
// NESdev source references:
//   https://www.nesdev.org/wiki/PAL_video
//   https://www.nesdev.org/wiki/NTSC_video
//
// NESdev sections mapped in this code:
//   1) PAL video: overview / differences from NTSC
//      - 2C07 / 6538 generate composite PAL much like the 2C02 generates NTSC:
//        a square wave between high and low levels, using 12 oscillators.
//      - PAL-B subcarrier is 4.43361875 MHz; the PAL PPU master crystal is
//        6x this rate, 26.6017125 MHz. This module expects the caller to feed
//        clk_video at 12x PAL subcarrier (~53.2034375 MHz), one tick per
//        oscillator half-phase.
//      - Implemented in section 1 with the 12-state phase counter.
//
//   2) PAL video: phase alternating line / color phases
//      - PAL inverts the V subcarrier on alternate scanlines.
//      - NESdev lists the hue pairs used on alternating lines:
//          3/2, 4/1, 5/C, 6/B, 7/A, 8/9.
//      - PAL colorburst is associated with phase 7; its paired phase is A.
//      - Implemented in sections 2, 3, and 6.
//
//   3) NTSC video: brightness levels / terminated measurements
//      - NESdev provides measured 75 ohm NES levels:
//          SYNC 48 mV, CBL 148 mV, 0D 228 mV, 1D 312 mV,
//          CBH 524 mV, 2D 552 mV, 00 616 mV, 10 840 mV,
//          3D 880 mV, 20/30 1100 mV.
//      - NESdev describes the PAL PPU as generating video in much the same
//        square-wave way as NTSC. This MiSTer DAC uses the same practical level
//        mapping as the NTSC DAC, ready to replace with PAL-specific measured
//        values if a reliable table is supplied.
//      - Implemented in section 4.
//
//   4) NTSC video: palette voltage rules
//      - $xE/$xF output the same voltage as $1D.
//      - $x1-$xC alternate between $xD and $x0 levels.
//      - $x0 outputs only high; $xD-$xF output only low.
//      - Implemented in sections 4 and 5.
//
//   5) NTSC video: color tint bits
//      - NESdev says emphasis attenuates the waveform during selected phases
//        and does not affect black columns $E/$F, but does affect column $D.
//      - NESdev also notes that on PAL/Dendy, the green and red bits swap
//        meaning. In this MiSTer NES core, PPU.sv already swaps PPUMASK bits
//        for PAL/Dendy before exporting emphasis[2:0], so this DAC treats
//        emphasis[2:0] as already PAL-corrected.
//      - Implemented in section 6.
//
// DAC scaling:
//   composite_out maps NESdev terminated voltages into the MiSTer 8-bit DAC.
//   Since sync is carried externally, the useful waveform range starts at
//   colorburst-low rather than the 48 mV sync tip:
//
//      DAC = round((V - 148 mV) * 255 / (1100 mV - 148 mV))
//
//   Resulting unsigned codes:
//
//      CBL             0   colorburst low rail, 148 mV
//      $0D            21   below-black palette rail, 228 mV
//      $1D/blank      44   black level, 312 mV
//      CBH           101   colorburst high rail, 524 mV
//      $2D           108   luma row 2 low rail, 552 mV
//      $00           125   luma row 0 high rail, 616 mV
//      $10           185   luma row 1 high rail, 840 mV
//      $3D           196   luma row 3 low rail, 880 mV
//      $20/$30       255   white rail, 1100 mV
//
// PAL implementation notes:
//   - Phase alternation is implemented in the waveform domain by pairing hues
//     on odd lines before the phase comparator.
//   - Colorburst uses phase 7 on one line and the paired A phase on the next.
//   - PPUMASK emphasis attenuation is applied to active picture samples only.

module native_2c07_dac (
    input  wire       clk_video,     // ~53.203 MHz: 12x PAL colorburst
    input  wire       reset,
    input  wire [5:0] nes_color,     // 6-bit PPU palette index after PPU grayscale handling: llhhhh
    input  wire [2:0] emphasis,      // PPUMASK[7:5] from PPU.sv; already PAL/Dendy red-green swapped there
    input  wire       sync,          // Sync interval; composite_out holds black while sync is supplied externally
    input  wire       hsync,         // Raw horizontal sync, used for PAL line alternation
    input  wire       blank,         // Blanking period: hblank | vblank
    input  wire       colorburst_en, // High during back porch burst window
    output reg  [7:0] composite_out  // Composite-style video DAC code; black=44, white=255
);

    // -----------------------------------------------------------
    // 1. Free-running 12-phase PAL subcarrier counter
    // -----------------------------------------------------------
    // NESdev "PAL video":
    //   PAL-B subcarrier = 4.43361875 MHz.
    //   2C07/6538 still use 12 oscillators; this module runs at 12x Fsc.
    reg [3:0] phase;
    always @(posedge clk_video) begin
        if (reset) begin
            phase <= 4'd0;
        end
        else begin
            phase <= (phase == 4'd11) ? 4'd0 : (phase + 4'd1);
        end
    end

    // Small modulo-12 helper for 0..30 input values.
    function automatic [3:0] mod12;
        input [4:0] x;
        begin
            if (x >= 5'd24)      mod12 = x - 5'd24;
            else if (x >= 5'd12) mod12 = x - 5'd12;
            else                 mod12 = x[3:0];
        end
    endfunction

    // NESdev "PAL video" hue-pair mapping for odd/even line alternation.
    function automatic [3:0] pal_pair_hue;
        input [3:0] hue;
        begin
            case (hue)
                4'h1: pal_pair_hue = 4'h4;
                4'h2: pal_pair_hue = 4'h3;
                4'h3: pal_pair_hue = 4'h2;
                4'h4: pal_pair_hue = 4'h1;
                4'h5: pal_pair_hue = 4'hC;
                4'h6: pal_pair_hue = 4'hB;
                4'h7: pal_pair_hue = 4'hA;
                4'h8: pal_pair_hue = 4'h9;
                4'h9: pal_pair_hue = 4'h8;
                4'hA: pal_pair_hue = 4'h7;
                4'hB: pal_pair_hue = 4'h6;
                4'hC: pal_pair_hue = 4'h5;
                default: pal_pair_hue = hue; // 0, D, E, F unchanged
            endcase
        end
    endfunction

    // -----------------------------------------------------------
    // 2. PAL line alternation tracking
    // -----------------------------------------------------------
    reg odd_line;
    reg prev_hsync;
    always @(posedge clk_video) begin
        if (reset) begin
            odd_line   <= 1'b0;
            prev_hsync <= 1'b0;
        end
        else begin
            prev_hsync <= hsync;
            if (prev_hsync && !hsync) begin
                odd_line <= ~odd_line;
            end
        end
    end

    // -----------------------------------------------------------
    // 3. Decode PPU palette entry with PAL hue swapping
    // -----------------------------------------------------------
    wire [3:0] raw_hue   = nes_color[3:0];
    wire [1:0] luma_bits = nes_color[5:4];
    wire [3:0] hue_bits  = odd_line ? pal_pair_hue(raw_hue) : raw_hue;

    // NESdev "Brightness Levels":
    //   $xE/$xF output the same voltage as $1D.
    // Use original hue for this rule; PAL pairing does not change E/F.
    wire [1:0] eff_level = (raw_hue >= 4'hE) ? 2'd1 : luma_bits;

    // -----------------------------------------------------------
    // 4. NESdev voltage levels converted to MiSTer DAC codes
    // -----------------------------------------------------------

    // 4A. Composite-style output codes.
    //     These are the NESdev terminated voltages scaled with the formula in
    //     the file header. Keep CBL and $0D below COMP_BLACK; those sub-black
    //     rails are part of the composite waveform and affect decoder behavior.
    localparam [7:0] COMP_CBL   = 8'd0;    // CBL: colorburst low rail, 148 mV
    localparam [7:0] COMP_0D    = 8'd21;   // $0D: level-0 low rail / below black, 228 mV
    localparam [7:0] COMP_BLACK = 8'd44;   // $1D: black and blanking level, 312 mV
    localparam [7:0] COMP_CBH   = 8'd101;  // CBH: colorburst high rail, 524 mV
    localparam [7:0] COMP_2D    = 8'd108;  // $2D: level-2 low rail, 552 mV
    localparam [7:0] COMP_00    = 8'd125;  // $00: level-0 high rail, 616 mV
    localparam [7:0] COMP_10    = 8'd185;  // $10: level-1 high rail, 840 mV
    localparam [7:0] COMP_3D    = 8'd196;  // $3D: level-3 low rail, 880 mV
    localparam [7:0] COMP_WHITE = 8'd255;  // $20/$30: white high rail, 1100 mV

    // 4B. Composite-style emphasis/tint attenuated codes.
    // NESdev terminated measurements include attenuated levels:
    //   0Dem 192 mV, 1Dem 256 mV, 2Dem 448 mV, 00em 500 mV,
    //   10em 676 mV, 3Dem 712 mV, 20em 896 mV.
    // These use the same CBL-to-white scaling as the plain waveform codes.
    localparam [7:0] COMP_0D_EM    = 8'd12;   // 0Dem, 192 mV
    localparam [7:0] COMP_BLACK_EM = 8'd29;   // 1Dem, 256 mV
    localparam [7:0] COMP_2D_EM    = 8'd80;   // 2Dem, 448 mV
    localparam [7:0] COMP_00_EM    = 8'd94;   // 00em, 500 mV
    localparam [7:0] COMP_10_EM    = 8'd141;  // 10em, 676 mV
    localparam [7:0] COMP_3D_EM    = 8'd151;  // 3Dem, 712 mV
    localparam [7:0] COMP_WHITE_EM = 8'd200;  // 20em, 896 mV

    reg [7:0] comp_low, comp_high;
    reg [7:0] comp_low_em, comp_high_em;

    // For palette colors $x1-$xC, NESdev models each luma row as a square
    // wave between that row's low rail ($xD) and high rail ($x0). Grays and
    // black columns override this in section 5.
    always @(*) begin
        case (eff_level)
            2'd0: begin
                // Palette row $0Y: low = $0D, high = $00.
                comp_low     = COMP_0D;
                comp_high    = COMP_00;
                comp_low_em  = COMP_0D_EM;
                comp_high_em = COMP_00_EM;
            end

            2'd1: begin
                // Palette row $1Y: low = $1D, high = $10.
                comp_low     = COMP_BLACK;
                comp_high    = COMP_10;
                comp_low_em  = COMP_BLACK_EM;
                comp_high_em = COMP_10_EM;
            end

            2'd2: begin
                // Palette row $2Y: low = $2D, high = $20.
                comp_low     = COMP_2D;
                comp_high    = COMP_WHITE;
                comp_low_em  = COMP_2D_EM;
                comp_high_em = COMP_WHITE_EM;
            end

            default: begin
                // Palette row $3Y: low = $3D, high = $30.
                // NESdev measures $20 and $30 at the same white voltage.
                comp_low     = COMP_3D;
                comp_high    = COMP_WHITE;
                comp_low_em  = COMP_3D_EM;
                comp_high_em = COMP_WHITE_EM;
            end
        endcase
    end

    // -----------------------------------------------------------
    // 5. Apply NESdev PPU color rules
    // -----------------------------------------------------------
    // NESdev "Brightness Levels":
    //   $x0:       only HIGH emitted. These are grays.
    //   $x1-$xC:   square wave alternates LOW <-> HIGH.
    //   $xD-$xF:   only LOW emitted.
    //   $xE/$xF:   force level 1, handled above, so they output $1D black.
    wire is_gray_column  = (raw_hue == 4'h0);
    wire is_low_only_col = (raw_hue >= 4'hD);

    // Select the two rails that the phase generator can choose between.
    // $x0 grays use the high rail for both halves of the cycle.
    // $xD-$xF black columns use the low rail for both halves of the cycle.
    wire [7:0] comp_eff_low  = is_gray_column  ? comp_high : comp_low;
    wire [7:0] comp_eff_high = is_low_only_col ? comp_low  : comp_high;

    wire [7:0] comp_eff_low_em  = is_gray_column  ? comp_high_em : comp_low_em;
    wire [7:0] comp_eff_high_em = is_low_only_col ? comp_low_em  : comp_high_em;

    // -----------------------------------------------------------
    // 6. Phase detection for active video, burst, and emphasis
    // -----------------------------------------------------------
    // NESdev "PAL video / Color Phases":
    //   Color wave selected by hue, with PAL line pairing applied.
    wire [3:0] active_phase   = mod12({1'b0, phase} + {1'b0, hue_bits});
    wire       in_color_phase = (active_phase < 4'd6);

    // PAL colorburst is phase 7; use the paired phase A on alternate lines.
    wire [3:0] burst_hue   = odd_line ? 4'hA : 4'h7;
    wire [3:0] burst_phase = mod12({1'b0, phase} + {1'b0, burst_hue});
    wire       burst_high  = (burst_phase < 4'd6);

    // Emphasis/tint phases. NESdev documents the PAL/Dendy red/green meaning
    // swap; using the PAL-paired phase on odd lines is inferred from the PAL
    // hue-pair oscillator mapping.
    wire [3:0] emph_hue_8 = odd_line ? pal_pair_hue(4'h8) : 4'h8;
    wire [3:0] emph_hue_4 = odd_line ? pal_pair_hue(4'h4) : 4'h4;
    wire [3:0] emph_hue_c = odd_line ? pal_pair_hue(4'hC) : 4'hC;

    wire emph_phase_8 = (mod12({1'b0, phase} + {1'b0, emph_hue_8}) < 4'd6);
    wire emph_phase_4 = (mod12({1'b0, phase} + {1'b0, emph_hue_4}) < 4'd6);
    wire emph_phase_c = (mod12({1'b0, phase} + {1'b0, emph_hue_c}) < 4'd6);

    // PPU.sv already swaps red/green PPUMASK meanings for PAL/Dendy, so keep
    // the same emphasis[2]/[1]/[0] phase interpretation here.
    wire emphasis_active_phase =
        (emphasis[2] & emph_phase_8) |
        (emphasis[1] & emph_phase_4) |
        (emphasis[0] & emph_phase_c);

    // NESdev: emphasis does not affect black colors in columns $E/$F, but
    // does affect all other columns, including the black/gray column $D.
    wire emphasis_allowed_for_color = (raw_hue != 4'hE) && (raw_hue != 4'hF);

    // Do not tint the sync/blanking/burst interval here. Apply only to active
    // picture samples.
    wire apply_emphasis_now = emphasis_allowed_for_color && emphasis_active_phase;

    wire [7:0] comp_sample_plain = in_color_phase ? comp_eff_high : comp_eff_low;
    wire [7:0] comp_sample_emph  = in_color_phase ? comp_eff_high_em : comp_eff_low_em;
    wire [7:0] comp_sample_final = apply_emphasis_now ? comp_sample_emph : comp_sample_plain;

    // Output priority:
    //   sync interval        -> black/blank level; sync tip is supplied externally
    //   blank + burst        -> PAL CBL/CBH burst rails, phase 7/A by line
    //   blank without burst  -> black/blank level
    //   active picture       -> phase-selected palette rail, with emphasis applied
    wire [7:0] comp_out_next = sync ? COMP_BLACK :
                               blank ? (colorburst_en ?
                                      (burst_high ? COMP_CBH : COMP_CBL) :
                                      COMP_BLACK) :
                               comp_sample_final;

    // -----------------------------------------------------------
    // 7. Final DAC output
    // -----------------------------------------------------------
    // Register one composite sample per clk_video tick. For PAL this is 12
    // samples per 4.43361875 MHz colorburst cycle.
    always @(posedge clk_video) begin
        if (reset) begin
            composite_out <= COMP_BLACK;
        end
        else begin
            composite_out <= comp_out_next;
        end
    end

endmodule
