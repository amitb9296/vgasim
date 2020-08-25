////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	axishdmi
//
// Project:	vgasim, a Verilator based VGA simulator demonstration
//
// Purpose:	Generates the timing signals (not the clock) for an outgoing
//		video signal, and then encodes the incoming pixels into
//	an HDMI data stream.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2018-2020, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	axishdmi #(
		// {{{
		parameter	HW=12,
				VW=12,
		// HDMI *only* works with 24-bit color, using 8-bits per color
		localparam	BITS_PER_COLOR = 8,
		localparam	BPC = BITS_PER_COLOR,
				BITS_PER_PIXEL = 3 * BPC,
				BPP = BITS_PER_PIXEL
		// }}}
	) (
		// {{{
		input	wire	i_pixclk,
		// Verilator lint_off SYNCASYNCNET
		input	wire			i_reset,
		// Verilator lint_on SYNCASYNCNET
		//
		// AXI Stream interface
		// {{{
		input	wire		i_valid,
		output	reg		o_ready,
		input	wire		i_hlast,
		input	wire		i_vlast,
		input	wire [BPP-1:0]	i_rgb_pix,
		// }}}
		//
		// Video mode information
		// {{{
		input	wire [HW-1:0]	i_hm_width,
		input	wire [HW-1:0]	i_hm_porch,
		input	wire [HW-1:0]	i_hm_synch,
		input	wire [HW-1:0]	i_hm_raw,
		//
		input	wire [VW-1:0]	i_vm_height,
		input	wire [VW-1:0]	i_vm_porch,
		input	wire [VW-1:0]	i_vm_synch,
		input	wire [VW-1:0]	i_vm_raw,
		// }}}
		//
		// HDMI outputs
		// {{{
		output	wire	[9:0]	o_red,
		output	wire	[9:0]	o_grn,
		output	wire	[9:0]	o_blu
		// }}}
		// }}}
	);

	// Register declarations
	// {{{
	reg		r_newline, r_newframe, lost_sync;
	reg		vsync, hsync;
	reg	[1:0]	hdmi_type;
	reg	[3:0]	hdmi_ctl;
	reg	[11:0]	hdmi_data;
	reg	[7:0]	red_pixel, grn_pixel, blu_pixel;
	reg		pre_line;
	reg		first_frame;

	wire			w_rd;
	wire	[BPC-1:0]	i_red, i_grn, i_blu;
	assign	i_red = i_rgb_pix[3*BPC-1:2*BPC];
	assign	i_grn = i_rgb_pix[2*BPC-1:  BPC];
	assign	i_blu = i_rgb_pix[  BPC-1:0];

	reg	[HW-1:0]	hpos;
	reg	[VW-1:0]	vpos;
	reg			hrd, vrd;
	reg		pix_reset;
	reg	[1:0]	pix_reset_pipe;
`ifdef	FORMAL
	wire	[47:0]		f_vmode, f_hmode;
`endif
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Synchronize the reset release
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	initial	{ pix_reset, pix_reset_pipe } = -1;
	always @(posedge i_pixclk, posedge i_reset)
	if (i_reset)
		{ pix_reset, pix_reset_pipe } <= -1;
	else
		{ pix_reset, pix_reset_pipe } <= { pix_reset_pipe, 1'b0 };
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Horizontal line counting
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// hpos, r_newline, hsync, hrd
	// {{{
	initial	hpos       = 0;
	initial	r_newline  = 0;
	initial	hsync = 0;
	initial	hrd = 1;
	always @(posedge i_pixclk)
	if (pix_reset)
	begin
		hpos <= 0;
		r_newline <= 1'b0;
		hsync <= 1'b0;
		hrd <= 1;
	end else begin
		hrd <= (hpos < i_hm_width-2)
				||(hpos >= i_hm_raw-2);
		if (hpos < i_hm_raw-1'b1)
			hpos <= hpos + 1'b1;
		else
			hpos <= 0;
		r_newline <= (hpos == i_hm_width-3);
		hsync <= (hpos >= i_hm_porch-1'b1)&&(hpos<i_hm_synch-1'b1);
	end
	// }}}

	// lost_sync detection
	// {{{
	initial	lost_sync = 1;
	always @(posedge i_pixclk)
	if (pix_reset)
		lost_sync <= 1;
	else if (w_rd)
	begin
		if (r_newframe && i_hlast && i_vlast && i_valid)
			lost_sync <= 0;
		else begin
			if (!i_valid)
				lost_sync <= 1;
			if (i_hlast != r_newline)
				lost_sync <= 1;
			if ((i_vlast && i_hlast) != r_newframe)
				lost_sync <= 1;
		end
	end
	// }}}
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Vertical line counting
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// r_newframe
	// {{{
	initial	r_newframe = 0;
	always @(posedge i_pixclk)
	if (pix_reset)
		r_newframe <= 1'b0;
	else if ((hpos == i_hm_width - 3)&&(vpos == i_vm_height-1))
		r_newframe <= 1'b1;
	else
		r_newframe <= 1'b0;
	// }}}

	// vpos, vsync
	// {{{
	initial	vpos = 0;
	initial	vsync = 1'b0;
	always @(posedge i_pixclk)
	if (pix_reset)
	begin
		vpos <= 0;
		vsync <= 1'b0;
	end else if (hpos == i_hm_porch-1'b1)
	begin
		if (vpos < i_vm_raw-1'b1)
			vpos <= vpos + 1'b1;
		else
			vpos <= 0;
		// Realistically, the new frame begins at the top
		// of the next frame.  Here, we define it as the end
		// last valid row.  That gives any software depending
		// upon this the entire time of the front and back
		// porches, together with the synch pulse width time,
		// to prepare to actually draw on this new frame before
		// the first pixel clock is valid.
		vsync <= (vpos >= i_vm_porch-1'b1)&&(vpos<i_vm_synch-1'b1);
	end
	// }}}

	// vrd
	// {{{
	initial	vrd = 1'b1;
	always @(posedge i_pixclk)
		vrd <= (vpos < i_vm_height)&&(!pix_reset);
	// }}}

	// first_frame
	// {{{
	initial	first_frame = 1'b1;
	always @(posedge i_pixclk)
	if (pix_reset)
		first_frame <= 1'b1;
	else if (r_newframe)
		first_frame <= 1'b0;
	// }}}
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI-stream Ready generation
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//


	// w_rd
	// {{{
	assign	w_rd = (hrd)&&(vrd)&&(!first_frame);
	// }}}

	// o_ready
	// {{{
	always @(*)
	if (lost_sync)
		o_ready = (!i_vlast || !i_hlast) || (r_newframe && w_rd);
	else
		o_ready = w_rd;
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// HDMI encoding
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//


	// Set *_pixel values
	// {{{
	always @(posedge i_pixclk)
	if (w_rd)
	begin
		if (lost_sync)
		begin
			red_pixel <= 0;
			grn_pixel <= 0;
			blu_pixel <= 0;
		end else begin
			red_pixel <= i_red;
			grn_pixel <= i_grn;
			blu_pixel <= i_blu;
		end
	end else begin
		red_pixel <= 0;
		grn_pixel <= 0;
		blu_pixel <= 0;
	end
	// }}}

	// hdmi_type
	// {{{
	localparam	[1:0]	GUARD = 2'b00;
	localparam	[1:0]	CTL_PERIOD  = 2'b01;
	localparam	[1:0]	DATA_ISLAND = 2'b10;
	localparam	[1:0]	VIDEO_DATA  = 2'b11;
	localparam		GUARD_PIXELS= 2,
				PREGUARD_CONTROL = 6;

	initial	pre_line = 1'b1;
	always @(posedge i_pixclk)
	if (pix_reset)
		pre_line <= 1'b1;
	else
		pre_line <= (vpos < i_vm_height);

	initial	hdmi_type = GUARD;
	always @(posedge i_pixclk)
	if (pix_reset)
		hdmi_type <= GUARD;
	else if (pre_line)
	begin
		if (hpos >= i_hm_raw - 1)
			hdmi_type <= VIDEO_DATA;
		else if (hpos < i_hm_width - 1)
			hdmi_type <= VIDEO_DATA;
		else if (hpos >= i_hm_raw - 1-GUARD_PIXELS)
			hdmi_type <= GUARD;
		else
			hdmi_type <= CTL_PERIOD;
	end else
		hdmi_type <= CTL_PERIOD;

	always @(*)
		hdmi_ctl = 4'h1;
	// }}}

	// hdmi_data
	// {{{
	always @(*)
	begin
		hdmi_data[1:0]	= { vsync, hsync };
		hdmi_data[11:2] = 0;
	end
	// }}}

	// TMDS encoding
	// {{{
`ifdef	FORMAL
	(* anyseq *) reg [9:0]	w_blu, w_grn, w_red;
	//
	// Verific complains of logic loops within tmdsencode.  Since the TMDS
	// encoder isn't really a part of our formal proof, we can cut it out
	// here and replace it's results with ... whatever we want ... just to
	// get the proof to pass.
	//

	assign	o_red = w_red;
	assign	o_grn = w_grn;
	assign	o_blu = w_blu;
`else
	// Channel 0 = blue
	tmdsencode #(.CHANNEL(2'b00)) hdmi_encoder_ch0(i_pixclk,
			hdmi_type, { vsync, hsync },
			hdmi_data[3:0], blu_pixel, o_blu);

	// Channel 1 = green
	tmdsencode #(.CHANNEL(2'b01)) hdmi_encoder_ch1(i_pixclk,
			hdmi_type, hdmi_ctl[1:0],
			hdmi_data[7:4], grn_pixel, o_grn);

	// Channel 2 = red
	tmdsencode #(.CHANNEL(2'b10)) hdmi_encoder_ch2(i_pixclk,
			hdmi_type, hdmi_ctl[3:2],
			hdmi_data[11:8], red_pixel, o_red);
`endif
	// }}}

	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal properties for verification purposes
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	reg	f_past_valid;

	////////////////////////////////////////////////////////////////////////
	//
	// Reset assumptions
	//
	initial	f_past_valid = 1'b0;
	always @(posedge i_pixclk)
		f_past_valid <= 1'b1;

	always @(*)
	if (!f_past_valid)
		assume(i_reset);

	////////////////////////////////////////////////////////////////////////
	//
	// AXI Stream assumptions
	//
	always @(posedge i_pixclk)
	if (f_past_valid && !$past(pix_reset))
	begin
		if ($past(i_valid && !o_ready))
		begin
			assume(i_valid);
			assume($stable(i_hlast));
			assume($stable(i_vlast));
			assume($stable(i_rgb_pix));
		end
	end

	////////////////////////////////////////////////////////////////////////
	//
	// Mode-line assumptions
	//
	always @(*)
	begin
		assume(12'h10 < i_hm_width);
		assume(i_hm_width < i_hm_porch);
		assume(i_hm_porch < i_hm_synch);
		assume(i_hm_synch < i_hm_raw);
		assume(i_hm_porch+14 < i_hm_raw);

		assume(12'h10 < i_vm_height);
		assume(i_vm_height < i_vm_porch);
		assume(i_vm_porch  < i_vm_synch);
		assume(i_vm_synch  < i_vm_raw);
	end

	assign	f_hmode = { i_hm_width,  i_hm_porch, i_hm_synch, i_hm_raw };
	assign	f_vmode = { i_vm_height, i_vm_porch, i_vm_synch, i_vm_raw };

	reg	[47:0]	f_last_vmode, f_last_hmode;
	always @(posedge i_pixclk)
		f_last_vmode <= f_vmode;
	always @(posedge i_pixclk)
		f_last_hmode <= f_hmode;

	reg	f_stable_mode;
	always @(*)
		f_stable_mode = (f_last_vmode == f_vmode)&&(f_last_hmode == f_hmode);

	always @(*)
	if (!pix_reset)
		assume(f_stable_mode);

	////////////////////////////////////////////////////////////////////////
	//
	// Pixel counting
	//

	always @(posedge i_pixclk)
	if ((!f_past_valid)||($past(pix_reset)))
	begin
		assert(hpos == 0);
		assert(vpos == 0);
		assert(first_frame);
	end

	always @(posedge i_pixclk)
	if ((f_past_valid)&&(!$past(pix_reset))&&(!pix_reset)
			&&(f_stable_mode)&&($past(f_stable_mode)))
	begin

		// The horizontal position counter should increment
		if ($past(hpos >= i_hm_raw-1'b1))
			assert(hpos == 0);
		else
			assert(hpos == $past(hpos)+1'b1);

		// The vertical position counter should increment
		if (hpos == i_hm_porch)
		begin
			if ($past(vpos >= i_vm_raw-1'b1))
				assert(vpos == 0);
			else
				assert(vpos == $past(vpos)+1'b1);
		end else
			assert(vpos == $past(vpos));

		// For induction purposes, we need to insist that both
		// horizontal and vertical counters stay within their
		// required ranges
		assert(hpos < i_hm_raw);
		assert(vpos < i_vm_raw);

		// If we are less than the data width for both horizontal
		// and vertical, then we should be asserting we are in a
		// valid data cycle
		// if ((hpos < i_hm_width)&&(vpos < i_vm_height)
		//		&&(!first_frame))
		//	assert(w_rd);
		// else
		//	assert(!w_rd);

		//
		// The horizontal sync should only be valid between positions
		// i_hm_porch <= hpos < i_hm_sync, invalid at all other times
		//
		if (hpos < i_hm_porch)
			assert(!hsync);
		else if (hpos < i_hm_synch)
			assert(hsync);
		else
			assert(!hsync);

		// Same thing for vertical
		if (vpos < i_vm_porch)
			assert(!vsync);
		else if (vpos < i_vm_synch)
			assert(vsync);
		else
			assert(!vsync);

		// At the end of every horizontal line cycle, we assert
		// a new line
		if (hpos == i_hm_width-2)
			assert(r_newline);
		else
			assert(!r_newline);

		// At the end of every vertical frame cycle, we assert
		// a new frame, but only on the newline measure
		if ((vpos == i_vm_height-1'b1)&&(r_newline))
			assert(r_newframe);
		else
			assert(!r_newframe);
	end

	//////////////////////////////
	//
	// HDMI Specific properties
	//
	//////////////////////////////
	reg	[3:0]	f_ctrl_length;
	reg	[1:0]	f_video_start, f_packet_start;

	always @(posedge i_pixclk)
	if (pix_reset)
		f_ctrl_length <= 4'hf;
	else if (hdmi_type != CTL_PERIOD)
		f_ctrl_length <= 0;
	else if (f_ctrl_length < 4'hf)
		f_ctrl_length <= f_ctrl_length + 1'b1;

	initial	f_video_start = 2'b01;
	always @(posedge i_pixclk)
	if (pix_reset)
		f_video_start = 2'b01;
	else if ((f_video_start == 2'b00)
			&&(f_ctrl_length >= 4'hc)&&(hdmi_type == GUARD)
			&&(hdmi_ctl == 4'h1))
		f_video_start <= 2'b1;
	else if ((f_video_start == 2'b01)&&(hdmi_type == GUARD)
			&&(hdmi_ctl == 4'h1))
		f_video_start <= 2'b10;
	else
		f_video_start <= 2'b00;

	always @(posedge i_pixclk)
	if ((f_ctrl_length >= 4'hc)&&(hdmi_type == GUARD))
		f_packet_start <= 2'b1;
	else if ((f_packet_start == 2'b1)&&(hdmi_type == GUARD))
		f_packet_start <= 2'b10;
	else
		f_packet_start <= 2'b00;

	always @(posedge i_pixclk)
	if ((f_past_valid)&&(!$past(pix_reset)))
	begin
		if (($past(hdmi_type != VIDEO_DATA))
				&&(f_video_start != 2'b10))
			assert(hdmi_type != VIDEO_DATA);
	end

	always @(posedge i_pixclk)
	if ((f_past_valid)&&(!$past(pix_reset))&&(!pix_reset))
	begin
		if ((hpos < i_hm_width)&&(vpos < i_vm_height))
			assert(hdmi_type == VIDEO_DATA);
		else
			assert(hdmi_type != VIDEO_DATA);
		if (!$past(first_frame))
			assert($past(w_rd) == (hdmi_type == VIDEO_DATA));

		if (vpos < i_vm_height)
		begin
			if (hpos < i_hm_width)
				assert(hdmi_type == VIDEO_DATA);
			if (hpos >= (i_hm_raw-GUARD_PIXELS))
				assert(hdmi_type == GUARD);
			else if (hpos >= (i_hm_raw-GUARD_PIXELS-PREGUARD_CONTROL))
				assert((hdmi_type == CTL_PERIOD)
					&&(hdmi_ctl == 4'h1));
		end
	end

	// always @(posedge i_pixclk)
	// if ((f_past_valid)&&(!$past(i_reset)))
		// assert(o_rd == (hdmi_type == VIDEO_DATA));

`ifdef	VERIFIC
	// {{{
	sequence	VIDEO_PREAMBLE;
		(hdmi_type == CTL_PERIOD) [*2]
		##1 ((hdmi_type == CTL_PERIOD)&&(hdmi_ctl == 4'h1)) [*10]
		##1 (hdmi_type == GUARD) [*2];
	endsequence

	assume property (@(posedge i_pixclk)
		VIDEO_PREAMBLE
		|=> (hdmi_type == VIDEO_DATA)&&(hpos == 0)&&(vpos == 0));

	// assert property (@(posedge i_pixclk)
	//	disable iff (pix_reset)
	//	((hdmi_type != VIDEO_DATA) throughout (not VIDEO_PREAMBLE)));

	//
	// Data Islands
	//
	sequence	DATA_PREAMBLE;
		(hdmi_type == CTL_PERIOD) [*2]
		##1 ((hdmi_type == CTL_PERIOD)&&(hdmi_ctl == 4'h5)) [*10]
		##1 (hdmi_type == GUARD) [*2];
	endsequence

	assert property (@(posedge i_pixclk)
		disable iff (pix_reset)
		(DATA_PREAMBLE)
		|=> 0 && (hdmi_type == DATA_ISLAND)[*64]
		##1 0 && (hdmi_type == GUARD) [*2]);

	// assert property (@(posedge i_pixclk)
	//	disable iff (pix_reset)
	//	((hdmi_type != DATA_ISLAND) throughout (not DATA_PREAMBLE))
	//	|=> (hdmi_type != DATA_ISLAND));

	// }}}
`endif
`endif
// }}}
endmodule
