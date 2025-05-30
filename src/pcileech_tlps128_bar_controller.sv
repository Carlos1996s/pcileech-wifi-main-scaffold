//
// PCILeech FPGA.
//
// PCIe BAR PIO controller.
//
// The PCILeech BAR PIO controller allows for easy user-implementation on top
// of the PCILeech AXIS128 PCIe TLP streaming interface.
// The controller consists of a read engine and a write engine and pluggable
// user-implemented PCIe BAR implementations (found at bottom of the file).
//
// Considerations:
// - The core handles 1 DWORD read + 1 DWORD write per CLK max. If a lot of
//   data is written / read from the TLP streaming interface the core may
//   drop packet silently.
// - The core reads 1 DWORD of data (without byte enable) per CLK.
// - The core writes 1 DWORD of data (with byte enable) per CLK.
// - All user-implemented cores must have the same latency in CLKs for the
//   returned read data or else undefined behavior will take place.
// - 32-bit addresses are passed for read/writes. Larger BARs than 4GB are
//   not supported due to addressing constraints. Lower bits (LSBs) are the
//   BAR offset, Higher bits (MSBs) are the 32-bit base address of the BAR.
// - DO NOT edit read/write engines.
// - DO edit pcileech_tlps128_bar_controller (to swap bar implementations).
// - DO edit the bar implementations (at bottom of the file, if neccessary).
//
// Example implementations exists below, swap out any of the example cores
// against a core of your use case, or modify existing cores.
// Following test cores exist (see below in this file):
// - pcileech_bar_impl_zerowrite4k = zero-initialized read/write BAR.
//     It's possible to modify contents by use of .coe file.
// - pcileech_bar_impl_loopaddr = test core that loops back the 32-bit
//     address of the current read. Does not support writes.
// - pcileech_bar_impl_none = core without any reply.
// 
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_bar_controller(
    input                   rst,
    input                   clk,
    input                   bar_en,
    input [15:0]            pcie_id,    
    IfAXIS128.sink_lite     tlps_in,
    IfAXIS128.source        tlps_out,
    output                  int_enable,
    input                   msix_vaild,
    output                  msix_send_done,
    output [31:0]           msix_address,
    output [31:0]           msix_vector,
    input [31:0]            base_address_register,
    input [31:0]            base_address_register_1,
    input [31:0]            base_address_register_2,
    input [31:0]            base_address_register_3,
    input [31:0]            base_address_register_4,
    input [31:0]            base_address_register_5
);
    
    // ------------------------------------------------------------------------
    // 1: TLP RECEIVE:
    // Receive incoming BAR requests from the TLP stream:
    // send them onwards to read and write FIFOs
    // ------------------------------------------------------------------------
    wire in_is_wr_ready;
    bit  in_is_wr_last;
    wire in_is_first    = tlps_in.tuser[0];
    wire in_is_bar      = bar_en && (tlps_in.tuser[8:2] != 0);
    wire in_is_rd       = (in_is_first && tlps_in.tlast && ((tlps_in.tdata[31:25] == 7'b0000000) || (tlps_in.tdata[31:25] == 7'b0010000) || (tlps_in.tdata[31:24] == 8'b00000010)));
    wire in_is_wr       = in_is_wr_last || (in_is_first && in_is_wr_ready && ((tlps_in.tdata[31:25] == 7'b0100000) || (tlps_in.tdata[31:25] == 7'b0110000) || (tlps_in.tdata[31:24] == 8'b01000010)));
    
    always @ ( posedge clk )
        if ( rst ) begin
            in_is_wr_last <= 0;
        end
        else if ( tlps_in.tvalid ) begin
            in_is_wr_last <= !tlps_in.tlast && in_is_wr;
        end

    wire [6:0]  wr_bar;
    wire [31:0] wr_addr;
    wire [3:0]  wr_be;
    wire [31:0] wr_data;
    wire        wr_valid;
    wire [87:0] rd_req_ctx;
    wire [6:0]  rd_req_bar;
    wire [31:0] rd_req_addr;
    wire [3:0]  rd_req_be;
    wire        rd_req_valid;
    wire [87:0] rd_rsp_ctx;
    wire [31:0] rd_rsp_data;
    wire        rd_rsp_valid;
        
    pcileech_tlps128_bar_rdengine i_pcileech_tlps128_bar_rdengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        // TLPs:
        .pcie_id        ( pcie_id                       ),
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_rd ),
        .tlps_out       ( tlps_out                      ),
        // BAR reads:
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_bar     ( rd_req_bar                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_be      ( rd_req_be                     ),
        .rd_req_valid   ( rd_req_valid                  ),
        .rd_rsp_ctx     ( rd_rsp_ctx                    ),
        .rd_rsp_data    ( rd_rsp_data                   ),
        .rd_rsp_valid   ( rd_rsp_valid                  )
    );

    pcileech_tlps128_bar_wrengine i_pcileech_tlps128_bar_wrengine(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        // TLPs:
        .tlps_in        ( tlps_in                       ),
        .tlps_in_valid  ( tlps_in.tvalid && in_is_bar && in_is_wr ),
        .tlps_in_ready  ( in_is_wr_ready                ),
        // outgoing BAR writes:
        .wr_bar         ( wr_bar                        ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid                      )
    );
    
    wire [87:0] bar_rsp_ctx[7];
    wire [31:0] bar_rsp_data[7];
    wire        bar_rsp_valid[7];
    
    assign rd_rsp_ctx = bar_rsp_valid[0] ? bar_rsp_ctx[0] :
                        bar_rsp_valid[1] ? bar_rsp_ctx[1] :
                        bar_rsp_valid[2] ? bar_rsp_ctx[2] :
                        bar_rsp_valid[3] ? bar_rsp_ctx[3] :
                        bar_rsp_valid[4] ? bar_rsp_ctx[4] :
                        bar_rsp_valid[5] ? bar_rsp_ctx[5] :
                        bar_rsp_valid[6] ? bar_rsp_ctx[6] : 0;
    assign rd_rsp_data = bar_rsp_valid[0] ? bar_rsp_data[0] :
                        bar_rsp_valid[1] ? bar_rsp_data[1] :
                        bar_rsp_valid[2] ? bar_rsp_data[2] :
                        bar_rsp_valid[3] ? bar_rsp_data[3] :
                        bar_rsp_valid[4] ? bar_rsp_data[4] :
                        bar_rsp_valid[5] ? bar_rsp_data[5] :
                        bar_rsp_valid[6] ? bar_rsp_data[6] : 0;
    assign rd_rsp_valid = bar_rsp_valid[0] || bar_rsp_valid[1] || bar_rsp_valid[2] || bar_rsp_valid[3] || bar_rsp_valid[4] || bar_rsp_valid[5] || bar_rsp_valid[6];
    

    pcileech_bar_impl_none i_bar0(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[0]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[0] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[0]                ),
        .rd_rsp_data    ( bar_rsp_data[0]               ),
        .rd_rsp_valid   ( bar_rsp_valid[0]              )
    );
    
    pcileech_bar_impl_none i_bar1(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[1]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[1] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[1]                ),
        .rd_rsp_data    ( bar_rsp_data[1]               ),
        .rd_rsp_valid   ( bar_rsp_valid[1]              )
    );
    
    pcileech_bar_impl_bar2 i_bar2(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[2]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[2] ),
        .base_address_register( base_address_register_2   ),
        .int_enable     ( int_enable                    ),
        .rd_rsp_ctx     ( bar_rsp_ctx[2]                ),
        .rd_rsp_data    ( bar_rsp_data[2]               ),
        .rd_rsp_valid   ( bar_rsp_valid[2]              )
    );
    
    pcileech_bar_impl_none i_bar3(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[3]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[3] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[3]                ),
        .rd_rsp_data    ( bar_rsp_data[3]               ),
        .rd_rsp_valid   ( bar_rsp_valid[3]              )
    );
    
    pcileech_bar_impl_none i_bar4(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[4]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[4] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[4]                ),
        .rd_rsp_data    ( bar_rsp_data[4]               ),
        .rd_rsp_valid   ( bar_rsp_valid[4]              )
    );
    
    pcileech_bar_impl_none i_bar5(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[5]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[5] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[5]                ),
        .rd_rsp_data    ( bar_rsp_data[5]               ),
        .rd_rsp_valid   ( bar_rsp_valid[5]              )
    );
    
    pcileech_bar_impl_none i_bar6_optrom(
        .rst            ( rst                           ),
        .clk            ( clk                           ),
        .wr_addr        ( wr_addr                       ),
        .wr_be          ( wr_be                         ),
        .wr_data        ( wr_data                       ),
        .wr_valid       ( wr_valid && wr_bar[6]         ),
        .rd_req_ctx     ( rd_req_ctx                    ),
        .rd_req_addr    ( rd_req_addr                   ),
        .rd_req_valid   ( rd_req_valid && rd_req_bar[6] ),
        .rd_rsp_ctx     ( bar_rsp_ctx[6]                ),
        .rd_rsp_data    ( bar_rsp_data[6]               ),
        .rd_rsp_valid   ( bar_rsp_valid[6]              )
    );


endmodule



// ------------------------------------------------------------------------
// BAR WRITE ENGINE:
// Receives BAR WRITE TLPs and output BAR WRITE requests.
// Holds a 2048-byte buffer.
// Input flow rate is 16bytes/CLK (max).
// Output flow rate is 4bytes/CLK.
// If write engine overflows incoming TLP is completely discarded silently.
// ------------------------------------------------------------------------
module pcileech_tlps128_bar_wrengine(
    input                   rst,    
    input                   clk,
    // TLPs:
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    output                  tlps_in_ready,
    // outgoing BAR writes:
    output bit [6:0]        wr_bar,
    output bit [31:0]       wr_addr,
    output bit [3:0]        wr_be,
    output bit [31:0]       wr_data,
    output bit              wr_valid
);

    wire            f_rd_en;
    wire [127:0]    f_tdata;
    wire [3:0]      f_tkeepdw;
    wire [8:0]      f_tuser;
    wire            f_tvalid;
    
    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tlast;
    
    bit [3:0]       be_first;
    bit [3:0]       be_last;
    bit             first_dw;
    bit [31:0]      addr;

    fifo_141_141_clk1_bar_wr i_fifo_141_141_clk1_bar_wr(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( {tlps_in.tuser[8:0], tlps_in.tkeepdw, tlps_in.tdata} ),
        .full           (                               ),
        .prog_empty     ( tlps_in_ready                 ),
        .rd_en          ( f_rd_en                       ),
        .dout           ( {f_tuser, f_tkeepdw, f_tdata} ),    
        .empty          (                               ),
        .valid          ( f_tvalid                      )
    );
    
    // STATE MACHINE:
    `define S_ENGINE_IDLE        3'h0
    `define S_ENGINE_FIRST       3'h1
    `define S_ENGINE_4DW_REQDATA 3'h2
    `define S_ENGINE_TX0         3'h4
    `define S_ENGINE_TX1         3'h5
    `define S_ENGINE_TX2         3'h6
    `define S_ENGINE_TX3         3'h7
    (* KEEP = "TRUE" *) bit [3:0] state = `S_ENGINE_IDLE;
    
    assign f_rd_en = (state == `S_ENGINE_IDLE) ||
                     (state == `S_ENGINE_4DW_REQDATA) ||
                     (state == `S_ENGINE_TX3) ||
                     ((state == `S_ENGINE_TX2 && !tkeepdw[3])) ||
                     ((state == `S_ENGINE_TX1 && !tkeepdw[2])) ||
                     ((state == `S_ENGINE_TX0 && !f_tkeepdw[1]));

    always @ ( posedge clk ) begin
        wr_addr     <= addr;
        wr_valid    <= ((state == `S_ENGINE_TX0) && f_tvalid) || (state == `S_ENGINE_TX1) || (state == `S_ENGINE_TX2) || (state == `S_ENGINE_TX3);
        
    end

    always @ ( posedge clk )
        if ( rst ) begin
            state <= `S_ENGINE_IDLE;
        end
        else case ( state )
            `S_ENGINE_IDLE: begin
                state   <= `S_ENGINE_FIRST;
            end
            `S_ENGINE_FIRST: begin
                if ( f_tvalid && f_tuser[0] ) begin
                    wr_bar      <= f_tuser[8:2];
                    tdata       <= f_tdata;
                    tkeepdw     <= f_tkeepdw;
                    tlast       <= f_tuser[1];
                    first_dw    <= 1;
                    be_first    <= f_tdata[35:32];
                    be_last     <= f_tdata[39:36];
                    if ( f_tdata[31:29] == 8'b010 ) begin       // 3 DW header, with data
                        addr    <= { f_tdata[95:66], 2'b00 };
                        state   <= `S_ENGINE_TX3;
                    end
                    else if ( f_tdata[31:29] == 8'b011 ) begin  // 4 DW header, with data
                        addr    <= { f_tdata[127:98], 2'b00 };
                        state   <= `S_ENGINE_4DW_REQDATA;
                    end 
                end
                else begin
                    state   <= `S_ENGINE_IDLE;
                end
            end 
            `S_ENGINE_4DW_REQDATA: begin
                state   <= `S_ENGINE_TX0;
            end
            `S_ENGINE_TX0: begin
                tdata       <= f_tdata;
                tkeepdw     <= f_tkeepdw;
                tlast       <= f_tuser[1];
                addr        <= addr + 4;
                wr_data     <= { f_tdata[0+00+:8], f_tdata[0+08+:8], f_tdata[0+16+:8], f_tdata[0+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (f_tkeepdw[1] ? 4'hf : be_last);
                state       <= f_tvalid ? (f_tkeepdw[1] ? `S_ENGINE_TX1 : `S_ENGINE_FIRST) : `S_ENGINE_IDLE;
            end
            `S_ENGINE_TX1: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[32+00+:8], tdata[32+08+:8], tdata[32+16+:8], tdata[32+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[2] ? 4'hf : be_last);
                state       <= tkeepdw[2] ? `S_ENGINE_TX2 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX2: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[64+00+:8], tdata[64+08+:8], tdata[64+16+:8], tdata[64+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (tkeepdw[3] ? 4'hf : be_last);
                state       <= tkeepdw[3] ? `S_ENGINE_TX3 : `S_ENGINE_FIRST;
            end
            `S_ENGINE_TX3: begin
                addr        <= addr + 4;
                wr_data     <= { tdata[96+00+:8], tdata[96+08+:8], tdata[96+16+:8], tdata[96+24+:8] };
                first_dw    <= 0;
                wr_be       <= first_dw ? be_first : (!tlast ? 4'hf : be_last);
                state       <= !tlast ? `S_ENGINE_TX0 : `S_ENGINE_FIRST;
            end
        endcase

endmodule




// ------------------------------------------------------------------------
// BAR READ ENGINE:
// Receives BAR READ TLPs and output BAR READ requests.
// ------------------------------------------------------------------------
module pcileech_tlps128_bar_rdengine(
    input                   rst,    
    input                   clk,
    // TLPs:
    input [15:0]            pcie_id,
    IfAXIS128.sink_lite     tlps_in,
    input                   tlps_in_valid,
    IfAXIS128.source        tlps_out,
    // BAR reads:
    output [87:0]           rd_req_ctx,
    output [6:0]            rd_req_bar,
    output [31:0]           rd_req_addr,
    output                  rd_req_valid,
    output [3:0]            rd_req_be,        
    input  [87:0]           rd_rsp_ctx,
    input  [31:0]           rd_rsp_data,
    input                   rd_rsp_valid
);
    // ------------------------------------------------------------------------
    // 1: PROCESS AND QUEUE INCOMING READ TLPs:
    // ------------------------------------------------------------------------
    wire [10:0] rd1_in_dwlen    = (tlps_in.tdata[9:0] == 0) ? 11'd1024 : {1'b0, tlps_in.tdata[9:0]};
    wire [6:0]  rd1_in_bar      = tlps_in.tuser[8:2];
    wire [15:0] rd1_in_reqid    = tlps_in.tdata[63:48];
    wire [7:0]  rd1_in_tag      = tlps_in.tdata[47:40];
    wire [31:0] rd1_in_addr     = { ((tlps_in.tdata[31:29] == 3'b000) ? tlps_in.tdata[95:66] : tlps_in.tdata[127:98]), 2'b00 };
    wire [3:0]  rd1_in_be       = tlps_in.tdata[35:32];
    wire [73:0] rd1_in_data;
    assign rd1_in_data[73:63]   = rd1_in_dwlen;
    assign rd1_in_data[62:56]   = rd1_in_bar;   
    assign rd1_in_data[55:48]   = rd1_in_tag;
    assign rd1_in_data[47:32]   = rd1_in_reqid;
    assign rd1_in_data[31:0]    = rd1_in_addr;

    
    wire [3:0]  rd1_out_be;
    wire        rd1_out_be_valid;
    wire        rd1_out_rden;
    wire [73:0] rd1_out_data;
    wire        rd1_out_valid;
    
    fifo_74_74_clk1_bar_rd1 i_fifo_74_74_clk1_bar_rd1(
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( rd1_in_data                   ),
        .full           (                               ),
        .rd_en          ( rd1_out_rden                  ),
        .dout           ( rd1_out_data                  ),    
        .empty          (                               ),
        .valid          ( rd1_out_valid                 )
    );
    fifo_4_4_clk1_bar_rd1 i_fifo_4_4_clk1_bar_rd1 (
        .srst           ( rst                           ),
        .clk            ( clk                           ),
        .wr_en          ( tlps_in_valid                 ),
        .din            ( rd1_in_be                     ),
        .full           (                               ),
        .rd_en          ( rd1_out_rden                  ),
        .dout           ( rd1_out_be                    ),
        .empty          (                               ),
        .valid          ( rd1_out_be_valid              )

    );
    
    // ------------------------------------------------------------------------
    // 2: PROCESS AND SPLIT READ TLPs INTO RESPONSE TLP READ REQUESTS AND QUEUE:
    //    (READ REQUESTS LARGER THAN 128-BYTES WILL BE SPLIT INTO MULTIPLE).
    // ------------------------------------------------------------------------
    
    wire [10:0] rd1_out_dwlen       = rd1_out_data[73:63];
    wire [4:0]  rd1_out_dwlen5      = rd1_out_data[67:63];
    wire [4:0]  rd1_out_addr5       = rd1_out_data[6:2];
    
    // 1st "instant" packet:
    wire [4:0]  rd2_pkt1_dwlen_pre  = ((rd1_out_addr5 + rd1_out_dwlen5 > 6'h20) || ((rd1_out_addr5 != 0) && (rd1_out_dwlen5 == 0))) ? (6'h20 - rd1_out_addr5) : rd1_out_dwlen5;
    wire [5:0]  rd2_pkt1_dwlen      = (rd2_pkt1_dwlen_pre == 0) ? 6'h20 : rd2_pkt1_dwlen_pre;
    wire [10:0] rd2_pkt1_dwlen_next = rd1_out_dwlen - rd2_pkt1_dwlen;
    wire        rd2_pkt1_large      = (rd1_out_dwlen > 32) || (rd1_out_dwlen != rd2_pkt1_dwlen);
    wire        rd2_pkt1_tiny       = (rd1_out_dwlen == 1);
    wire [11:0] rd2_pkt1_bc         = rd1_out_dwlen << 2;
    wire [85:0] rd2_pkt1;
    assign      rd2_pkt1[85:74]     = rd2_pkt1_bc;
    assign      rd2_pkt1[73:63]     = rd2_pkt1_dwlen;
    assign      rd2_pkt1[62:0]      = rd1_out_data[62:0];
    
    // Nth packet (if split should take place):
    bit  [10:0] rd2_total_dwlen;
    wire [10:0] rd2_total_dwlen_next = rd2_total_dwlen - 11'h20;
    
    bit  [85:0] rd2_pkt2;
    wire [10:0] rd2_pkt2_dwlen = rd2_pkt2[73:63];
    wire        rd2_pkt2_large = (rd2_total_dwlen > 11'h20);
    
    wire        rd2_out_rden;
    
    // STATE MACHINE:
    `define S2_ENGINE_REQDATA     1'h0
    `define S2_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state2 = `S2_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            state2 <= `S2_ENGINE_REQDATA;
        end
        else case ( state2 )
            `S2_ENGINE_REQDATA: begin
                if ( rd1_out_valid && rd2_pkt1_large ) begin
                    rd2_total_dwlen <= rd2_pkt1_dwlen_next;                             // dwlen (total remaining)
                    rd2_pkt2[85:74] <= rd2_pkt1_dwlen_next << 2;                        // byte-count
                    rd2_pkt2[73:63] <= (rd2_pkt1_dwlen_next > 11'h20) ? 11'h20 : rd2_pkt1_dwlen_next;   // dwlen next
                    rd2_pkt2[62:12] <= rd1_out_data[62:12];                             // various data
                    rd2_pkt2[11:0]  <= rd1_out_data[11:0] + (rd2_pkt1_dwlen << 2);      // base address (within 4k page)
                    state2 <= `S2_ENGINE_PROCESSING;
                end
            end
            `S2_ENGINE_PROCESSING: begin
                if ( rd2_out_rden ) begin
                    rd2_total_dwlen <= rd2_total_dwlen_next;                                // dwlen (total remaining)
                    rd2_pkt2[85:74] <= rd2_total_dwlen_next << 2;                           // byte-count
                    rd2_pkt2[73:63] <= (rd2_total_dwlen_next > 11'h20) ? 11'h20 : rd2_total_dwlen_next;   // dwlen next
                    rd2_pkt2[62:12] <= rd2_pkt2[62:12];                                     // various data
                    rd2_pkt2[11:0]  <= rd2_pkt2[11:0] + (rd2_pkt2_dwlen << 2);              // base address (within 4k page)
                    if ( !rd2_pkt2_large ) begin
                        state2 <= `S2_ENGINE_REQDATA;
                    end
                end
            end
        endcase
    
    assign rd1_out_rden = rd2_out_rden && (((state2 == `S2_ENGINE_REQDATA) && (!rd1_out_valid || rd2_pkt1_tiny)) || ((state2 == `S2_ENGINE_PROCESSING) && !rd2_pkt2_large));

    wire [85:0] rd2_in_data  = (state2 == `S2_ENGINE_REQDATA) ? rd2_pkt1 : rd2_pkt2;
    wire        rd2_in_valid = rd1_out_valid || ((state2 == `S2_ENGINE_PROCESSING) && rd2_out_rden);
    wire [3:0]  rd2_in_be       = rd1_out_be;
    wire        rd2_in_be_valid = rd1_out_valid;

    bit  [85:0] rd2_out_data;
    bit         rd2_out_valid;
    bit  [3:0]  rd2_out_be;
    bit         rd2_out_be_valid;
    always @ ( posedge clk ) begin
        rd2_out_data    <= rd2_in_valid ? rd2_in_data : rd2_out_data;
        rd2_out_valid   <= rd2_in_valid && !rst;
        rd2_out_be       <= rd2_in_be_valid ? rd2_in_be : rd2_out_data;
        rd2_out_be_valid <= rd2_in_be_valid && !rst;  
    end

    // ------------------------------------------------------------------------
    // 3: PROCESS EACH READ REQUEST PACKAGE PER INDIVIDUAL 32-bit READ DWORDS:
    // ------------------------------------------------------------------------

    wire [4:0]  rd2_out_dwlen   = rd2_out_data[67:63];
    wire        rd2_out_last    = (rd2_out_dwlen == 1);
    wire [9:0]  rd2_out_dwaddr  = rd2_out_data[11:2];
    
    wire        rd3_enable;
    
    bit [3:0]   rd3_process_be;
    bit         rd3_process_valid;
    bit         rd3_process_first;
    bit         rd3_process_last;
    bit [4:0]   rd3_process_dwlen;
    bit [9:0]   rd3_process_dwaddr;
    bit [85:0]  rd3_process_data;
    wire        rd3_process_next_last = (rd3_process_dwlen == 2);
    wire        rd3_process_nextnext_last = (rd3_process_dwlen <= 3);
    assign rd_req_be    = rd3_process_be;
    assign rd_req_ctx   = { rd3_process_first, rd3_process_last, rd3_process_data };
    assign rd_req_bar   = rd3_process_data[62:56];
    assign rd_req_addr  = { rd3_process_data[31:12], rd3_process_dwaddr, 2'b00 };
    assign rd_req_valid = rd3_process_valid;
    
    // STATE MACHINE:
    `define S3_ENGINE_REQDATA     1'h0
    `define S3_ENGINE_PROCESSING  1'h1
    (* KEEP = "TRUE" *) bit [0:0] state3 = `S3_ENGINE_REQDATA;
    
    always @ ( posedge clk )
        if ( rst ) begin
            rd3_process_valid   <= 1'b0;
            state3              <= `S3_ENGINE_REQDATA;
        end
        else case ( state3 )
            `S3_ENGINE_REQDATA: begin
                if ( rd2_out_valid ) begin
                    rd3_process_valid       <= 1'b1;
                    rd3_process_first       <= 1'b1;                    // FIRST
                    rd3_process_last        <= rd2_out_last;            // LAST (low 5 bits of dwlen == 1, [max pktlen = 0x20))
                    rd3_process_dwlen       <= rd2_out_dwlen;           // PKT LENGTH IN DW
                    rd3_process_dwaddr      <= rd2_out_dwaddr;          // DWADDR OF THIS DWORD
                    rd3_process_data[85:0]  <= rd2_out_data[85:0];      // FORWARD / SAVE DATA
                    if ( rd2_out_be_valid ) begin
                        rd3_process_be <= rd2_out_be;
                    end else begin
                        rd3_process_be <= 4'hf;
                    end
                    if ( !rd2_out_last ) begin
                        state3 <= `S3_ENGINE_PROCESSING;
                    end
                end
                else begin
                    rd3_process_valid       <= 1'b0;
                end
            end
            `S3_ENGINE_PROCESSING: begin
                rd3_process_first           <= 1'b0;                    // FIRST
                rd3_process_last            <= rd3_process_next_last;   // LAST
                rd3_process_dwlen           <= rd3_process_dwlen - 1;   // LEN DEC
                rd3_process_dwaddr          <= rd3_process_dwaddr + 1;  // ADDR INC
                if ( rd3_process_next_last ) begin
                    state3 <= `S3_ENGINE_REQDATA;
                end
            end
        endcase

    assign rd2_out_rden = rd3_enable && (
        ((state3 == `S3_ENGINE_REQDATA) && (!rd2_out_valid || rd2_out_last)) ||
        ((state3 == `S3_ENGINE_PROCESSING) && rd3_process_nextnext_last));
    
    // ------------------------------------------------------------------------
    // 4: PROCESS RESPONSES:
    // ------------------------------------------------------------------------
    
    wire        rd_rsp_first    = rd_rsp_ctx[87];
    wire        rd_rsp_last     = rd_rsp_ctx[86];
    
    wire [9:0]  rd_rsp_dwlen    = rd_rsp_ctx[72:63];
    wire [11:0] rd_rsp_bc       = rd_rsp_ctx[85:74];
    wire [15:0] rd_rsp_reqid    = rd_rsp_ctx[47:32];
    wire [7:0]  rd_rsp_tag      = rd_rsp_ctx[55:48];
    wire [6:0]  rd_rsp_lowaddr  = rd_rsp_ctx[6:0];
    wire [31:0] rd_rsp_addr     = rd_rsp_ctx[31:0];
    wire [31:0] rd_rsp_data_bs  = { rd_rsp_data[7:0], rd_rsp_data[15:8], rd_rsp_data[23:16], rd_rsp_data[31:24] };
    
    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1;
    wire        tvalid  = tlast || tkeepdw[3];
    
    always @ ( posedge clk )
        if ( rst ) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 0;
        end
        else if ( rd_rsp_valid && rd_rsp_first ) begin
            tkeepdw         <= 4'b1111;
            tlast           <= rd_rsp_last;
            first           <= 1'b1;
            tdata[31:0]     <= { 22'b0100101000000000000000, rd_rsp_dwlen };            // format, type, length
            tdata[63:32]    <= { pcie_id[7:0], pcie_id[15:8], 4'b0, rd_rsp_bc };        // pcie_id, byte_count
            tdata[95:64]    <= { rd_rsp_reqid, rd_rsp_tag, 1'b0, rd_rsp_lowaddr };      // req_id, tag, lower_addr
            tdata[127:96]   <= rd_rsp_data_bs;
        end
        else begin
            tlast   <= rd_rsp_valid && rd_rsp_last;
            tkeepdw <= tvalid ? (rd_rsp_valid ? 4'b0001 : 4'b0000) : (rd_rsp_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first   <= 0;
            if ( rd_rsp_valid ) begin
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= rd_rsp_data_bs;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= rd_rsp_data_bs;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= rd_rsp_data_bs;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= rd_rsp_data_bs;   
            end
        end
    
    // 2.1 - submit to output fifo - will feed into mux/pcie core.
    fifo_134_134_clk1_bar_rdrsp i_fifo_134_134_clk1_bar_rdrsp(
        .srst           ( rst                       ),
        .clk            ( clk                       ),
        .din            ( { first, tlast, tkeepdw, tdata } ),
        .wr_en          ( tvalid                    ),
        .rd_en          ( tlps_out.tready           ),
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           (                           ),
        .empty          (                           ),
        .prog_empty     ( rd3_enable                ),
        .valid          ( tlps_out.tvalid           )
    );
    
    assign tlps_out.tuser[1] = tlps_out.tlast;
    assign tlps_out.tuser[8:2] = 0;
    
    // 2.2 - packet count:
    bit [10:0]  pkt_count       = 0;
    wire        pkt_count_dec   = tlps_out.tvalid && tlps_out.tlast;
    wire        pkt_count_inc   = tvalid && tlast;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data    = (pkt_count_next > 0);
    
    always @ ( posedge clk ) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end

endmodule


// ------------------------------------------------------------------------
// Example BAR implementation that does nothing but drop any read/writes
// silently without generating a response.
// This is only recommended for placeholder designs.
// Latency = N/A.
// ------------------------------------------------------------------------
module pcileech_bar_impl_none(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    initial rd_rsp_ctx = 0;
    initial rd_rsp_data = 0;
    initial rd_rsp_valid = 0;

endmodule




// ------------------------------------------------------------------------
// Example BAR implementation of "address loopback" which can be useful
// for testing. Any read to a specific BAR address will result in the
// address as response.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_loopaddr(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input [87:0]        rd_req_ctx,
    input [31:0]        rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]      rd_req_ctx_1;
    bit [31:0]      rd_req_addr_1;
    bit             rd_req_valid_1;
    
    always @ ( posedge clk ) begin
        rd_req_ctx_1    <= rd_req_ctx;
        rd_req_addr_1   <= rd_req_addr;
        rd_req_valid_1  <= rd_req_valid;
        rd_rsp_ctx      <= rd_req_ctx_1;
        rd_rsp_data     <= rd_req_addr_1;
        rd_rsp_valid    <= rd_req_valid_1;
    end    

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation of a 4kB writable initial-zero BAR.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module pcileech_bar_impl_zerowrite4k(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    wire [31:0] doutb;
    
    always @ ( posedge clk ) begin
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        rd_rsp_data     <= doutb; 
    end
    
    bram_bar_zero4k i_bram_bar_zero4k(
        // Port A - write:
        .addra  ( wr_addr[11:2]     ),
        .clka   ( clk               ),
        .dina   ( wr_data           ),
        .ena    ( wr_valid          ),
        .wea    ( wr_be             ),
        // Port A - read (2 CLK latency):
        .addrb  ( rd_req_addr[11:2] ),
        .clkb   ( clk               ),
        .doutb  ( doutb             ),
        .enb    ( rd_req_valid      )
    );

endmodule


`define MAC_RANDOM_NUM1 13
`define MAC_RANDOM_NUM2 2
`define MAC_RANDOM_NUM3 13
`define MAC_RANDOM_NUM4 9
`define MAC_RANDOM_NUM5 7
`define MAC_RANDOM_NUM6 5


module pcileech_bar_impl_bar2(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    input  [31:0]       base_address_register,
    // outgoing BAR read replies:
    output wire         int_enable,
    output reg [87:0]   rd_rsp_ctx,
    output reg [31:0]   rd_rsp_data,
    output reg          rd_rsp_valid
);
                     
    reg [87:0]      drd_req_ctx;
    reg [31:0]      drd_req_addr;
    reg             drd_req_valid;
                  
    reg [31:0]      dwr_addr;
    reg [31:0]      dwr_data;
    reg             dwr_valid;
               
    reg [31:0]      data_32;
              
    time number = 0;

    assign int_enable = 1'b1;
                  
    always @ (posedge clk) begin
        if (rst)
            number <= 0;
               
        number          <= number + 1;
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        dwr_valid       <= wr_valid;
        drd_req_addr    <= rd_req_addr;
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        dwr_addr        <= wr_addr;
        dwr_data        <= wr_data;

        if (drd_req_valid) begin
            case (({drd_req_addr[31:24], drd_req_addr[23:16], drd_req_addr[15:08], drd_req_addr[07:00]} - (base_address_register & 32'hFFFFFFF0)) & 32'hFFFF)
                16'h0000 : rd_rsp_data <= 32'hFDC3B2D2;
                16'h0004 : rd_rsp_data <= 32'h15030012;
                16'h0008 : rd_rsp_data <= 32'h00207C2B;
                16'h0010 : rd_rsp_data <= 32'h4007EB03;
                16'h0014 : rd_rsp_data <= 32'h10562175;
                16'h0018 : rd_rsp_data <= 32'h00400100;
                16'h001C : rd_rsp_data <= 32'h07F6E100;
                16'h0020 : rd_rsp_data <= 32'h05010101;
                16'h0024 : rd_rsp_data <= 32'h000F81F9;
                16'h0028 : rd_rsp_data <= 32'hF4004783;
                16'h002C : rd_rsp_data <= 32'hF0AAA596;
                16'h0030 : rd_rsp_data <= 32'hF261FAFF;
                16'h0034 : rd_rsp_data <= 32'h34000000;
                16'h0040 : rd_rsp_data <= 32'h00000220;
                16'h0044 : rd_rsp_data <= 32'h00200090;
                16'h0048 : rd_rsp_data <= 32'h00020000;
                16'h004C : rd_rsp_data <= 32'h0FE28282;
                16'h0050 : rd_rsp_data <= 32'h80000000;
                16'h0060 : rd_rsp_data <= 32'h00000062;
                16'h0064 : rd_rsp_data <= 32'h30030104;
                16'h0068 : rd_rsp_data <= 32'h80086804;
                16'h006C : rd_rsp_data <= 32'h000000E0;
                16'h0074 : rd_rsp_data <= 32'h00000405;
                16'h0078 : rd_rsp_data <= 32'h0A1E002A;
                16'h007C : rd_rsp_data <= 32'h00000083;
                16'h0080 : rd_rsp_data <= 32'h800706C6;
                16'h0090 : rd_rsp_data <= 32'hD5000000;
                16'h0094 : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00A0 : rd_rsp_data <= 32'h00000620;
                16'h00A4 : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00A8 : rd_rsp_data <= 32'hFF000000;
                16'h00AC : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00B0 : rd_rsp_data <= 32'h31000603;
                16'h00B4 : rd_rsp_data <= 32'h00100041;
                16'h00B8 : rd_rsp_data <= 32'h10000F00;
                16'h00C0 : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00C8 : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00CC : rd_rsp_data <= 32'h00000029;
                16'h00D0 : rd_rsp_data <= 32'h001FC002;
                16'h00DC : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00EC : rd_rsp_data <= 32'hEAEAEAEA;
                16'h00F0 : rd_rsp_data <= 32'h0C44113B;
                16'h00F4 : rd_rsp_data <= 32'h0000006B;
                16'h00F8 : rd_rsp_data <= 32'h00038129;
                16'h00FC : rd_rsp_data <= 32'h00000207;
                16'h0100 : rd_rsp_data <= 32'h000006FF;
                16'h0104 : rd_rsp_data <= 32'h00000020;
                16'h010C : rd_rsp_data <= 32'h0000F5B1;
                16'h0114 : rd_rsp_data <= 32'h3CFF0FF5;
                16'h011C : rd_rsp_data <= 32'h11981198;
                16'h0130 : rd_rsp_data <= 32'h72070012;
                16'h0134 : rd_rsp_data <= 32'h00000009;
                16'h0138 : rd_rsp_data <= 32'hE213091F;
                16'h013C : rd_rsp_data <= 32'h10000200;
                16'h0164 : rd_rsp_data <= 32'h00000001;
                16'h0174 : rd_rsp_data <= 32'h000008FF;
                16'h0194 : rd_rsp_data <= 32'h10000001;
                16'h0198 : rd_rsp_data <= 32'h000B0047;
                16'h01C4 : rd_rsp_data <= 32'hFE0057FC;
                16'h01D0 : rd_rsp_data <= 32'h00FF0F1E;
                16'h01D4 : rd_rsp_data <= 32'h00FF0F1E;
                16'h01D8 : rd_rsp_data <= 32'h00FF001E;
                16'h01DC : rd_rsp_data <= 32'h00FF001E;
                16'h01E4 : rd_rsp_data <= 32'h00000523;
                16'h01E8 : rd_rsp_data <= 32'h00000880;
                16'h01EC : rd_rsp_data <= 32'hB0000C1C;
                16'h0200 : rd_rsp_data <= 32'h00E40808;
                16'h0204 : rd_rsp_data <= 32'h00E40808;
                16'h0208 : rd_rsp_data <= 32'h6B00F510;
                16'h020C : rd_rsp_data <= 32'h00FD0000;
                16'h0224 : rd_rsp_data <= 32'h00002020;
                16'h0228 : rd_rsp_data <= 32'h0000F500;
                16'h0280 : rd_rsp_data <= 32'h00002003;
                16'h0284 : rd_rsp_data <= 32'h00020000;
                16'h0290 : rd_rsp_data <= 32'h00000004;
                16'h0294 : rd_rsp_data <= 32'h00003D00;
                16'h0300 : rd_rsp_data <= 32'hA7038000;
                16'h0308 : rd_rsp_data <= 32'h7013C000;
                16'h0310 : rd_rsp_data <= 32'h70069000;
                16'h0318 : rd_rsp_data <= 32'h700CB000;
                16'h0320 : rd_rsp_data <= 32'h700DD000;
                16'h0328 : rd_rsp_data <= 32'h700FC000;
                16'h0330 : rd_rsp_data <= 32'h70146000;
                16'h0338 : rd_rsp_data <= 32'h6E9C7000;
                16'h0340 : rd_rsp_data <= 32'h70050000;
                16'h0380 : rd_rsp_data <= 32'hA2001200;
                16'h0384 : rd_rsp_data <= 32'h12001200;
                16'h0388 : rd_rsp_data <= 32'h12001200;
                16'h038C : rd_rsp_data <= 32'h12001200;
                16'h0390 : rd_rsp_data <= 32'h12001200;
                16'h0394 : rd_rsp_data <= 32'h12001200;
                16'h0398 : rd_rsp_data <= 32'h12001200;
                16'h039C : rd_rsp_data <= 32'h401D401D;
                16'h03B0 : rd_rsp_data <= 32'h01600160;
                16'h03B4 : rd_rsp_data <= 32'h00730073;
                16'h03D8 : rd_rsp_data <= 32'h08008004;
                16'h03E8 : rd_rsp_data <= 32'h97020D00;
                16'h03EC : rd_rsp_data <= 32'h00020D00;
                16'h03F0 : rd_rsp_data <= 32'h04000718;
                16'h03F4 : rd_rsp_data <= 32'h6FB76FB7;
                16'h03F8 : rd_rsp_data <= 32'h0000000A;
                16'h0400 : rd_rsp_data <= 32'h007F80FF;
                16'h0404 : rd_rsp_data <= 32'h007F80FF;
                16'h0408 : rd_rsp_data <= 32'h007F80FF;
                16'h040C : rd_rsp_data <= 32'h007F80FF;
                16'h0410 : rd_rsp_data <= 32'h027F80FF;
                16'h0414 : rd_rsp_data <= 32'h007F80FF;
                16'h0418 : rd_rsp_data <= 32'h0FFF00F5;
                16'h041C : rd_rsp_data <= 32'h000000F5;
                16'h0420 : rd_rsp_data <= 32'hFF711F80;
                16'h0424 : rd_rsp_data <= 32'h6A30F5F5;
                16'h0428 : rd_rsp_data <= 32'h07070E10;
                16'h0430 : rd_rsp_data <= 32'h01000000;
                16'h0434 : rd_rsp_data <= 32'h07060504;
                16'h0438 : rd_rsp_data <= 32'h01000000;
                16'h043C : rd_rsp_data <= 32'h07060504;
                16'h0440 : rd_rsp_data <= 32'h00000FFF;
                16'h0444 : rd_rsp_data <= 32'h00000010;
                16'h0448 : rd_rsp_data <= 32'h3E0FF000;
                16'h044C : rd_rsp_data <= 32'h00000010;
                16'h0450 : rd_rsp_data <= 32'h000FF000;
                16'h0454 : rd_rsp_data <= 32'hF55E0000;
                16'h0458 : rd_rsp_data <= 32'hFFFFFFFF;
                16'h045C : rd_rsp_data <= 32'h1000F500;
                16'h0460 : rd_rsp_data <= 32'h03086666;
                16'h0464 : rd_rsp_data <= 32'h00FF00FF;
                16'h0468 : rd_rsp_data <= 32'h007F80FF;
                16'h046C : rd_rsp_data <= 32'h007F80FF;
                16'h0470 : rd_rsp_data <= 32'h007F80FF;
                16'h0474 : rd_rsp_data <= 32'h007F80FF;
                16'h0480 : rd_rsp_data <= 32'h000C0400;
                16'h04AC : rd_rsp_data <= 32'h12010200;
                16'h04B0 : rd_rsp_data <= 32'h40404040;
                16'h04BC : rd_rsp_data <= 32'h00040040;
                16'h04C0 : rd_rsp_data <= 32'h10001000;
                16'h04C4 : rd_rsp_data <= 32'h80040340;
                16'h04C8 : rd_rsp_data <= 32'h171708FF;
                16'h04CC : rd_rsp_data <= 32'h0201FF7F;
                16'h04DC : rd_rsp_data <= 32'h00000160;
                16'h04E4 : rd_rsp_data <= 32'h25240C0C;
                16'h04E8 : rd_rsp_data <= 32'h06060606;
                16'h04F0 : rd_rsp_data <= 32'h0000C100;
                16'h04F4 : rd_rsp_data <= 32'h00200001;
                16'h04FC : rd_rsp_data <= 32'hFFFF0000;
                16'h0500 : rd_rsp_data <= 32'h002F3210;
                16'h0504 : rd_rsp_data <= 32'h0000A422;
                16'h0508 : rd_rsp_data <= 32'h005EA42B;
                16'h050C : rd_rsp_data <= 32'h0000A422;
                16'h0510 : rd_rsp_data <= 32'h28004413;
                16'h0514 : rd_rsp_data <= 32'h0E100E10;
                16'h0518 : rd_rsp_data <= 32'h0916FE00;
                16'h0520 : rd_rsp_data <= 32'h00003F0F;
                16'h0524 : rd_rsp_data <= 32'h21FF4F0F;
                16'h0528 : rd_rsp_data <= 32'h806C0A8F;
                16'h0540 : rd_rsp_data <= 32'h8000FF12;
                16'h0544 : rd_rsp_data <= 32'h00400180;
                16'h0550 : rd_rsp_data <= 32'h0000001D;
                16'h0554 : rd_rsp_data <= 32'h00640064;
                16'h0558 : rd_rsp_data <= 32'h00020202;
                16'h055C : rd_rsp_data <= 32'h0F0FFF50;
                16'h0560 : rd_rsp_data <= 32'h0C4020FA;
                16'h0568 : rd_rsp_data <= 32'h0C402109;
                16'h0570 : rd_rsp_data <= 32'h000A0002;
                16'h0574 : rd_rsp_data <= 32'h03FF1000;
                16'h058C : rd_rsp_data <= 32'h06200060;
                16'h0590 : rd_rsp_data <= 32'h000F000F;
                16'h05A0 : rd_rsp_data <= 32'h02020202;
                16'h05A4 : rd_rsp_data <= 32'h00010202;
                16'h05CC : rd_rsp_data <= 32'h11E21051;
                16'h05E0 : rd_rsp_data <= 32'h00001000;
                16'h05E4 : rd_rsp_data <= 32'h00003000;
                16'h05E8 : rd_rsp_data <= 32'h00001000;
                16'h05EC : rd_rsp_data <= 32'h00000003;
                16'h05FC : rd_rsp_data <= 32'hFFFF0000;
                16'h0600 : rd_rsp_data <= 32'h04000000;
                16'h0604 : rd_rsp_data <= 32'h00003000;
                16'h0608 : rd_rsp_data <= 32'hF000780E;
                16'h060C : rd_rsp_data <= 32'h04000420;
                // 这里是模拟了一个随机MAC 但是这只是寄存器映射 实际网卡的MAC是从Efuse取出 所以这里是无效的
//                16'h0610 : begin
//                        rd_rsp_data[7:0]   <= 8'h00;
//                        rd_rsp_data[15:8]  <= 8'h0C;
//                        rd_rsp_data[23:16] <= 8'h43;
//                        rd_rsp_data[31:24] <= ((0 + (number + `MAC_RANDOM_NUM1) % (15 + 1 - 0)) << 4) | (0 + (number + `MAC_RANDOM_NUM2) % (15 + 1 - 0)); 
//                end
//                16'h0614 : begin
//                        rd_rsp_data[7:0]   <= ((0 + (number + `MAC_RANDOM_NUM3) % (15 + 1 - 0)) << 4) | (0 + (number + `MAC_RANDOM_NUM6) % (15 + 1 - 0));
//                        rd_rsp_data[15:8]  <= ((0 + (number + `MAC_RANDOM_NUM5) % (15 + 1 - 0)) << 4) | (0 + (number + `MAC_RANDOM_NUM6) % (15 + 1 - 0));
//                        rd_rsp_data[31:16] <= 16'h0000;
//                end
                16'h0610 : rd_rsp_data <= 32'h04430C00;
                16'h0614 : rd_rsp_data <= 32'h0000EB39;
                16'h0620 : rd_rsp_data <= 32'hFFFFFFFF;
                16'h0624 : rd_rsp_data <= 32'hFFFFFFFF;
                16'h0638 : rd_rsp_data <= 32'h0E102850;
                16'h063C : rd_rsp_data <= 32'h0E0E0A0A;
                16'h0640 : rd_rsp_data <= 32'h00401440;
                16'h0650 : rd_rsp_data <= 32'h00EB0426;
                16'h0658 : rd_rsp_data <= 32'hFFFFFFFF;
                16'h065C : rd_rsp_data <= 32'hFFFFFFFF;
                16'h0660 : rd_rsp_data <= 32'h00810010;
                16'h0664 : rd_rsp_data <= 32'h00000005;
                16'h0668 : rd_rsp_data <= 32'h0E301000;
                16'h066C : rd_rsp_data <= 32'h00052000;
                16'h0670 : rd_rsp_data <= 32'h000100FF;
                16'h0680 : rd_rsp_data <= 32'h000000EC;
                16'h0690 : rd_rsp_data <= 32'h000F0000;
                16'h0694 : rd_rsp_data <= 32'h000A0200;
                16'h06A4 : rd_rsp_data <= 32'h0000FFFF;
                16'h06B8 : rd_rsp_data <= 32'h00000008;
                16'h06D8 : rd_rsp_data <= 32'h0000003F;
                16'h0700 : rd_rsp_data <= 32'h04430C02;
                16'h0704 : rd_rsp_data <= 32'h0000EB39;
                16'h0708 : rd_rsp_data <= 32'h87654321;
                16'h0718 : rd_rsp_data <= 32'h20000200;
                16'h0750 : rd_rsp_data <= 32'h00000076;
                16'h0778 : rd_rsp_data <= 32'h00000001;
                16'h0794 : rd_rsp_data <= 32'h0000017F;
                16'h0798 : rd_rsp_data <= 32'h88E088E0;
                16'h079C : rd_rsp_data <= 32'h880B880B;
                16'h07A0 : rd_rsp_data <= 32'h06492A30;
                16'h07A4 : rd_rsp_data <= 32'h0B6F27C2;
                16'h07A8 : rd_rsp_data <= 32'h804040AA;
                16'h0800 : rd_rsp_data <= 32'h83040000;
                16'h0804 : rd_rsp_data <= 32'h00000003;
                16'h0808 : rd_rsp_data <= 32'h0000FC00;
                16'h080C : rd_rsp_data <= 32'h0000000A;
                16'h0810 : rd_rsp_data <= 32'h10001331;
                16'h0814 : rd_rsp_data <= 32'h020C3D10;
                16'h0818 : rd_rsp_data <= 32'h02220385;
                16'h0820 : rd_rsp_data <= 32'h01000100;
                16'h0824 : rd_rsp_data <= 32'hA1390204;
                16'h0828 : rd_rsp_data <= 32'h01000100;
                16'h082C : rd_rsp_data <= 32'h0C390204;
                16'h0830 : rd_rsp_data <= 32'h29292929;
                16'h0834 : rd_rsp_data <= 32'h29292929;
                16'h0838 : rd_rsp_data <= 32'h23232330;
                16'h083C : rd_rsp_data <= 32'h2B2B2B2B;
                16'h0840 : rd_rsp_data <= 32'h04237CE8;
                16'h0844 : rd_rsp_data <= 32'h01807C0A;
                16'h0848 : rd_rsp_data <= 32'h292B2B2B;
                16'h084C : rd_rsp_data <= 32'h29292929;
                16'h0858 : rd_rsp_data <= 32'h009A009A;
                16'h085C : rd_rsp_data <= 32'h01000014;
                16'h0860 : rd_rsp_data <= 32'h66F60010;
                16'h0864 : rd_rsp_data <= 32'h061F0010;
                16'h0868 : rd_rsp_data <= 32'h27292929;
                16'h086C : rd_rsp_data <= 32'h23232323;
                16'h0874 : rd_rsp_data <= 32'h55004200;
                16'h0878 : rd_rsp_data <= 32'h08080808;
                16'h0880 : rd_rsp_data <= 32'hB0000C1C;
                16'h0884 : rd_rsp_data <= 32'h00000001;
                16'h088C : rd_rsp_data <= 32'hCC0000C0;
                16'h0890 : rd_rsp_data <= 32'h605C0903;
                16'h0894 : rd_rsp_data <= 32'hFFFEFFFF;
                16'h0898 : rd_rsp_data <= 32'h44403C38;
                16'h089C : rd_rsp_data <= 32'h54504C48;
                16'h08A0 : rd_rsp_data <= 32'h00100000;
                16'h08A4 : rd_rsp_data <= 32'h00100000;
                16'h08A8 : rd_rsp_data <= 32'h0000010F;
                16'h08AC : rd_rsp_data <= 32'h00001C80;
                16'h08B4 : rd_rsp_data <= 32'h00030000;
                16'h08B8 : rd_rsp_data <= 32'h00107CE8;
                16'h08BC : rd_rsp_data <= 32'h00107C0A;
                16'h08C4 : rd_rsp_data <= 32'h00000B82;
                16'h08D0 : rd_rsp_data <= 32'h0000342D;
                16'h08D4 : rd_rsp_data <= 32'h0000CBD4;
                16'h08D8 : rd_rsp_data <= 32'h04010100;
                16'h08DC : rd_rsp_data <= 32'h01146E3F;
                16'h08E0 : rd_rsp_data <= 32'h02040204;
                16'h08E8 : rd_rsp_data <= 32'hF802070C;
                16'h08EC : rd_rsp_data <= 32'h29292929;
                16'h08F0 : rd_rsp_data <= 32'h29292929;
                16'h08F4 : rd_rsp_data <= 32'h80000000;
                16'h08F8 : rd_rsp_data <= 32'h00001818;
                16'h0904 : rd_rsp_data <= 32'h00000023;
                16'h0908 : rd_rsp_data <= 32'h00000208;
                16'h090C : rd_rsp_data <= 32'h81121313;
                16'h0910 : rd_rsp_data <= 32'h806C0001;
                16'h0914 : rd_rsp_data <= 32'h00000001;
                16'h091C : rd_rsp_data <= 32'h00010000;
                16'h0924 : rd_rsp_data <= 32'h00000001;
                16'h094C : rd_rsp_data <= 32'h00000008;
                16'h09C0 : rd_rsp_data <= 32'h002A513E;
                16'h09C4 : rd_rsp_data <= 32'h005B3FF5;
                16'h0A00 : rd_rsp_data <= 32'h00D047C8;
                16'h0A04 : rd_rsp_data <= 32'h81FF800C;
                16'h0A08 : rd_rsp_data <= 32'h9C408300;
                16'h0A0C : rd_rsp_data <= 32'h2E68120F;
                16'h0A10 : rd_rsp_data <= 32'h95009B78;
                16'h0A14 : rd_rsp_data <= 32'h1114D028;
                16'h0A18 : rd_rsp_data <= 32'h00881117;
                16'h0A1C : rd_rsp_data <= 32'h89140F00;
                16'h0A20 : rd_rsp_data <= 32'h1A1B0010;
                16'h0A24 : rd_rsp_data <= 32'h090E1317;
                16'h0A28 : rd_rsp_data <= 32'h00000204;
                16'h0A2C : rd_rsp_data <= 32'h00D3A000;
                16'h0A30 : rd_rsp_data <= 32'h00000001;
                16'h0A38 : rd_rsp_data <= 32'h00000001;
                16'h0A3C : rd_rsp_data <= 32'h00000006;
                16'h0A40 : rd_rsp_data <= 32'h000000F8;
                16'h0A44 : rd_rsp_data <= 32'h000000F6;
                16'h0A48 : rd_rsp_data <= 32'h00000009;
                16'h0A50 : rd_rsp_data <= 32'h630FE880;
                16'h0A54 : rd_rsp_data <= 32'h8030B3FC;
                16'h0A58 : rd_rsp_data <= 32'h02005881;
                16'h0A5C : rd_rsp_data <= 32'h0000043F;
                16'h0A60 : rd_rsp_data <= 32'h8080A903;
                16'h0A70 : rd_rsp_data <= 32'h101FFF00;
                16'h0A74 : rd_rsp_data <= 32'h00000007;
                16'h0A78 : rd_rsp_data <= 32'h00000900;
                16'h0A7C : rd_rsp_data <= 32'h225B0606;
                16'h0A80 : rd_rsp_data <= 32'h218075B1;
                16'h0AB0 : rd_rsp_data <= 32'h000000F9;
                16'h0B68 : rd_rsp_data <= 32'h80000000;
                16'h0B6C : rd_rsp_data <= 32'h80000000;
                16'h0BD8 : rd_rsp_data <= 32'h0283000F;
                16'h0BDC : rd_rsp_data <= 32'h01000000;
                16'h0BE0 : rd_rsp_data <= 32'h01000000;
                16'h0BE4 : rd_rsp_data <= 32'h01000000;
                16'h0BE8 : rd_rsp_data <= 32'h01000000;
                16'h0BEC : rd_rsp_data <= 32'h01000000;
                16'h0BF0 : rd_rsp_data <= 32'h01000000;
                16'h0BF4 : rd_rsp_data <= 32'h01000000;
                16'h0BF8 : rd_rsp_data <= 32'h01000000;
                16'h0C00 : rd_rsp_data <= 32'h48071D40;
                16'h0C04 : rd_rsp_data <= 32'h03A05633;
                16'h0C08 : rd_rsp_data <= 32'h000000E4;
                16'h0C0C : rd_rsp_data <= 32'h6C6C6C6C;
                16'h0C10 : rd_rsp_data <= 32'h08800000;
                16'h0C14 : rd_rsp_data <= 32'h4000E907;
                16'h0C18 : rd_rsp_data <= 32'h08800000;
                16'h0C1C : rd_rsp_data <= 32'h40000105;
                16'h0C30 : rd_rsp_data <= 32'h69E9AC47;
                16'h0C34 : rd_rsp_data <= 32'h469652AF;
                16'h0C38 : rd_rsp_data <= 32'h49795994;
                16'h0C3C : rd_rsp_data <= 32'h0A97971C;
                16'h0C40 : rd_rsp_data <= 32'h1F7C403F;
                16'h0C44 : rd_rsp_data <= 32'h000100B7;
                16'h0C48 : rd_rsp_data <= 32'hEC020107;
                16'h0C4C : rd_rsp_data <= 32'h00F603FD;
                16'h0C50 : rd_rsp_data <= 32'h0004002A;
                16'h0C54 : rd_rsp_data <= 32'h0080801F;
                16'h0C58 : rd_rsp_data <= 32'h0000002A;
                16'h0C5C : rd_rsp_data <= 32'h00248492;
                16'h0C64 : rd_rsp_data <= 32'h2112848B;
                16'h0C68 : rd_rsp_data <= 32'h47C00BFF;
                16'h0C6C : rd_rsp_data <= 32'h00000036;
                16'h0C70 : rd_rsp_data <= 32'h00000600;
                16'h0C74 : rd_rsp_data <= 32'h02013269;
                16'h0C78 : rd_rsp_data <= 32'h407F0001;
                16'h0C7C : rd_rsp_data <= 32'h00B91612;
                16'h0C80 : rd_rsp_data <= 32'h400100FE;
                16'h0C84 : rd_rsp_data <= 32'h21F60000;
                16'h0C88 : rd_rsp_data <= 32'h40040100;
                16'h0C8C : rd_rsp_data <= 32'hA0E40000;
                16'h0C90 : rd_rsp_data <= 32'h00121820;
                16'h0C98 : rd_rsp_data <= 32'h00121820;
                16'h0C9C : rd_rsp_data <= 32'h00007F7F;
                16'h0CA0 : rd_rsp_data <= 32'hF0000000;
                16'h0CA4 : rd_rsp_data <= 32'h000300A0;
                16'h0CBC : rd_rsp_data <= 32'h28000000;
                16'h0CD8 : rd_rsp_data <= 32'h64B22427;
                16'h0CDC : rd_rsp_data <= 32'h00766932;
                16'h0CE0 : rd_rsp_data <= 32'h00222222;
                16'h0CE4 : rd_rsp_data <= 32'h00040000;
                16'h0CE8 : rd_rsp_data <= 32'h77644302;
                16'h0CEC : rd_rsp_data <= 32'h2F97D40C;
                16'h0CF0 : rd_rsp_data <= 32'h00C70000;
                16'h0CF4 : rd_rsp_data <= 32'h00230000;
                16'h0CFC : rd_rsp_data <= 32'h80000000;
                16'h0D00 : rd_rsp_data <= 32'h00080740;
                16'h0D04 : rd_rsp_data <= 32'h00020403;
                16'h0D08 : rd_rsp_data <= 32'h0000907F;
                16'h0D0C : rd_rsp_data <= 32'h20010201;
                16'h0D10 : rd_rsp_data <= 32'hA0633333;
                16'h0D14 : rd_rsp_data <= 32'h3333BC43;
                16'h0D18 : rd_rsp_data <= 32'h7A8F5B6B;
                16'h0D1C : rd_rsp_data <= 32'h0000007F;
                16'h0D2C : rd_rsp_data <= 32'hCC979975;
                16'h0D34 : rd_rsp_data <= 32'h40608000;
                16'h0D3C : rd_rsp_data <= 32'h00127353;
                16'h0D50 : rd_rsp_data <= 32'h6437140A;
                16'h0D58 : rd_rsp_data <= 32'h00000282;
                16'h0D5C : rd_rsp_data <= 32'h30032064;
                16'h0D60 : rd_rsp_data <= 32'h4653DA68;
                16'h0D64 : rd_rsp_data <= 32'h04518A3C;
                16'h0D68 : rd_rsp_data <= 32'h00002101;
                16'h0D6C : rd_rsp_data <= 32'h2A201C16;
                16'h0D70 : rd_rsp_data <= 32'h1812362E;
                16'h0D74 : rd_rsp_data <= 32'h322C2220;
                16'h0D78 : rd_rsp_data <= 32'h000E3C24;
                16'h0D80 : rd_rsp_data <= 32'h01081008;
                16'h0D84 : rd_rsp_data <= 32'h00000800;
                16'h0D88 : rd_rsp_data <= 32'hF0B50000;
                16'h0DA0 : rd_rsp_data <= 32'h054D0B85;
                16'h0DA4 : rd_rsp_data <= 32'h0034059D;
                16'h0DA8 : rd_rsp_data <= 32'h0000002B;
                16'h0DAC : rd_rsp_data <= 32'h07900790;
                16'h0DB0 : rd_rsp_data <= 32'h0B040CC6;
                16'h0DB4 : rd_rsp_data <= 32'h0B040CC6;
                16'h0DB8 : rd_rsp_data <= 32'h010B00D5;
                16'h0DBC : rd_rsp_data <= 32'h0B470AB4;
                16'h0DC4 : rd_rsp_data <= 32'h03FA0000;
                16'h0DC8 : rd_rsp_data <= 32'h00000018;
                16'h0DCC : rd_rsp_data <= 32'h00000002;
                16'h0DD0 : rd_rsp_data <= 32'h00001108;
                16'h0DD4 : rd_rsp_data <= 32'h00000007;
                16'h0DD8 : rd_rsp_data <= 32'h80E10823;
                16'h0DDC : rd_rsp_data <= 32'h80003102;
                16'h0DE0 : rd_rsp_data <= 32'h0CC60CC6;
                16'h0DE8 : rd_rsp_data <= 32'h0002447C;
                16'h0DF4 : rd_rsp_data <= 32'h205E7000;
                16'h0DF8 : rd_rsp_data <= 32'h00000028;
                16'h0E00 : rd_rsp_data <= 32'h29292929;
                16'h0E04 : rd_rsp_data <= 32'h29292929;
                16'h0E08 : rd_rsp_data <= 32'h03902330;
                16'h0E0C : rd_rsp_data <= 32'h00000007;
                16'h0E10 : rd_rsp_data <= 32'h2B2B2B2B;
                16'h0E14 : rd_rsp_data <= 32'h292B2B2B;
                16'h0E18 : rd_rsp_data <= 32'h29292929;
                16'h0E1C : rd_rsp_data <= 32'h27292929;
                16'h0E28 : rd_rsp_data <= 32'h00000058;
                16'h0E30 : rd_rsp_data <= 32'h01008C00;
                16'h0E34 : rd_rsp_data <= 32'h01008C00;
                16'h0E38 : rd_rsp_data <= 32'h821608FF;
                16'h0E3C : rd_rsp_data <= 32'h281608FF;
                16'h0E40 : rd_rsp_data <= 32'h81037C02;
                16'h0E44 : rd_rsp_data <= 32'h01004800;
                16'h0E48 : rd_rsp_data <= 32'hF8000000;
                16'h0E4C : rd_rsp_data <= 32'h0046A891;
                16'h0E50 : rd_rsp_data <= 32'h38008C1C;
                16'h0E54 : rd_rsp_data <= 32'h18008C1C;
                16'h0E58 : rd_rsp_data <= 32'h821608FF;
                16'h0E5C : rd_rsp_data <= 32'h281608FF;
                16'h0E60 : rd_rsp_data <= 32'h00000048;
                16'h0E68 : rd_rsp_data <= 32'h0FC05656;
                16'h0E6C : rd_rsp_data <= 32'h03C09696;
                16'h0E70 : rd_rsp_data <= 32'h03C09696;
                16'h0E74 : rd_rsp_data <= 32'h0C005656;
                16'h0E78 : rd_rsp_data <= 32'h0C005656;
                16'h0E7C : rd_rsp_data <= 32'h0C005656;
                16'h0E80 : rd_rsp_data <= 32'h0C005656;
                16'h0E84 : rd_rsp_data <= 32'h03C09696;
                16'h0E88 : rd_rsp_data <= 32'h0C005656;
                16'h0E8C : rd_rsp_data <= 32'h03C09696;
                16'h0E90 : rd_rsp_data <= 32'h000001EC;
                16'h0E94 : rd_rsp_data <= 32'h01000000;
                16'h0E98 : rd_rsp_data <= 32'h0000007C;
                16'h0EA0 : rd_rsp_data <= 32'h0012C088;
                16'h0EA4 : rd_rsp_data <= 32'h01080000;
                16'h0EA8 : rd_rsp_data <= 32'h00001330;
                16'h0EAC : rd_rsp_data <= 32'h27FBA000;
                16'h0EB0 : rd_rsp_data <= 32'h000003C4;
                16'h0EB4 : rd_rsp_data <= 32'h01030000;
                16'h0EB8 : rd_rsp_data <= 32'h00000078;
                16'h0EBC : rd_rsp_data <= 32'h00020000;
                16'h0EC0 : rd_rsp_data <= 32'h00056F28;
                16'h0EC4 : rd_rsp_data <= 32'h01050000;
                16'h0EC8 : rd_rsp_data <= 32'h00000AC0;
                16'h0ED0 : rd_rsp_data <= 32'h03C09696;
                16'h0ED4 : rd_rsp_data <= 32'h03C09696;
                16'h0ED8 : rd_rsp_data <= 32'h03C09696;
                16'h0EDC : rd_rsp_data <= 32'h0000D6D6;
                16'h0EE0 : rd_rsp_data <= 32'h0000D6D6;
                16'h0EE4 : rd_rsp_data <= 32'hB0000C1C;
                16'h0EE8 : rd_rsp_data <= 32'h00000001;
                16'h0EEC : rd_rsp_data <= 32'h0FC01616;
                16'h0EF0 : rd_rsp_data <= 32'h83040000;
                16'h0EF4 : rd_rsp_data <= 32'h00000003;
                16'h0F00 : rd_rsp_data <= 32'h00000300;
                16'h0F14 : rd_rsp_data <= 32'h00000003;
                16'h0F80 : rd_rsp_data <= 32'h00000003;
                16'h0F84 : rd_rsp_data <= 32'h00000008;
                16'h0F88 : rd_rsp_data <= 32'h00000025;
                16'h0F94 : rd_rsp_data <= 32'h01570000;
                16'h0FA0 : rd_rsp_data <= 32'h03AB0000;
                16'h0FA4 : rd_rsp_data <= 32'h00010E9F;
                16'h0FA8 : rd_rsp_data <= 32'h0000CA0D;
                16'h0FAC : rd_rsp_data <= 32'h0002DC0E;
                16'h0FB0 : rd_rsp_data <= 32'h0940040A;
                16'h0FB4 : rd_rsp_data <= 32'h000098B6;
                default: rd_rsp_data <= 32'h00000000;
            endcase
        end else if (dwr_valid) begin
            case (({dwr_addr[31:24], dwr_addr[23:16], dwr_addr[15:08], dwr_addr[07:00]} - (base_address_register & 32'hFFFFFFF0)) & 32'hFFFF)
                //Dont be scared
            endcase
        end else begin
            rd_rsp_data <= 32'h00000000;
        end
    end
            
endmodule
