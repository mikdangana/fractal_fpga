
library IEEE;


PACKAGE reg24gen_package IS
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.math_real.all;
	
    type dist_type is (UNIFORM_DIST, NORMAL_DIST, EXPONENTIAL_DIST);
    type tuple is array (0 to 1) of natural;
    
	function log2ceil(n : natural) return natural;
	function childCnt(l : natural) return natural;
	function max(L, R: integer) return integer;
	function min(L, R: integer) return integer;
	function logNceil(val : natural; base : natural) return natural;
	function get_addr(path : natural; n : natural) return tuple;
	
	CONSTANT FULL_PRECISION : INTEGER := 1;
	CONSTANT LOG_FP : INTEGER := 7;
	CONSTANT PADDING : INTEGER := 1;
	CONSTANT PWIDTH : INTEGER := 1;
	CONSTANT N_BATCH : INTEGER := 1;
	CONSTANT N_SHARDS : INTEGER := 1;
	CONSTANT N : INTEGER := 8;  --fanout
	CONSTANT LOGN : INTEGER := log2ceil(N); --depth
	CONSTANT LOGNSIZE : INTEGER := 2; --depth
    CONSTANT PRECISION : INTEGER := 6;
    CONSTANT SIZE_PRECISION : INTEGER := 10;
	CONSTANT RAW_PRECISION : INTEGER := 128;
	CONSTANT PRECISIONS : INTEGER := 2*LOGN+43; --21; --PRECISION + SIZE_PRECISION;
	CONSTANT BASE_INPUT_SIZE : INTEGER := 9;
	CONSTANT DEVICE_PINS : INTEGER := 100; -- 550;
    CONSTANT INPUT_SIZE : INTEGER := N; --4*BASE_INPUT_SIZE; --8*8*8*9=4608; --depth*fanout*base_size --1152; --9216; --288/PRECISION;
    CONSTANT DATASET_SIZE: INTEGER := 2**28;
    CONSTANT W_ADDR : INTEGER := 16;
    CONSTANT RAM_LEN: INTEGER := (2**20) / W_ADDR; --(2**28) / W_ADDR;
    CONSTANT N_BKTS: INTEGER := 2;  -- slot 0: write zeros+ones count; slot 1: read-back for accumulation

    -- Histogram constants
    CONSTANT LC : INTEGER := 20;  -- max histogram level
    CONSTANT NODE_LEVELS : INTEGER := log2ceil(INPUT_SIZE);  -- log2ceil(INPUT_SIZE)
    CONSTANT KEY_WIDTH : INTEGER := 42;  -- PRECISIONS - (2*LOGN+1) = 49-7
    CONSTANT HIST_DEPTH : INTEGER := 2097152;  -- 2^(LC+1)

    -- Phase 1 scatter-bin constants
    CONSTANT N_BINS : INTEGER := 8;  -- small for testing, target 1024-4096
    CONSTANT BIN_ID_BITS : INTEGER := 3;  -- log2ceil(N_BINS)
    CONSTANT BIN_ENTRY_WIDTH : INTEGER := KEY_WIDTH - BIN_ID_BITS;  -- trailing bits per entry
    -- SRAM bin depth per bin (on-chip write buffer before HBM drain)
    CONSTANT BIN_BUF_DEPTH : INTEGER := 64;  -- entries per bin buffer
    CONSTANT BIN_BUF_ADDR_BITS : INTEGER := 6;  -- log2ceil(BIN_BUF_DEPTH)

    -- Physical memory channel counts (stride for drain)
    CONSTANT N_HBM_CHAN : INTEGER := 8;   -- HBM pseudo-channels drained per cc
    CONSTANT N_DRAM_CHAN : INTEGER := 4;  -- DRAM channels
    CONSTANT N_SSD_CHAN : INTEGER := 2;   -- SSD channels

    -- HBM payload: 256 bits per pseudo-channel
    CONSTANT HBM_PAYLOAD_BITS : INTEGER := 256;
    CONSTANT HBM_ENTRIES_PER_PAYLOAD : INTEGER := HBM_PAYLOAD_BITS / BIN_ENTRY_WIDTH;

    -- SRAM throttle: pause input when total bin occupancy exceeds this (in entries)
    -- 256Mb / BIN_ENTRY_WIDTH bits per entry
    CONSTANT SRAM_THROTTLE_ENTRIES : INTEGER := 256 * 1024 * 1024 / BIN_ENTRY_WIDTH;

    -- Max entries per bin in HBM (address space reservation)
    CONSTANT MAX_BIN_ENTRIES : INTEGER := DATASET_SIZE / N_BINS;

    -- Pipeline latency: 2 clocked stages per level (fs_scatter + ff_dp_partition),
    -- minus 1 since last level has no ff_dp_partition after it
    CONSTANT PIPELINE_LATENCY : INTEGER := 2 * (RAW_PRECISION / log2ceil(INPUT_SIZE)) - 1;

    -- Function to generate a set of N random numbers
    impure function generate_rand_set(
        n    : positive; 
        dist : dist_type; 
        seed1   : positive; -- Passed inout to maintain state
        seed2   : positive; -- Passed inout to maintain state
        mean : real := 0.0; 
        std  : real := 1.0
    ) return std_logic_vector;

END reg24gen_package;


PACKAGE BODY reg24gen_package IS

    function log2ceil(n : natural) return natural is
        variable r : natural := 0;
        variable v : natural;
    begin
        -- Handle the edge case for n=0 or n=1
        if n <= 1 then 
            return 0; 
        end if;
    
        v := n - 1;
        -- Use a static for loop so the synthesizer can unroll it
        for i in 0 to 31 loop
            if v > 0 then
                v := v / 2;
                r := r + 1;
            else
                exit; -- Exit early once v reaches 0
            end if;
        end loop;
        
        return r;
    end function;
	
	function logNceil(val : natural; base : natural) return natural is
        variable r : natural := 0;
        variable v : natural;
    begin
        -- Handle edge cases for base 0 or 1 to prevent infinite loops
        if base < 2 then 
            return 0; 
        end if;
    
        if val <= 1 then
            return 0;
        else
            v := val - 1;
            while v > 0 loop
                v := v / base;
                r := r + 1;
            end loop;
            return r;
        end if;
    end function;
	
	function childCnt(l : natural) return natural is
	begin
		 return (INPUT_SIZE / (N**l))-1;
	end function;
	
	-- Define the function for the specific type you need (e.g., integer)
    function max(L, R: integer) return integer is
    begin
        if L > R then return L;
        else return R;
        end if;
    end function;
    
    function min(L, R: integer) return integer is
    begin
        if L <= R then return L;
        else return R;
        end if;
    end function;


    impure function generate_rand_set(
        n                : positive; 
        dist             : dist_type; 
        seed1   : positive; -- Passed inout to maintain state
        seed2   : positive; -- Passed inout to maintain state
        mean             : real := 0.0; 
        std              : real := 1.0
    ) return std_logic_vector is
        variable result : std_logic_vector(n*RAW_PRECISION-1 downto 0);
        variable u1, u2 : real;
        variable temp   : real;
        variable s1: positive := seed1;
        variable s2: positive := seed2;
    begin
        for i in 0 to n-1 loop
            uniform(s1, s2, u1); 
            
            case dist is
                when UNIFORM_DIST =>
                    result((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION) := 
                        std_logic_vector(to_unsigned(integer(round((u1 - 0.5) * (2.0 * std) + mean)), RAW_PRECISION));
    
                when NORMAL_DIST =>
                    uniform(s1, s2, u2);
                    temp := sqrt(-2.0 * log(u1)) * cos(MATH_2_PI * u2);
                    result((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION) := 
                        std_logic_vector(to_unsigned(integer(round((temp * std) + mean)), RAW_PRECISION));
    
                when EXPONENTIAL_DIST =>
                    result((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION) := 
                        std_logic_vector(to_unsigned(integer(round(-mean * log(u1))), RAW_PRECISION));
            end case;
        end loop;
        return result;
    end function;
    
    function get_addr(path : natural; n : natural) return tuple is
        variable l   : natural := log2ceil(path);
        -- Ensure w doesn't go below 0 later in calculations
        variable w   : natural := max(log2ceil(n)+1, l);
        variable d   : natural := 0;
        variable pos : natural := 0;
    begin
        -- 2. Use a static for-loop to satisfy the synthesizer
        -- 31 is the max bits for a 'natural', so 'l' cannot exceed this.
        for i in 0 to 31 loop
            if d < l then
                pos := pos + w * (2**(d+1));
                w   := w - 1;
                d   := d + 1;
            else
                exit; -- Exit as soon as we reach the calculated depth 'l'
            end if;
        end loop;
    
        -- 3. Return the record
        return (pos + w * max(0, path - 2**max(0, d-1)), w);
    end function;
END PACKAGE BODY;

-- clk = 100MHz:
----------------
-- Throughput (T_bits): 6 * 8 * 8 * 9 * 100MHz = 345600Mb/s = 345.6Gb/s = 43.2GB/s
-- Throughput (T_records): T_bits / 20 = 2.16G records/s

-- clk = 150MHz:
----------------
-- T_bits = 64.8 GB/s = 518.4 Gb/s
-- T_records = 25.85G records/s

-- clk = 300MHz:
----------------
-- T_bits = 1035 Gb/s = 1.035 Tb/s
-- T_records = 51.75G records/s


library IEEE;

USE work.reg24gen_package.ALL;
use IEEE.STD_LOGIC_1164.ALL;
   use ieee.numeric_std.all;
use STD.TEXTIO.ALL;

entity counter is
    Generic ( LEVEL_SIZE : integer := INPUT_SIZE;
	           N_FF_NODES: integer := 1;
	           N_LEVELS: integer := RAW_PRECISION / log2ceil(INPUT_SIZE); --21;
	           N_BASE : integer := INPUT_SIZE / BASE_INPUT_SIZE;
			     N32: integer := 32;
			     P: integer := 0;
			     P_CACHE: integer := 28;
			     P_COMPUTABLE: integer := 32;
	           FF_LEVEL_WIDTH: integer := 1;
				 FF_N : integer := 2 ;
			     FF_LEVEL_SIZE : integer := INPUT_SIZE );
				  --LEVEL_SIZE : integer := INPUT_SIZE; --PWIDTH;
	           --PRECISIONS : integer := PRECISIONS;
				  --PADDING : integer := PADDING );
	 Port ( clk : in std_logic;
	        reset : in std_logic;
			  numbers_p : in std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
			  starts_p : in std_logic_vector(LEVEL_SIZE*log2ceil(LEVEL_SIZE)-1 downto 0);
			  start : in integer;                                              -- Inclusive index
			  stop : in integer;                                               -- Non-inclusive index
			  sorted_p : out std_logic_vector(LEVEL_SIZE-1 downto 0); -- := (LEVEL_SIZE-1 downto 0 => '0');
			  --indices : out std_logic_vector(LEVEL_SIZE*(SIZE_PRECISION+PRECISION)-1 downto 0);
			  numout_p : out std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
			  --filterout: out std_logic_vector(LEVEL_SIZE-1 downto 0);
			  startout_p : out std_logic_vector(LEVEL_SIZE*log2ceil(LEVEL_SIZE)-1 downto 0);
			  count : out integer := 0;
	          fifo_wr_en: out std_logic;
	          fifo_re_en: out std_logic;
	          fifo_dw: out std_logic_vector(4*W_ADDR-1 downto 0);
	          fifo_dr: in std_logic_vector(4*W_ADDR-1 downto 0);
	          fifo_dready: in std_logic;
	          -- HBM controller interface
	          hbm_wr_en : out std_logic;
	          hbm_dout  : out std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
	          hbm_ready : in std_logic;
	          -- DRAM controller interface
	          dram_wr_en : out std_logic;
	          dram_dout  : out std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
	          dram_ready : in std_logic;
	          -- SSD controller interface
	          ssd_wr_en : out std_logic;
	          ssd_dout  : out std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
	          ssd_ready : in std_logic;
	          -- Phase control
	          phase1_complete : in std_logic;
	          sort_complete : out std_logic;
	          -- HBM write address (for both Phase 1 drain and Phase 2 write-back)
	          hbm_wr_addr : out std_logic_vector(31 downto 0);
	          -- HBM read interface (Phase 2 readback)
	          hbm_rd_req  : out std_logic;
	          hbm_rd_addr : out std_logic_vector(31 downto 0);
	          hbm_rd_data : in std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
	          hbm_rd_valid : in std_logic);
end counter;

architecture Behavioral of counter is

	component sub_counter is
         --Generic ( LEVEL_SIZE : integer := COUNTER_INPUT_SIZE;
	     --          PRECISIONS : integer := PRECISIONS;
		--		   PADDING : integer := PADDING );
		 Port ( clk : in std_logic;
		        reset : in std_logic;
			     d_p : in std_logic_vector;
			     numbers_p : in std_logic_vector;
				  start : in integer;
				  stop : in integer;
				  sorted_p : out std_logic_vector;
				  --indices : out std_logic_vector;
				  numout_p : out std_logic_vector;
				  --filterout: out std_logic_vector(LEVEL_SIZE-1 downto 0);
				  count : out integer );
	end component;
	
	type level_n_ints is array(N-1 downto 0) of integer;
	type level_ints is array(LEVEL_SIZE-1 downto 0) of integer;
	type level_tuples is array(log2ceil(N)-1 downto 0, LEVEL_SIZE-1 downto 0, 3 downto 0) of integer;
	type level_logints is array(LOGN-1 downto 0, N-1 downto 0) of integer;

	type level_nums is array(N-1 downto 0) of std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	
	-- Child node size: each child GeneralCase works on LEVEL_SIZE / N bits
    constant CHILD_LEVEL_SIZE : integer := LEVEL_SIZE / N;

    -- 1-D arrays for child-level slices and outputs
    type slv_child_arr      is array (natural range <>) of std_logic_vector(CHILD_LEVEL_SIZE-1 downto 0);
    type slv_child_prec_arr is array (natural range <>) of std_logic_vector(CHILD_LEVEL_SIZE*PRECISIONS-1 downto 0);
    type slv_ram_arr        is array (natural range <>) of std_logic_vector(W_ADDR-1 downto 0);
    type slv_ram_2darr      is array (natural range <>, natural range <>) of std_logic_vector(W_ADDR-1 downto 0);
    type int_child_arr      is array (natural range <>) of integer;
    type int_arr_t is array (integer range <>) of integer;
    type addr_array is array (natural range<>) of std_logic_vector(31 downto 0);
    type data_array is array (natural range<>) of std_logic_vector(2*W_ADDR-1 downto 0);

	
	-- Number of BaseCase tiles
    --constant N_BASE : integer := INPUT_SIZE / BASE_INPUT_SIZE;
    
    -- Small helper array types for BaseCase replication
    type slv1_arr  is array (natural range <>, natural range <>) of std_logic_vector(0 downto 0);
    type slv2_arr  is array (natural range <>, natural range <>) of std_logic_vector(1 downto 0);
    type slv3_arr  is array (natural range <>, natural range <>) of std_logic_vector(2 downto 0);
    
    type slv_p_arr     is array (natural range <>, natural range <>) of std_logic_vector(PRECISIONS-1 downto 0);
    type slv_2p_arr    is array (natural range <>, natural range <>) of std_logic_vector(2*PRECISIONS-1 downto 0);
    type slv_3p_arr    is array (natural range <>, natural range <>) of std_logic_vector(3*PRECISIONS-1 downto 0);
    type slv_base_arr  is array (natural range <>, natural range <>) of std_logic_vector(BASE_INPUT_SIZE-1 downto 0);
    type slv_basep_arr is array (natural range <>, natural range <>) of std_logic_vector(BASE_INPUT_SIZE*PRECISIONS-1 downto 0);
    
    type count_1d_t is array (natural range <>) of integer range 0 to LEVEL_SIZE;
    type count_2d_t is array (natural range <>, natural range <>) of integer range 0 to LEVEL_SIZE;
    type count_3d_t is array (natural range<>, natural range <>, natural range <>) of integer range 0 to LEVEL_SIZE;

	
	--signal test: std_logic_vector(100000000-1 downto 0);
	--signal start : integer := rhs * pivot;
	--signal stop : integer := pivot * (1 - rhs) + rhs * (LEVEL_SIZE - 1); -- d'Length * rhs
	--signal filter: std_logic_vector(LEVEL_SIZE-1 downto 0); -- := to_bitvector(std_logic_vector(to_unsigned(rhs, LEVEL_SIZE))); --(stop downto start => '1', others => '0'); 
	--signal filtered: std_logic_vector(LEVEL_SIZE-1 downto 0); -- := d and filter; 
	
	--signal d : std_logic_vector(LEVEL_SIZE-1 downto 0);
   --signal numbers : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
   --signal sorted : std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');

			  --indices : out std_logic_vector(LEVEL_SIZE*(SIZE_PRECISION+PRECISION)-1 downto 0);
   --signal numout : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	
	
    alias MyNumbers: std_logic_vector(numbers_p'Length-1 downto 0) IS numbers_p; --LEVEL_SIZE*PRECISIONS-1 downto 0) IS numbers;
   
    signal node_ids_0 : std_logic_vector(numbers_p'Length-1 downto 0);
    --signal raw_numbers : std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0) := (others => '0');
    
       -- Per-child input slices (combinational views of MyInput / MyNumbers)
    signal child_in      : slv_child_arr      (0 to N-1);
    signal child_numbers : slv_child_prec_arr (0 to N-1);

    -- Per-child outputs (what the recursive counters used to produce)
    signal child_sorted  : slv_child_arr      (0 to N-1);
    signal child_numout  : slv_child_prec_arr (0 to N-1);
    signal child_count   : int_child_arr      (0 to N-1);
 
    -- Enough space for all levels; second dimension sized by N_BASE
    --signal node_ids : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal sorted_start_level : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    signal sorted_end_level   : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    -- Per-node counts of d_p=0 and d_p=1 entries within each node's [start,end) range.
    -- split_level(l,pos) = sorted_start_level(l,pos) + node_zeros(l,pos)
    --   = first position of the 1-group after the 0-group is placed.
    signal node_zeros  : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal node_ones   : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal split_level : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal fs_total_ones : count_1d_t(0 to N_LEVELS-1) := (others => 0);
    -- Prefix sums: cumulative zeros/ones before each node (for ff_dp_partition)
    signal zeros_before : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal ones_before  : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    -- Histogram memory (URAM-inferred)
    type hist_mem_t is array (0 to HIST_DEPTH-1) of std_logic_vector(W_ADDR-1 downto 0);
    signal hist_mem : hist_mem_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of hist_mem : signal is "ultra";

    -- Histogram memory interface signals
    signal hist_rd_addr : integer range 0 to HIST_DEPTH-1 := 0;
    signal hist_rd_data : std_logic_vector(W_ADDR-1 downto 0) := (others => '0');
    signal hist_wr_addr : integer range 0 to HIST_DEPTH-1 := 0;
    signal hist_wr_data : std_logic_vector(W_ADDR-1 downto 0) := (others => '0');
    signal hist_wr_en   : std_logic := '0';

    -- Phase 1 SRAM bin buffers: N_BINS bins, each BIN_BUF_DEPTH entries deep
    -- Implemented as a single URAM block addressed by (bin_id * BIN_BUF_DEPTH + offset)
    constant BIN_SRAM_DEPTH : integer := N_BINS * BIN_BUF_DEPTH;  -- total SRAM entries
    type bin_sram_t is array (0 to BIN_SRAM_DEPTH-1) of std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    signal bin_sram : bin_sram_t := (others => (others => '0'));
    attribute ram_style of bin_sram : signal is "ultra";

    -- Per-bin write/read pointers and fill counts
    type bin_ptr_t is array (0 to N_BINS-1) of integer range 0 to BIN_BUF_DEPTH-1;
    type bin_cnt_t is array (0 to N_BINS-1) of integer range 0 to BIN_BUF_DEPTH;
    signal bin_wr_ptr : bin_ptr_t := (others => 0);
    signal bin_rd_ptr : bin_ptr_t := (others => 0);
    signal bin_count  : bin_cnt_t := (others => 0);

    -- Total SRAM occupancy for throttle
    signal sram_total_entries : integer range 0 to BIN_SRAM_DEPTH := 0;
    signal throttle_active : std_logic := '0';

    -- Per-entry scatter: extract bin_id and trailing bits from each pipeline output
    type scatter_bin_id_t is array (0 to LEVEL_SIZE-1) of integer range 0 to N_BINS-1;
    type scatter_entry_t is array (0 to LEVEL_SIZE-1) of std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    signal scatter_bin_ids : scatter_bin_id_t := (others => 0);
    signal scatter_entries : scatter_entry_t := (others => (others => '0'));
    signal scatter_valid   : std_logic_vector(LEVEL_SIZE-1 downto 0) := (others => '0');

    -- Scatter write serializer: N entries per cc but SRAM has limited write ports
    -- We serialize N writes over N sub-cycles using a write index
    signal scatter_wr_idx : integer range 0 to LEVEL_SIZE-1 := 0;
    signal scatter_pending : std_logic := '0';

    -- HBM drain: round-robin with stride N_HBM_CHAN
    signal drain_base : integer range 0 to N_BINS-1 := 0;  -- base bin for current drain window
    signal drain_sub  : integer range 0 to N_HBM_CHAN-1 := 0;  -- sub-channel within window

    -- Phase control
    type phase_t is (PHASE1_SCATTER, PHASE1_FLUSH, PHASE2_SORT, PHASE_DONE);
    signal phase : phase_t := PHASE1_SCATTER;

    -- Phase 1 HBM write: per-bin entry counts for Phase 2 readback
    type bin_hbm_cnt_t is array (0 to N_BINS-1) of integer range 0 to MAX_BIN_ENTRIES;
    signal hbm_bin_wr_count : bin_hbm_cnt_t := (others => 0);

    -- Phase 1/2 HBM output mux intermediates
    signal p1_hbm_wr_en   : std_logic := '0';
    signal p1_hbm_dout    : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0) := (others => '0');
    signal p1_hbm_wr_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal p2_hbm_wr_en   : std_logic := '0';
    signal p2_hbm_dout    : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0) := (others => '0');
    signal p2_hbm_wr_addr : std_logic_vector(31 downto 0) := (others => '0');

    -- Phase 2 state
    type p2_state_t is (P2_IDLE, P2_REQ_READ, P2_WAIT_READ, P2_SORT_WAIT,
                        P2_WRITE_OUT, P2_NEXT_BATCH, P2_NEXT_BIN, P2_DONE);
    signal p2_state : p2_state_t := P2_IDLE;
    signal p2_curr_bin : integer range 0 to N_BINS-1 := 0;
    signal p2_read_idx : integer := 0;
    signal p2_batch_fill : integer range 0 to LEVEL_SIZE := 0;
    signal p2_batch_buf : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (others => '0');
    signal p2_sort_count : integer range 0 to PIPELINE_LATENCY + 2 := 0;
    signal p2_write_idx : integer range 0 to LEVEL_SIZE := 0;
    signal p2_batch_valid : integer range 0 to LEVEL_SIZE := 0;  -- entries in current batch
    signal p2_bin_write_count : integer := 0;
    signal p2_finished : std_logic := '0';

    -- Pipeline input mux
    signal pipeline_input : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
    



	--signal e1_1: std_logic_vector(0 downto 0) := (0 downto 0 => '0');
	--signal e1_2: std_logic_vector(1 downto 0) := (1 downto 0 => '0');
	--signal e1_3: std_logic_vector(2 downto 0) := (2 downto 0 => '0');
	--signal e2_1: std_logic_vector(0 downto 0) := (0 downto 0 => '0');
	--signal e2_2: std_logic_vector(1 downto 0) := (1 downto 0 => '0');
	--signal e2_3: std_logic_vector(2 downto 0) := (2 downto 0 => '0');
	--signal e3_1: std_logic_vector(0 downto 0) := (0 downto 0 => '0');
	--signal e3_2: std_logic_vector(1 downto 0) := (1 downto 0 => '0');
	--signal e3_3: std_logic_vector(2 downto 0) := (2 downto 0 => '0');
	--signal n1_1: std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	--signal n1_2: std_logic_vector(2*PRECISIONS-1 downto 0) := (2*PRECISIONS-1 downto 0 => '0');
	--signal n1_3: std_logic_vector(3*PRECISIONS-1 downto 0) := (3*PRECISIONS-1 downto 0 => '0');
	--signal n2_1: std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	--signal n2_2: std_logic_vector(2*PRECISIONS-1 downto 0) := (2*PRECISIONS-1 downto 0 => '0');
	--signal n2_3: std_logic_vector(3*PRECISIONS-1 downto 0) := (3*PRECISIONS-1 downto 0 => '0');
	--signal n3_1: std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	--signal n3_2: std_logic_vector(2*PRECISIONS-1 downto 0) := (2*PRECISIONS-1 downto 0 => '0');
	--signal n3_3: std_logic_vector(3*PRECISIONS-1 downto 0) := (3*PRECISIONS-1 downto 0 => '0');

	signal sorted1: std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
	--signal indices1: std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	--signal indices2: std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	--signal numbers1: level_logics(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => (PRECISIONS-1 downto 0 => '0')); --std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	--signal numbers2: std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	--signal numsout: level_nums := (N-1 downto 0 => (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0'));
	--signal filtered1: std_logic_vector(LEVEL_SIZE-1 downto 0);
	--signal o1: std_logic_vector(BASE_INPUT_SIZE-1 downto 0);
	--signal o2: std_logic_vector(BASE_INPUT_SIZE*PRECISIONS-1 downto 0);
	--signal o3: std_logic_vector(BASE_INPUT_SIZE*PRECISIONS-1 downto 0);

	--signal offset1: integer := 0;
	--signal offset2: integer := 0;
   --signal offset3: integer := 0;
	signal tcount : integer := 0;
	signal counts: level_logints := (LOGN-1 downto 0 => (N-1 downto 0 => 0));

	signal starts : level_ints := (LEVEL_SIZE-1 downto 0 => 0);
	signal stops : level_ints := (LEVEL_SIZE-1 downto 0 => 0);
	signal icount : integer := 0;
	
	-- How many ffnode instances?
	--constant N_FF_NODES : positive := 4;  -- <<< set as needed

	signal one : std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0'); 
	signal zero : std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0'); 
	signal zero_LEVEL_SIZE : std_logic_vector(FF_LEVEL_SIZE-1 downto 0) := (FF_LEVEL_SIZE-1 downto 0 => '0');
	signal mem_addr: integer := 0;
	signal mem_value: std_logic_vector(4*W_ADDR downto 0) := (others => '0');
	signal mem_addr1: integer := 0;
	signal mem_value1: std_logic_vector(4*W_ADDR downto 0) := (others => '0');
	signal mem_slot_available: integer := 10;
	signal turn: integer := 0;
	signal pipe_level : integer range 0 to N_LEVELS := 0;
	
	
	-- Reusable array types (one element per ffnode)
	type sl_arr             is array (natural range <>) of std_logic;
	type int_arr            is array (natural range <>) of integer;

	type slv_fflevel_arr    is array (natural range <>) of std_logic_vector(FF_LEVEL_SIZE-1 downto 0);
	type slv_ffinp_arr      is array (natural range <>) of std_logic_vector(N_FF_NODES-1 downto 0);
	type slv_prec_arr       is array (natural range <>) of std_logic_vector(PRECISIONS-1 downto 0);
	type slv_ffprec_arr     is array (natural range <>) of std_logic_vector(FF_LEVEL_SIZE*PRECISIONS-1 downto 0);
	--type slv_inpsz_arr      is array (natural range <>) of std_logic_vector(INPUT_SIZE-1 downto 0);
	type slv32_arr          is array (natural range <>) of std_logic_vector(31 downto 0);
	
	type slv_seg_arr  is array (natural range <>, natural range <>) of std_logic_vector(INPUT_SIZE-1 downto 0);
    type slv_segP_arr is array (natural range <>, natural range <>) of std_logic_vector(INPUT_SIZE*PRECISIONS-1 downto 0);
    
    signal sorted_level : slv_seg_arr (0 to N_SHARDS, 0 to N_LEVELS) := (others => (0 to N_LEVELS => (INPUT_SIZE-1 downto 0 => '0')));
    --signal numout_level : slv_segP_arr(0 to N_SHARDS, 0 to N_LEVELS) := (others => (0 to N_LEVELS => (INPUT_SIZE*PRECISIONS-1 downto 0 => '0')));
    signal numout_level : slv_segP_arr(0 to N_LEVELS, 0 to logNceil(LEVEL_SIZE,N)+1) := (others => (others => (INPUT_SIZE*PRECISIONS-1 downto 0 => '0')));
    --signal nodeids_level : slv_segP_arr(0 to N_SHARDS, 0 to N_LEVELS) := (others => (0 to N_LEVELS => (INPUT_SIZE*PRECISIONS-1 downto 0 => '0')));
       

    -- Sort-key bit layout within each PRECISIONS-bit entry:
    --   bits 0..2*LOGN   : metadata (not loaded from raw_numbers)
    --   bits 2*LOGN+1..PRECISIONS-1 : 41 raw key bits
    -- KEY_OFFSET = 7 (for LOGN=3), KEY_GROUPS = 14 distinct LOGN-bit groups.
    -- KBASE(l) gives the first bit of the key group used at pipeline level l.
    -- Defined here so it is available in both pipeline_regs and ff_cd_node_ids.
    constant KEY_OFFSET : integer := 2*LOGN + 1;
    constant KEY_GROUPS : integer := (PRECISIONS - KEY_OFFSET) / LOGN;
    type kbase_t is array (0 to N_LEVELS-1) of integer;
    function make_kbases return kbase_t is
        variable t : kbase_t;
    begin
        for l in 0 to N_LEVELS-1 loop
            t(l) := KEY_OFFSET + (l mod KEY_GROUPS) * LOGN;
        end loop;
        return t;
    end function;
    constant KBASE : kbase_t := make_kbases;

	-- Handy per-node initial constants (avoid repeating expressions)
	constant PREC_ONE      : std_logic_vector(PRECISIONS-1 downto 0)
	  := '1' & (PRECISIONS-2 downto 0 => '0');
	constant PREC_ZERO     : std_logic_vector(PRECISIONS-1 downto 0)
	  := (others => '0');
	constant PREC_NXTMASK0 : std_logic_vector(PRECISIONS-1 downto 0)
	  := '1' & (PRECISIONS-1 downto 1 => '0');
	constant FF_ZERO       : std_logic_vector(FF_LEVEL_SIZE-1 downto 0)
	  := (others => '0');
	constant FFPREC_ZERO   : std_logic_vector(FF_LEVEL_SIZE*PRECISIONS-1 downto 0)
	  := (others => '0');
	constant NFF_ZERO       : std_logic_vector(N_FF_NODES-1 downto 0) := (others => '0');
	constant NFFPREC_ZERO       : std_logic_vector(N_FF_NODES*PRECISIONS-1 downto 0) := (others => '0');
	--constant INPSZ_ZERO    : std_logic_vector(INPUT_SIZE-1 downto 0)
	--  := (others => '0');
	constant U32_ZERO      : std_logic_vector(N32-1 downto 0)
	  := (others => '0');

	-- =======================
	-- FF PORTS (arrayed)
	-- =======================

	signal ffreset       : std_logic_vector(N_FF_NODES-1 downto 0) := (others => '0');  -- one bit per node

	--signal ffd_p         : slv_fflevel_arr (N_FF_NODES-1 downto 0) := (others => FF_ZERO);
	--signal ffnumbers_p   : slv_ffprec_arr  (N_FF_NODES-1 downto 0) := (others => FFPREC_ZERO);

	signal path          : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);
	signal path_mask     : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);
	signal bkey          : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	signal bmask         : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);
	signal nxt_mask      : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_NXTMASK0);

	signal ffstart       : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	signal ffstop        : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	signal active_level  : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);

	--signal ffdout_p      : slv_fflevel_arr (N_FF_NODES-1 downto 0);
	--signal ffnumout_p    : slv_ffprec_arr  (N_FF_NODES-1 downto 0);
	--signal ffcount       : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);        

	-- =======================
	-- FF SIGNALS (arrayed)
	-- =======================

	--signal ffd           : slv_fflevel_arr (N_FF_NODES-1 downto 0) := (others => FF_ZERO);
	--signal ffnumbers     : slv_ffprec_arr  (N_FF_NODES-1 downto 0) := (others => FFPREC_ZERO);
	--signal ffd_cnt       : slv_inpsz_arr   (N_FF_NODES-1 downto 0) := (others => INPSZ_ZERO);

	signal ffdout        : slv_fflevel_arr (N_FF_NODES-1 downto 0) := (others => FF_ZERO);
	signal ffnumout      : slv_ffprec_arr  (N_FF_NODES-1 downto 0) := (others => FFPREC_ZERO);
--	signal ffdout        : slv_ffinp_arr (FF_LEVEL_SIZE-1 downto 0) := (others => (N_FF_NODES-1 downto 0 => '0'));
--	signal ffnumout      : slv_ffinp_arr  (FF_LEVEL_SIZE*PRECISIONS-1 downto 0) := (others => (N_FF_NODES-1 downto 0 => '0'));
--	attribute keep : boolean;
--    attribute keep of ffdout : signal is true;
--    attribute keep of ffnumout : signal is true;


	signal nums_left 		: slv_ffprec_arr  (N_FF_NODES-1 downto 0) := (others => FFPREC_ZERO);
	signal match_0       : slv_fflevel_arr (N_FF_NODES-1 downto 0) := (others => FF_ZERO);
	signal match_i_1     : slv_fflevel_arr (N_FF_NODES-1 downto 0) := (others => FF_ZERO);
	signal match_i_2     : slv_fflevel_arr (N_FF_NODES-1 downto 0) := (others => FF_ZERO);
	
	signal key_bits0     : slv_fflevel_arr (PRECISIONS-1 downto 0) := (others => FF_ZERO);
	signal key_bits1     : slv_fflevel_arr (PRECISIONS-1 downto 0) := (others => FF_ZERO);
	signal key_bits2     : slv_fflevel_arr (PRECISIONS-1 downto 0) := (others => FF_ZERO);
	signal key_bits3     : slv_fflevel_arr (PRECISIONS-1 downto 0) := (others => FF_ZERO);

	--signal ready         : int_arr         (N_FF_NODES-1 downto 0) := (others => 0);
	signal ffready       : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	--signal fficount      : int_arr         (N_FF_NODES-1 downto 0) := (others => 0);
	signal ready_max 		: integer := 15;

	signal key_v0        : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	signal key_v1        : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	signal key_v2        : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);
	signal key_v3        : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);

	--signal key0          : int_arr         (N_FF_NODES-1 downto 0) := (others => 0);
	--signal key1          : int_arr         (N_FF_NODES-1 downto 0) := (others => 0);
	--signal key2          : int_arr         (N_FF_NODES-1 downto 0) := (others => 0);
	--signal key3          : int_arr         (N_FF_NODES-1 downto 0) := (others => 0);
	
	signal nxt_i         : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);
	signal skey          : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);

	-- If you still need single-bit “one/zero” vectors per node:
	--signal one_arr       : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ONE);
	--signal zero_arr      : slv_prec_arr    (N_FF_NODES-1 downto 0) := (others => PREC_ZERO);

	
	
	--impure function get_base(n : integer) return integer is
	  --  variable base : integer := 0;
	--begin
	  --  --for i in 0 to n loop
	  --  --    base := base + counts(0, i);
	  --  --end loop;
	  --  if n=0 then
	  --      return counts(0,0);
	  --  elsif n=1 then
	  --      return counts(0,0) + counts(0,1);
	  --  elsif n=2 then
	  --      return counts(0,0) + counts(0,1) + counts(0,2);
	  --  elsif n=3 then
	  --      return counts(0,0) + counts(0,1) + counts(0,2) + counts(0,3);
	  --  elsif n=4 then
	  --      return counts(0,0) + counts(0,1) + counts(0,2) + counts(0,3) + counts(0,4);
	  --  elsif n=5 then
	  --      return counts(0,0) + counts(0,1) + counts(0,2) + counts(0,3) + counts(0,4) + counts(0,5);
	  --  elsif n=6 then
	  --      return counts(0,0)+counts(0,1)+counts(0,2)+counts(0,3)+counts(0,4)+counts(0,5)+counts(0,6);
	  --  elsif n=7 then
	  --      return counts(0,0)+counts(0,1)+counts(0,2)+counts(0,3)+counts(0,4)+counts(0,5)+counts(0,6)+counts(0,7);
	  --  else 
	  --      return 0;
	  --  end if;
	--end function;
	
	impure function get(items: std_logic_vector; pos : integer) return std_logic_vector is
	begin
	    return items((pos+1)*PRECISIONS-1 downto pos*PRECISIONS);
	end function;
	
	impure function get_nid(l: integer; i: integer) return integer is
	begin
	    return max(0, min(LEVEL_SIZE-1, to_integer(unsigned(numout_level(l, logNceil(LEVEL_SIZE, N))(i*PRECISIONS+2*LOGN-1 downto i*PRECISIONS+LOGN)))));
	end function;
	
	

	for all:sub_counter use entity counter(Behavioral); 
	
	begin
		
		
    -- ff_cd_node_ids: transition-detection approach.
    -- Nodes are contiguous after fs_scatter, so we only need to detect where
    -- the node ID changes between adjacent entries.  Cost: LEVEL_SIZE
    -- comparators per level instead of LEVEL_SIZE^2.
    ff_cd_node_ids: process(numout_level)
        variable nid_raw, prev_nid_raw : std_logic_vector(LOGN-1 downto 0);
        variable nid_i, prev_nid_i     : integer range 0 to LEVEL_SIZE-1;
        variable nid_bits              : integer range 0 to LOGN;
        variable cur_start             : integer range 0 to LEVEL_SIZE;
    begin
        -- Default: all nodes empty (start=LEVEL_SIZE, end=0)
        for l in 0 to N_LEVELS-2 loop
            for nid in 0 to LEVEL_SIZE-1 loop
                sorted_start_level(l, nid) <= LEVEL_SIZE;
                sorted_end_level(l, nid)   <= 0;
            end loop;
        end loop;

        for l in 0 to N_LEVELS-2 loop
            if l = 0 then
                -- Level 0: single node spanning entire array
                sorted_start_level(0, 0) <= 0;
                sorted_end_level(0, 0)   <= LEVEL_SIZE;
            else
                if l < LOGN then nid_bits := l;
                else nid_bits := LOGN;
                end if;

                -- Get node ID of first entry
                prev_nid_raw := numout_level(l, 1)(LOGN-1 downto 0);
                for b in 0 to LOGN-1 loop
                    if b >= nid_bits then prev_nid_raw(b) := '0'; end if;
                end loop;
                prev_nid_i := to_integer(unsigned(prev_nid_raw));
                cur_start := 0;

                -- Scan entries 1..LEVEL_SIZE-1: detect transitions
                for i in 1 to LEVEL_SIZE-1 loop
                    nid_raw := numout_level(l, 1)(i*PRECISIONS+LOGN-1 downto i*PRECISIONS);
                    for b in 0 to LOGN-1 loop
                        if b >= nid_bits then nid_raw(b) := '0'; end if;
                    end loop;
                    nid_i := to_integer(unsigned(nid_raw));

                    if nid_i /= prev_nid_i then
                        -- Close previous node, open new one
                        sorted_start_level(l, prev_nid_i) <= cur_start;
                        sorted_end_level(l, prev_nid_i)   <= i;
                        cur_start := i;
                        prev_nid_i := nid_i;
                    end if;
                end loop;

                -- Close last node
                sorted_start_level(l, prev_nid_i) <= cur_start;
                sorted_end_level(l, prev_nid_i)   <= LEVEL_SIZE;
            end if;
        end loop;
    end process;
    
    
    -- ff_cd_count: direct per-node zero/one counting.
    -- After fs_scatter, entries from the same node are NOT contiguous (split
    -- between zero and one pools), so we cannot use boundary-based scanning.
    -- Instead, scan all entries, extract each entry's node ID and sort bit,
    -- and accumulate per-node counts directly.
    -- ff_cd_shards: one-sided split finder (original, boundary-based).
    -- Used by histogram (hist_update reads node_zeros/node_ones).
    ff_cd_shards:
    for l in 0 to N_LEVELS-2 generate
        shards_pos: for pos in 0 to LEVEL_SIZE-1 generate
            process(numout_level, sorted_start_level, sorted_end_level)
                constant KEY_BIT : integer := KEY_OFFSET + (l mod (PRECISIONS - KEY_OFFSET));
                variable n_z : integer range 0 to LEVEL_SIZE;
                variable v_start : integer range 0 to LEVEL_SIZE;
                variable v_end   : integer range 0 to LEVEL_SIZE;
                variable found : boolean;
            begin
                v_start := sorted_start_level(l, pos);
                v_end   := sorted_end_level(l, pos);
                n_z := 0;
                found := false;
                if v_end > v_start then
                    for i in 0 to LEVEL_SIZE-1 loop
                        if not found and i >= v_start and i < v_end then
                            if numout_level(l, 1)(i*PRECISIONS + KEY_BIT) = '1' then
                                found := true;
                                n_z := i - v_start;
                            end if;
                        end if;
                    end loop;
                    if not found then
                        n_z := v_end - v_start;
                    end if;
                end if;
                node_zeros(l, pos)  <= n_z;
                node_ones(l, pos)   <= v_end - v_start - n_z;
                split_level(l, pos) <= v_start + n_z;
            end process;
        end generate shards_pos;
    end generate ff_cd_shards;
    
    -- Histogram URAM: single-port read/write
    hist_sram: process(clk)
    begin
        if rising_edge(clk) then
            if hist_wr_en = '1' then
                hist_mem(hist_wr_addr) <= hist_wr_data;
            end if;
            hist_rd_data <= hist_mem(hist_rd_addr);
        end if;
    end process;

    -- Combinational: extract bin_id and trailing bits from each sorted pipeline entry
    scatter_extract: process(numout_level)
        variable key : std_logic_vector(KEY_WIDTH-1 downto 0);
    begin
        for i in 0 to LEVEL_SIZE-1 loop
            key := numout_level(N_LEVELS-1, 1)(
                i*PRECISIONS + KEY_OFFSET + KEY_WIDTH - 1
                downto
                i*PRECISIONS + KEY_OFFSET);
            scatter_bin_ids(i) <= to_integer(unsigned(
                key(KEY_WIDTH-1 downto KEY_WIDTH-BIN_ID_BITS)));
            scatter_entries(i) <= key(BIN_ENTRY_WIDTH-1 downto 0);
            if unsigned(key) /= 0 then
                scatter_valid(i) <= '1';
            else
                scatter_valid(i) <= '0';
            end if;
        end loop;
    end process;

    -- Throttle: assert when SRAM occupancy is high
    throttle_active <= '1' when sram_total_entries > SRAM_THROTTLE_ENTRIES else '0';

    -- HBM output mux: Phase 1 drain vs Phase 2 write-back
    hbm_wr_en   <= p2_hbm_wr_en   when phase = PHASE2_SORT else p1_hbm_wr_en;
    hbm_dout    <= p2_hbm_dout    when phase = PHASE2_SORT else p1_hbm_dout;
    hbm_wr_addr <= p2_hbm_wr_addr when phase = PHASE2_SORT else p1_hbm_wr_addr;
    sort_complete <= p2_finished;

    -- hist_bin_update: state machine that iterates over nodes, updates histogram
    -- counters via read-modify-write in local SRAM, and writes bin entries for
    -- last-level nodes.
    --
    -- For each pos (0..LEVEL_SIZE-2):
    --   Inner loop: l from log2ceil(pos+1) to min(N_LEVELS-NODE_LEVELS+1+pos, N_LEVELS-2)
    --     At first l where node_zeros(l,pos)>0 AND node_ones(l,pos)>0:
    --       histogram path = first l key bits of entry at pos
    --       histogram addr = 2^l - 1 + path_value
    --       accumulate node_ones(l,pos) with counter width W_ADDR-floor(lh/2)
    --       break
    --   If log2ceil(pos+1) >= NODE_LEVELS-1: write to channel bin
    -- hist_update: state machine that iterates over nodes, updates histogram
    -- counters via read-modify-write in URAM. Bin writes are now handled by
    -- scatter_write (Phase 1), so this FSM only does histogram accumulation.
    hist_update: process(clk)
        type state_t is (IDLE, SCAN_L, HIST_READ, HIST_WRITE, NEXT_POS);
        variable state      : state_t := IDLE;
        variable curr_pos   : integer range 0 to LEVEL_SIZE-1 := 0;
        variable curr_l     : integer range 0 to N_LEVELS-1 := 0;
        variable l_end      : integer range 0 to N_LEVELS-1 := 0;
        variable v_hist_addr : integer range 0 to HIST_DEPTH-1 := 0;
        variable v_hist_lh  : integer range 0 to LC := 0;
        variable path_val   : integer := 0;
        variable ctr_width  : integer range 1 to W_ADDR := W_ADDR;
        variable ones_val   : integer := 0;
        variable new_val    : unsigned(W_ADDR-1 downto 0) := (others => '0');
        variable mask       : unsigned(W_ADDR-1 downto 0) := (others => '1');
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state := IDLE;
                hist_wr_en <= '0';
            else
                hist_wr_en <= '0';

                case state is
                    when IDLE =>
                        curr_pos := 0;
                        curr_l := 0;
                        l_end := min(min(N_LEVELS - NODE_LEVELS + 1, N_LEVELS - 2), LC);
                        state := SCAN_L;

                    when SCAN_L =>
                        if curr_l <= l_end then
                            if node_zeros(curr_l, curr_pos) > 0 and
                               node_ones(curr_l, curr_pos) > 0 then
                                v_hist_lh := curr_l;
                                if curr_l = 0 then
                                    path_val := 0;
                                else
                                    path_val := to_integer(unsigned(
                                        numout_level(curr_l, 1)(
                                            curr_pos*PRECISIONS + KEY_OFFSET + curr_l - 1
                                            downto
                                            curr_pos*PRECISIONS + KEY_OFFSET)));
                                end if;
                                if v_hist_lh <= LC then
                                    v_hist_addr := 2**v_hist_lh - 1 + path_val;
                                    ones_val := node_ones(curr_l, curr_pos);
                                    hist_rd_addr <= v_hist_addr;
                                    state := HIST_READ;
                                else
                                    state := NEXT_POS;
                                end if;
                            else
                                curr_l := curr_l + 1;
                            end if;
                        else
                            state := NEXT_POS;
                        end if;

                    when HIST_READ =>
                        state := HIST_WRITE;

                    when HIST_WRITE =>
                        ctr_width := W_ADDR - v_hist_lh / 2;
                        mask := (others => '0');
                        for b in 0 to W_ADDR-1 loop
                            if b < ctr_width then
                                mask(b) := '1';
                            end if;
                        end loop;
                        new_val := (unsigned(hist_rd_data) + to_unsigned(ones_val, W_ADDR)) and mask;
                        hist_wr_addr <= v_hist_addr;
                        hist_wr_data <= std_logic_vector(new_val);
                        hist_wr_en <= '1';
                        state := NEXT_POS;

                    when NEXT_POS =>
                        if curr_pos >= LEVEL_SIZE - 2 then
                            state := IDLE;
                        else
                            curr_pos := curr_pos + 1;
                            curr_l := log2ceil(curr_pos + 1);
                            l_end := min(min(N_LEVELS - NODE_LEVELS + 1 + curr_pos, N_LEVELS - 2), LC);
                            state := SCAN_L;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- ff_dp_partition: arithmetic destination computation.
    -- After fs_scatter, zeros are at [0..total_zeros-1], ones at [total_zeros..LEVEL_SIZE-1].
    -- Relative order preserved → node's zeros/ones are contiguous sub-ranges.
    -- zeros_before(l,nid) = cumulative zeros from nodes 0..nid-1.
    -- Source for output j in node nid:
    --   zero-slot: src = zeros_before(nid) + (j - node_start)
    --   one-slot:  src = total_zeros + ones_before(nid) + (j - split)

    -- Prefix-sum of zeros/ones across nodes (combinational)
    -- Used by histogram only; ff_dp_partition computes its own counts inline.
    ff_dp_prefix: process(node_zeros, node_ones)
        variable z_acc, o_acc : integer range 0 to LEVEL_SIZE;
    begin
        for l in 0 to N_LEVELS-2 loop
            z_acc := 0;
            o_acc := 0;
            for nid in 0 to LEVEL_SIZE-1 loop
                zeros_before(l, nid) <= z_acc;
                ones_before(l, nid)  <= o_acc;
                z_acc := z_acc + node_zeros(l, nid);
                o_acc := o_acc + node_ones(l, nid);
            end loop;
        end loop;
    end process;

    -- ff_dp_partition: pass-through register stage.
    -- LSD radix sort: each level sorts by one key bit from LSB to MSB.
    -- No per-node regrouping needed — just register the scatter output
    -- to the next level's input.
    ff_dp_partition:
    for l in 0 to N_LEVELS-2 generate
        part_j: for j in 0 to LEVEL_SIZE-1 generate
            process(clk)
            begin
                if rising_edge(clk) then
                    numout_level(l+1, 0)((j+1)*PRECISIONS-1 downto j*PRECISIONS)
                        <= numout_level(l, 1)((j+1)*PRECISIONS-1 downto j*PRECISIONS);
                end if;
            end process;
        end generate part_j;
    end generate ff_dp_partition;

    numout_p <= numout_level(N_LEVELS-1, 1);  -- final barrel-sorted output of last stage

    -- ram_update disabled: variable-indexed writes to 65536-entry ram cause synthesis explosion
    -- ram_update: process(clk) ... end process ram_update;

    -- Combinational N_LEVELS-stage radix sort pipeline.
    -- Uses local variables to chain stages (signal reads within a process see
    -- the pre-process value, so variables are required for cascaded levels).
    -- Fixed-index writes only: after loop unrolling, every numout_level(l,vc)
    -- assignment has a static address, avoiding mux-explosion.
    --
    -- fs_count: combinational, one process per l.
    -- Computes fs_total_ones(l) = number of 1-entries in numout_level(l,0)
    -- at KEY_BIT(l). Shared across all j-instances of fs_scatter to avoid
    -- duplicating the count loop LEVEL_SIZE times per level.
    fs_count:
    for l in 0 to N_LEVELS-1 generate
        process(numout_level)
            constant KEY_BIT : integer := KEY_OFFSET + (l mod (PRECISIONS - KEY_OFFSET));
            variable cnt : integer range 0 to LEVEL_SIZE;
        begin
            cnt := 0;
            for i in 0 to LEVEL_SIZE-1 loop
                if numout_level(l, 0)(i*PRECISIONS + KEY_BIT) = '1' then
                    cnt := cnt + 1;
                end if;
            end loop;
            fs_total_ones(l) <= cnt;
        end process;
    end generate fs_count;

    -- fs_scatter: single-pass radix sort stage.
    -- Only one scan needed: zeros count is the inverse of ones count.
    -- Pass 1 finds the j-th zero-entry; Pass 2 (overwrite) finds the
    -- (j-total_zeros)-th one-entry.  Only one pass produces a valid result
    -- for any given j, so the other's assignment is harmless.

    -- Stage-0 input: mux between raw pipeline input (Phase 1) and readback buffer (Phase 2)
    pipeline_input <= p2_batch_buf when phase = PHASE2_SORT else numbers_p;
    numout_level(0, 0) <= pipeline_input;

    fs_scatter:
    for l in 0 to N_LEVELS-1 generate
        fs_j: for j in 0 to LEVEL_SIZE-1 generate
            process(clk)
                constant KEY_BIT : integer := KEY_OFFSET + (l mod (PRECISIONS - KEY_OFFSET));
                variable cnt     : integer range 0 to LEVEL_SIZE;
                variable entry_i : std_logic_vector(PRECISIONS-1 downto 0);
            begin
                if rising_edge(clk) then
                    entry_i := (others => '0');
                    -- Pass 1: find the j-th 0-entry
                    cnt := 0;
                    for i in 0 to LEVEL_SIZE-1 loop
                        if numout_level(l, 0)(i*PRECISIONS + KEY_BIT) = '0' then
                            if cnt = j then
                                entry_i := numout_level(l, 0)
                                    ((i+1)*PRECISIONS-1 downto i*PRECISIONS);
                            end if;
                            cnt := cnt + 1;
                        end if;
                    end loop;
                    -- Pass 2: find the (j - total_zeros)-th 1-entry
                    cnt := 0;
                    for i in 0 to LEVEL_SIZE-1 loop
                        if numout_level(l, 0)(i*PRECISIONS + KEY_BIT) = '1' then
                            if cnt = j - (LEVEL_SIZE - fs_total_ones(l)) then
                                entry_i := numout_level(l, 0)
                                    ((i+1)*PRECISIONS-1 downto i*PRECISIONS);
                            end if;
                            cnt := cnt + 1;
                        end if;
                    end loop;
                    numout_level(l, 1)((j+1)*PRECISIONS-1 downto j*PRECISIONS) <= entry_i;
                end if;
            end process;
        end generate fs_j;
    end generate fs_scatter;


    -- Old FIFO interface now unused (histogram is local SRAM, bins drain via HBM/DRAM/SSD)
    fifo_wr_en <= '0';
    fifo_re_en <= '0';
    fifo_dw    <= (others => '0');

    -- DRAM/SSD interfaces inactive for now (only HBM bins implemented)
    dram_wr_en <= '0';
    dram_dout  <= (others => '0');
    ssd_wr_en  <= '0';
    ssd_dout   <= (others => '0');

    -- bin_controller: unified process handling both scatter writes (from pipeline)
    -- and HBM drain (to off-chip memory). Single driver for all bin state.
    --
    -- Scatter: 1 entry written per cc (serialized from LEVEL_SIZE pipeline outputs)
    -- Drain: stride-N_HBM_CHAN round-robin, 1 entry read per cc, full-payload gated
    bin_controller: process(clk)
        variable wr_bid : integer range 0 to N_BINS-1;
        variable wr_addr : integer range 0 to BIN_SRAM_DEPTH-1;
        variable drain_bin : integer range 0 to N_BINS-1;
        variable has_payload : boolean;
        variable did_write : boolean;
        variable did_read : boolean;
    begin
        if rising_edge(clk) then
            p1_hbm_wr_en <= '0';
            if reset = '1' then
                scatter_wr_idx <= 0;
                scatter_pending <= '0';
                drain_base <= 0;
                drain_sub <= 0;
                sram_total_entries <= 0;
                phase <= PHASE1_SCATTER;
                for b in 0 to N_BINS-1 loop
                    bin_wr_ptr(b) <= 0;
                    bin_rd_ptr(b) <= 0;
                    bin_count(b) <= 0;
                    hbm_bin_wr_count(b) <= 0;
                end loop;
            else
                did_write := false;
                did_read := false;

                -- === PHASE TRANSITIONS ===
                if phase = PHASE1_SCATTER and phase1_complete = '1' then
                    phase <= PHASE1_FLUSH;
                end if;
                if phase = PHASE1_FLUSH and sram_total_entries = 0 then
                    phase <= PHASE2_SORT;
                end if;
                if phase = PHASE2_SORT and p2_finished = '1' then
                    phase <= PHASE_DONE;
                end if;

                -- === SCATTER WRITE (Phase 1) ===
                if phase = PHASE1_SCATTER and
                   scatter_valid(scatter_wr_idx) = '1' then
                    wr_bid := scatter_bin_ids(scatter_wr_idx);
                    if bin_count(wr_bid) < BIN_BUF_DEPTH then
                        wr_addr := wr_bid * BIN_BUF_DEPTH + bin_wr_ptr(wr_bid);
                        bin_sram(wr_addr) <= scatter_entries(scatter_wr_idx);
                        if bin_wr_ptr(wr_bid) = BIN_BUF_DEPTH - 1 then
                            bin_wr_ptr(wr_bid) <= 0;
                        else
                            bin_wr_ptr(wr_bid) <= bin_wr_ptr(wr_bid) + 1;
                        end if;
                        bin_count(wr_bid) <= bin_count(wr_bid) + 1;
                        did_write := true;
                    end if;
                end if;

                -- Advance scatter write index
                if phase = PHASE1_SCATTER then
                    if scatter_wr_idx = LEVEL_SIZE - 1 then
                        scatter_wr_idx <= 0;
                    else
                        scatter_wr_idx <= scatter_wr_idx + 1;
                    end if;
                end if;

                -- === HBM DRAIN (Phase 1 scatter + flush) ===
                if phase = PHASE1_SCATTER or phase = PHASE1_FLUSH then
                    drain_bin := (drain_base + drain_sub) mod N_BINS;

                    has_payload := (bin_count(drain_bin) >= HBM_ENTRIES_PER_PAYLOAD);
                    if phase = PHASE1_FLUSH then
                        has_payload := (bin_count(drain_bin) > 0);
                    end if;

                    if hbm_ready = '1' and has_payload then
                        p1_hbm_dout <= bin_sram(drain_bin * BIN_BUF_DEPTH + bin_rd_ptr(drain_bin));
                        p1_hbm_wr_en <= '1';
                        p1_hbm_wr_addr <= std_logic_vector(to_unsigned(
                            drain_bin * MAX_BIN_ENTRIES + hbm_bin_wr_count(drain_bin), 32));
                        hbm_bin_wr_count(drain_bin) <= hbm_bin_wr_count(drain_bin) + 1;
                        if bin_rd_ptr(drain_bin) = BIN_BUF_DEPTH - 1 then
                            bin_rd_ptr(drain_bin) <= 0;
                        else
                            bin_rd_ptr(drain_bin) <= bin_rd_ptr(drain_bin) + 1;
                        end if;
                        if did_write and wr_bid = drain_bin then
                            bin_count(drain_bin) <= bin_count(drain_bin);
                        else
                            bin_count(drain_bin) <= bin_count(drain_bin) - 1;
                        end if;
                        did_read := true;
                    end if;

                    -- Advance drain stride
                    if drain_sub = N_HBM_CHAN - 1 then
                        drain_sub <= 0;
                        if drain_base + N_HBM_CHAN >= N_BINS then
                            drain_base <= 0;
                        else
                            drain_base <= drain_base + N_HBM_CHAN;
                        end if;
                    else
                        drain_sub <= drain_sub + 1;
                    end if;
                end if;

                -- Update total SRAM occupancy
                if did_write and not did_read then
                    sram_total_entries <= sram_total_entries + 1;
                elsif did_read and not did_write then
                    sram_total_entries <= sram_total_entries - 1;
                end if;
            end if;
        end if;
    end process;

    -- Phase 2 controller: read bins from HBM, sort through pipeline, write back
    phase2_ctrl: process(clk)
        variable v_entry : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    begin
        if rising_edge(clk) then
            p2_hbm_wr_en <= '0';
            hbm_rd_req <= '0';
            if reset = '1' then
                p2_state <= P2_IDLE;
                p2_finished <= '0';
                p2_curr_bin <= 0;
                p2_read_idx <= 0;
                p2_batch_fill <= 0;
                p2_batch_buf <= (others => '0');
                p2_sort_count <= 0;
                p2_write_idx <= 0;
                p2_batch_valid <= 0;
                p2_bin_write_count <= 0;
            else
                case p2_state is
                    when P2_IDLE =>
                        if phase = PHASE2_SORT then
                            p2_curr_bin <= 0;
                            p2_read_idx <= 0;
                            p2_batch_fill <= 0;
                            p2_bin_write_count <= 0;
                            p2_batch_buf <= (others => '0');
                            if hbm_bin_wr_count(0) > 0 then
                                p2_state <= P2_REQ_READ;
                            else
                                p2_state <= P2_NEXT_BIN;
                            end if;
                        end if;

                    when P2_REQ_READ =>
                        -- Request one entry from HBM
                        hbm_rd_req <= '1';
                        hbm_rd_addr <= std_logic_vector(to_unsigned(
                            p2_curr_bin * MAX_BIN_ENTRIES + p2_read_idx, 32));
                        p2_state <= P2_WAIT_READ;

                    when P2_WAIT_READ =>
                        -- Wait for valid read data from HBM
                        if hbm_rd_valid = '1' then
                            -- Pack into batch buffer: zero-pad metadata, place key bits
                            p2_batch_buf(
                                p2_batch_fill*PRECISIONS + KEY_OFFSET + BIN_ENTRY_WIDTH - 1
                                downto
                                p2_batch_fill*PRECISIONS + KEY_OFFSET
                            ) <= hbm_rd_data;
                            -- Zero the metadata bits (already zero from init, but be explicit)
                            p2_batch_buf(
                                p2_batch_fill*PRECISIONS + KEY_OFFSET - 1
                                downto
                                p2_batch_fill*PRECISIONS
                            ) <= (others => '0');

                            p2_read_idx <= p2_read_idx + 1;

                            if p2_batch_fill = LEVEL_SIZE - 1 or
                               p2_read_idx = hbm_bin_wr_count(p2_curr_bin) - 1 then
                                -- Batch full or no more entries in this bin
                                p2_batch_valid <= p2_batch_fill + 1;
                                p2_sort_count <= 0;
                                p2_state <= P2_SORT_WAIT;
                            else
                                p2_batch_fill <= p2_batch_fill + 1;
                                p2_state <= P2_REQ_READ;
                            end if;
                        end if;

                    when P2_SORT_WAIT =>
                        -- Wait for pipeline to process the batch
                        if p2_sort_count >= PIPELINE_LATENCY + 2 then
                            p2_write_idx <= 0;
                            p2_state <= P2_WRITE_OUT;
                        else
                            p2_sort_count <= p2_sort_count + 1;
                        end if;

                    when P2_WRITE_OUT =>
                        -- Write sorted entries to HBM (skip zero-padded slots)
                        -- Valid entries sort last (zeros sort first), so write from
                        -- position (LEVEL_SIZE - p2_batch_valid) onwards
                        if p2_write_idx < p2_batch_valid then
                            v_entry := numout_level(N_LEVELS-1, 1)(
                                (LEVEL_SIZE - p2_batch_valid + p2_write_idx)*PRECISIONS + KEY_OFFSET + BIN_ENTRY_WIDTH - 1
                                downto
                                (LEVEL_SIZE - p2_batch_valid + p2_write_idx)*PRECISIONS + KEY_OFFSET);
                            p2_hbm_wr_en <= '1';
                            p2_hbm_dout <= v_entry;
                            -- Write to sorted output area (offset past scatter area)
                            p2_hbm_wr_addr <= std_logic_vector(to_unsigned(
                                N_BINS * MAX_BIN_ENTRIES +
                                p2_curr_bin * MAX_BIN_ENTRIES +
                                p2_bin_write_count, 32));
                            p2_bin_write_count <= p2_bin_write_count + 1;
                            p2_write_idx <= p2_write_idx + 1;
                        else
                            p2_state <= P2_NEXT_BATCH;
                        end if;

                    when P2_NEXT_BATCH =>
                        p2_batch_fill <= 0;
                        p2_batch_buf <= (others => '0');
                        if p2_read_idx >= hbm_bin_wr_count(p2_curr_bin) then
                            p2_state <= P2_NEXT_BIN;
                        else
                            p2_state <= P2_REQ_READ;
                        end if;

                    when P2_NEXT_BIN =>
                        if p2_curr_bin = N_BINS - 1 then
                            p2_state <= P2_DONE;
                        else
                            p2_curr_bin <= p2_curr_bin + 1;
                            p2_read_idx <= 0;
                            p2_batch_fill <= 0;
                            p2_bin_write_count <= 0;
                            p2_batch_buf <= (others => '0');
                            if hbm_bin_wr_count(p2_curr_bin + 1) > 0 then
                                p2_state <= P2_REQ_READ;
                            else
                                p2_state <= P2_NEXT_BIN;
                            end if;
                        end if;

                    when P2_DONE =>
                        p2_finished <= '1';

                end case;
            end if;
        end if;
    end process;

    -- Drive count from pipeline output + shard counters so neither block is
    -- optimized away (count feeds child_counts in fractal.vhd).
    count <= to_integer(unsigned(numout_level(N_LEVELS-1, 1)(LOGN-1 downto 0)))
           + node_zeros(0, 0);

    -- Diagnostic: print key pipeline signals every 20 cycles
    -- End-to-end sort check: print full key value (bits 7..48) of each entry
    -- at L0 input and L41 output. Repeated every 50 cycles to see multiple batches.
    diagnostic: process(clk)
        variable l_out   : line;
        variable sim_cyc : integer := 0;
        variable prev_val : integer;
        variable cur_val  : integer;
        variable sorted   : boolean;
    begin
        if rising_edge(clk) then
            sim_cyc := sim_cyc + 1;
            if sim_cyc mod 50 = 0 then
                -- L0 input: what went in (top 31 key bits: 48 downto 18, fits in integer)
                write(l_out, string'("[cyc=" & integer'image(sim_cyc) & "] INPUT :"));
                for i in 0 to LEVEL_SIZE-1 loop
                    write(l_out, string'( integer'image(to_integer(unsigned(
                        numout_level(0,0)(i*PRECISIONS+48 downto i*PRECISIONS+18)))) & " "));
                end loop;
                writeline(output, l_out);
                -- L41 output: what came out
                write(l_out, string'("[cyc=" & integer'image(sim_cyc) & "] OUTPUT:"));
                for i in 0 to LEVEL_SIZE-1 loop
                    write(l_out, string'( integer'image(to_integer(unsigned(
                        numout_level(N_LEVELS-1,1)(i*PRECISIONS+48 downto i*PRECISIONS+18)))) & " "));
                end loop;
                writeline(output, l_out);
                -- Check if output is non-decreasing (using same 31-bit window)
                sorted := true;
                prev_val := 0;
                for i in 0 to LEVEL_SIZE-1 loop
                    cur_val := to_integer(unsigned(
                        numout_level(N_LEVELS-1,1)(i*PRECISIONS+48 downto i*PRECISIONS+18)));
                    if cur_val < prev_val then sorted := false; end if;
                    prev_val := cur_val;
                end loop;
                if sorted then
                    write(l_out, string'("[cyc=" & integer'image(sim_cyc) & "] SORTED: YES"));
                else
                    write(l_out, string'("[cyc=" & integer'image(sim_cyc) & "] SORTED: NO"));
                end if;
                writeline(output, l_out);
            end if;
        end if;
    end process;

end Behavioral;
