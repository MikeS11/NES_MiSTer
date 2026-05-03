// native_2c02_dac.sv
//
// NES 2C02-style NTSC DAC helper for MiSTer FPGA analog outputs.
//
// MiSTer-oriented output contract:
//   - composite_out is an unsigned 8-bit DAC code, 0..255.
//   - The output layer supplies sync externally. During sync intervals this
//     waveform holds black/blank level while the external sync path supplies
//     the sync tip.
//   - The DAC mapping keeps colorburst-low and $0D below black, matching the
//     relative ordering of NESdev's terminated measurements.
//
// NESdev source reference:
//   https://www.nesdev.org/wiki/NTSC_video
//
// NESdev sections mapped in this code:
//   1) "Brightness Levels" / "Terminated measurement"
//      - Uses the measured 75 ohm values:
//          SYNC 48 mV, CBL 148 mV, 0D 228 mV, 1D 312 mV,
//          CBH 524 mV, 2D 552 mV, 00 616 mV, 10 840 mV,
//          3D 880 mV, 20/30 1100 mV.
//      - NESdev also states:
//          $xE/$xF output the same voltage as $1D.
//          $x1-$xC alternate between $xD and $x0 levels.
//          $x0 outputs only the high level.
//          $xD-$xF output only the low level.
//      - Implemented below in sections 3 and 4.
//
//   2) "Color Phases"
//      - NESdev states that the color generator is clocked on both edges of
//        the ~21.477 MHz master clock, giving an effective ~42.95 MHz clock,
//        with 12 phase-spaced square waves at the ~3.58 MHz colorburst rate.
//      - Implemented below with the 12-state phase counter and
//        (phase + hue) % 12 < 6 logic.
//
//   3) "Color Tint Bits"
//      - NESdev describes PPUMASK emphasis / tint bits and attenuation.
//      - Implemented here using the PPU's exported emphasis[2:0] signal:
//          emphasis[2] = PPUMASK bit 7, active on color-8 phase.
//          emphasis[1] = PPUMASK bit 6, active on color-4 phase.
//          emphasis[0] = PPUMASK bit 5, active on color-C phase.
//      - Attenuation is applied only in active picture, not to sync/blanking
//        or colorburst.
//      - Per NESdev, columns $xE/$xF are not affected; column $xD is affected.
//
//   4) "Grayscale"
//      - NESdev states that when grayscale is active, colors $x1-$xD are
//        treated as $x0.
//      - In this MiSTer NES core, PPU.sv applies grayscale before driving the
//        6-bit color output.
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

module native_2c02_dac (
    input  wire       clk_42m,       // ~42.95 MHz: 12x NTSC colorburst
    input  wire       reset,
    input  wire [5:0] nes_color,     // 6-bit PPU palette index after PPU grayscale handling: llhhhh
    input  wire [2:0] emphasis,      // PPUMASK[7:5] from PPU.sv; NTSC order: bit7, bit6, bit5
    input  wire       sync,          // Sync interval; composite_out holds black while sync is supplied externally
    input  wire       blank,         // Blanking period: hblank | vblank
    input  wire       colorburst_en, // High during back porch burst window
    output reg  [7:0] composite_out  // Composite-style video DAC code; black=44, white=255
);

    // -----------------------------------------------------------
    // 1. Free-running 12-phase subcarrier counter
    // -----------------------------------------------------------
    // NESdev "Color Phases":
    //   Effective ~42.95 MHz color-generator clock.
    //   12 half-clock states per 3.579545 MHz colorburst cycle.
    reg [3:0] phase;
    always @(posedge clk_42m) begin
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

    // -----------------------------------------------------------
    // 2. Decode PPU palette entry
    // -----------------------------------------------------------
    wire [3:0] hue_bits_raw = nes_color[3:0];
    wire [1:0] luma_bits    = nes_color[5:4];

    // NESdev "Brightness Levels":
    //   $xE/$xF output the same voltage as $1D.
    // This forces columns E/F to brightness level 1.
    wire [1:0] eff_level = (hue_bits_raw >= 4'hE) ? 2'd1 : luma_bits;

    // -----------------------------------------------------------
    // 3. NESdev voltage levels converted to MiSTer DAC codes
    // -----------------------------------------------------------

    // 3A. Composite-style output codes.
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

    // 3B. Composite-style emphasis/tint attenuated codes.
    // NESdev "Terminated measurement" also lists attenuated measurements:
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
    // black columns override this in section 4.
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
    // 4. Apply NESdev PPU color rules
    // -----------------------------------------------------------
    // NESdev "Brightness Levels":
    //   $x0:       only HIGH emitted. These are grays.
    //   $x1-$xC:   square wave alternates LOW <-> HIGH.
    //   $xD-$xF:   only LOW emitted.
    //   $xE/$xF:   force level 1, handled above, so they output $1D black.
    wire is_gray_column  = (hue_bits_raw == 4'h0);
    wire is_low_only_col = (hue_bits_raw >= 4'hD);

    // Select the two rails that the phase generator can choose between.
    // $x0 grays use the high rail for both halves of the cycle.
    // $xD-$xF black columns use the low rail for both halves of the cycle.
    wire [7:0] comp_eff_low  = is_gray_column  ? comp_high : comp_low;
    wire [7:0] comp_eff_high = is_low_only_col ? comp_low  : comp_high;

    wire [7:0] comp_eff_low_em  = is_gray_column  ? comp_high_em : comp_low_em;
    wire [7:0] comp_eff_high_em = is_low_only_col ? comp_low_em  : comp_high_em;

    // -----------------------------------------------------------
    // 5. Phase detection for active video and colorburst
    // -----------------------------------------------------------
    // NESdev "Color Phases":
    //   Color $xY uses wave Y.
    //   Active high for 6 of the 12 half-clock phases.
    //   NTSC colorburst is the same phase as color 8.
    wire [3:0] active_phase   = mod12({1'b0, phase} + {1'b0, hue_bits_raw});
    wire       in_color_phase = (active_phase < 4'd6);

    wire [3:0] burst_phase = mod12({1'b0, phase} + 5'd8);
    wire       burst_high  = (burst_phase < 4'd6);

    // NESdev "Color Tint Bits":
    //   PPUMASK bit 7 -> Color 8 phase
    //   PPUMASK bit 6 -> Color 4 phase
    //   PPUMASK bit 5 -> Color C phase
    // The attenuator is shared, so the active windows OR together.
    wire emph_phase_8 = (mod12({1'b0, phase} + 5'd8 ) < 4'd6);
    wire emph_phase_4 = (mod12({1'b0, phase} + 5'd4 ) < 4'd6);
    wire emph_phase_c = (mod12({1'b0, phase} + 5'd12) < 4'd6);

    wire emphasis_active_phase =
        (emphasis[2] & emph_phase_8) |
        (emphasis[1] & emph_phase_4) |
        (emphasis[0] & emph_phase_c);

    // NESdev: emphasis does not affect black colors in columns $E/$F, but
    // does affect all other columns, including the black/gray column $D.
    wire emphasis_allowed_for_color = (hue_bits_raw != 4'hE) && (hue_bits_raw != 4'hF);

    // Do not tint the sync/blanking/burst interval here. Apply only to active
    // picture samples.
    wire apply_emphasis_now = emphasis_allowed_for_color && emphasis_active_phase;

    wire [7:0] comp_sample_plain = in_color_phase ? comp_eff_high : comp_eff_low;
    wire [7:0] comp_sample_emph  = in_color_phase ? comp_eff_high_em : comp_eff_low_em;
    wire [7:0] comp_sample_final = apply_emphasis_now ? comp_sample_emph : comp_sample_plain;

    // Output priority:
    //   sync interval     -> black/blank level; sync tip is supplied externally
    //   blank + burst     -> NESdev CBL/CBH burst rails at color-8 phase
    //   blank without burst -> black/blank level
    //   active picture    -> phase-selected palette rail, with emphasis applied
    wire [7:0] comp_raw_next = sync ? COMP_BLACK :
                               blank ? (colorburst_en ?
                                      (burst_high ? COMP_CBH : COMP_CBL) :
                                      COMP_BLACK) :
                               comp_sample_final;

    // -----------------------------------------------------------
    // 6. Final DAC output
    // -----------------------------------------------------------
    // Register one composite sample per 42.95 MHz tick. At this rate there are
    // 8 DAC samples per PPU pixel and 12 samples per NTSC colorburst cycle.
    always @(posedge clk_42m) begin
        if (reset) begin
            composite_out <= COMP_BLACK;
        end
        else begin
            composite_out <= comp_raw_next;
        end
    end

endmodule
