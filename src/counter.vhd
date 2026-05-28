
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
	function log2floor(n : natural) return natural;
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
    CONSTANT INPUT_SIZE : INTEGER := N; --N*N for HW; N for quick sim
    CONSTANT N_INPUT_CYCLES : INTEGER := 500;
    CONSTANT N_DATASET : INTEGER := N_INPUT_CYCLES * INPUT_SIZE;  -- actual element count
    CONSTANT DATASET_SIZE: INTEGER := 2**28;  -- HBM address space reservation
    CONSTANT W_ADDR : INTEGER := 16;
    CONSTANT RAM_LEN: INTEGER := (2**20) / W_ADDR; --(2**28) / W_ADDR;
    CONSTANT N_BKTS: INTEGER := 2;  -- slot 0: write zeros+ones count; slot 1: read-back for accumulation

    -- Histogram constants
    CONSTANT LC : INTEGER := 20;  -- max histogram level
    CONSTANT NODE_LEVELS : INTEGER := log2ceil(INPUT_SIZE);  -- log2ceil(INPUT_SIZE)
    CONSTANT KEY_WIDTH : INTEGER := 42;  -- PRECISIONS - (2*LOGN+1) = 49-7
    CONSTANT HIST_DEPTH : INTEGER := 2097152;  -- 2^(LC+1)
    -- Enable histogram components only for small precisions (p<32)
    CONSTANT ENABLE_HIST : boolean := PRECISIONS < 32;

    -- Phase 1 scatter-bin constants
    -- N_BINS bounds: N_DATASET/2^22 <= N_BINS <= min(N_DATASET/64, 2^26)
    -- Use power-of-2 at upper bound: 2^floor(log2(min(N_DATASET/64, 2^26)))
    CONSTANT N_BINS : INTEGER := 2**log2floor(min(N_DATASET/64, 2**26));
    CONSTANT BIN_ID_BITS : INTEGER := log2floor(min(N_DATASET/64, 2**26));
    CONSTANT BIN_ENTRY_WIDTH : INTEGER := RAW_PRECISION - BIN_ID_BITS;  -- full entry minus bin ID bits
    -- SRAM bin depth per bin (on-chip write buffer before HBM drain)
    CONSTANT BIN_BUF_DEPTH : INTEGER := 64;  -- entries per bin buffer
    CONSTANT BIN_BUF_ADDR_BITS : INTEGER := log2ceil(BIN_BUF_DEPTH);

    -- Storage tier selection: 0=HBM, 1=DRAM, 2=SSD
    -- Set FORCE_TIER >= 0 to override auto-select (for simulation testing).
    CONSTANT FORCE_TIER : INTEGER := -1;  -- -1=auto, 0=HBM, 1=DRAM, 2=SSD
    -- Capacity thresholds in bytes (avoid overflow by staying in MB)
    -- HBM: 16 GB = 16384 MB, DRAM: 64 GB = 65536 MB, entry = 16 bytes
    -- N_DATASET * 16 bytes converted to MB = N_DATASET / 65536
    -- Auto-select: dataset_MB <= tier_MB → use that tier
    CONSTANT DATASET_MB : INTEGER := N_DATASET / 65536;  -- 0 for small sim datasets
    CONSTANT ACTIVE_TIER : INTEGER :=
        FORCE_TIER when FORCE_TIER >= 0 else
        0 when DATASET_MB <= 16384 else   -- fits in HBM (16 GB)
        1 when DATASET_MB <= 65536 else   -- fits in DRAM (64 GB)
        2;                                 -- SSD

    -- Physical memory channel counts (stride for drain)
    CONSTANT N_HBM_CHAN : INTEGER := 8;   -- HBM pseudo-channels drained per cc
    CONSTANT N_DRAM_CHAN : INTEGER := 4;  -- DRAM channels
    CONSTANT N_SSD_CHAN : INTEGER := 2;   -- SSD channels

    -- HBM payload: 256 bits per pseudo-channel
    CONSTANT HBM_PAYLOAD_BITS : INTEGER := 256;
    CONSTANT HBM_ENTRIES_PER_PAYLOAD : INTEGER := HBM_PAYLOAD_BITS / BIN_ENTRY_WIDTH;

    -- Max entries per bin in HBM (address space reservation)
    -- 4x headroom for non-uniform distribution during testing
    CONSTANT MAX_BIN_ENTRIES : INTEGER := 4 * N_DATASET / N_BINS;

    -- Top/Bottom bin split: avoid round-tripping full entries in Phase 2.
    -- Each bin has a "top" (narrow sort keys) and "bottom" (trailing bits).
    --   ln = log2ceil(n) where n = N_DATASET (total entries)
    --   lnb = log2ceil(N_BINS) = BIN_ID_BITS (bits consumed by bin selection)
    --   Lead bits = key bits [lnb .. ln+2] (2 guard bits to reduce collisions)
    --   lb = log2ceil(MAX_BIN_ENTRIES) = pointer width into bottom
    --   Top entry = lead_bits & lb-bit pointer
    --   Bottom entry = trailing bits [0 .. lnb-1]
    CONSTANT LN : INTEGER := log2ceil(N_DATASET);
    CONSTANT LNB : INTEGER := BIN_ID_BITS;
    CONSTANT LEAD_BITS_WIDTH : INTEGER := (LN + 2) - LNB + 1;  -- bits [lnb..ln+2]
    CONSTANT LB : INTEGER := log2ceil(MAX_BIN_ENTRIES);  -- pointer width
    CONSTANT TOP_ENTRY_WIDTH : INTEGER := LEAD_BITS_WIDTH + LB;
    CONSTANT BOTTOM_ENTRY_WIDTH : INTEGER := LNB;  -- trailing bits [0..lnb-1]
    -- Top/bottom packing into HBM payloads
    CONSTANT HBM_TOP_PER_PAYLOAD : INTEGER := HBM_PAYLOAD_BITS / TOP_ENTRY_WIDTH;
    CONSTANT HBM_BOT_PER_PAYLOAD : INTEGER := HBM_PAYLOAD_BITS / BOTTOM_ENTRY_WIDTH;

    -- Pipeline latency per level: FS_DEPTH registered tree stages + 1 ff_dp_partition,
    -- minus 1 since last level has no ff_dp_partition after it.
    -- FS_DEPTH = logNceil(INPUT_SIZE, N). For INPUT_SIZE=64, N=8: FS_DEPTH=2, latency=3*128-1=383.
    CONSTANT PIPELINE_LATENCY : INTEGER :=
        (logNceil(INPUT_SIZE, N) + 1) * RAW_PRECISION - 1;

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
	
	function log2floor(n : natural) return natural is
		variable temp : natural := n;
		variable result : natural := 0;
	begin
		if n <= 1 then return 0; end if;
		while temp > 1 loop
			temp := temp / 2;
			result := result + 1;
		end loop;
		return result;
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
        constant CHUNK_BITS : integer := 30;
        constant N_FULL_CHUNKS : integer := RAW_PRECISION / CHUNK_BITS;
        constant REMAINDER_BITS : integer := RAW_PRECISION - N_FULL_CHUNKS * CHUNK_BITS;
        variable base : integer;
    begin
        for i in 0 to n-1 loop
            base := i * RAW_PRECISION;
            case dist is
                when UNIFORM_DIST =>
                    -- Generate full-range random value in 30-bit chunks
                    for j in 0 to N_FULL_CHUNKS-1 loop
                        uniform(s1, s2, u1);
                        result(base + (j+1)*CHUNK_BITS - 1 downto base + j*CHUNK_BITS) :=
                            std_logic_vector(to_unsigned(
                                integer(floor(u1 * 1073741824.0)), CHUNK_BITS));
                    end loop;
                    if REMAINDER_BITS > 0 then
                        uniform(s1, s2, u1);
                        result(base + RAW_PRECISION - 1 downto base + N_FULL_CHUNKS*CHUNK_BITS) :=
                            std_logic_vector(to_unsigned(
                                integer(floor(u1 * real(2**REMAINDER_BITS))), REMAINDER_BITS));
                    end if;

                when NORMAL_DIST =>
                    uniform(s1, s2, u1);
                    uniform(s1, s2, u2);
                    temp := sqrt(-2.0 * log(u1)) * cos(MATH_2_PI * u2);
                    result((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION) :=
                        std_logic_vector(to_unsigned(integer(round((temp * std) + mean)), RAW_PRECISION));

                when EXPONENTIAL_DIST =>
                    uniform(s1, s2, u1);
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
	           N_LEVELS: integer := RAW_PRECISION; -- sort all RAW_PRECISION bits
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
			  numbers_p : in std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0);
			  starts_p : in std_logic_vector(LEVEL_SIZE*log2ceil(LEVEL_SIZE)-1 downto 0);
			  start : in integer;                                              -- Inclusive index
			  stop : in integer;                                               -- Non-inclusive index
			  sorted_p : out std_logic_vector(LEVEL_SIZE-1 downto 0); -- := (LEVEL_SIZE-1 downto 0 => '0');
			  --indices : out std_logic_vector(LEVEL_SIZE*(SIZE_PRECISION+PRECISION)-1 downto 0);
			  numout_p : out std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0) := (LEVEL_SIZE*RAW_PRECISION-1 downto 0 => '0');
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
	          hbm_dout  : out std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
	          hbm_ready : in std_logic;
	          -- DRAM controller interface
	          dram_wr_en : out std_logic;
	          dram_dout  : out std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
	          dram_ready : in std_logic;
	          -- SSD controller interface
	          ssd_wr_en : out std_logic;
	          ssd_dout  : out std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
	          ssd_ready : in std_logic;
	          -- Phase control
	          phase1_complete : in std_logic;
	          sort_complete : out std_logic;
	          -- HBM write address (for both Phase 1 drain and Phase 2 write-back)
	          hbm_wr_addr : out std_logic_vector(31 downto 0);
	          -- HBM read interface (Phase 2 readback)
	          hbm_rd_req  : out std_logic;
	          hbm_rd_addr : out std_logic_vector(31 downto 0);
	          hbm_rd_data : in std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
	          hbm_rd_valid : in std_logic;
	          -- DRAM read/write address + read interface
	          dram_wr_addr : out std_logic_vector(31 downto 0);
	          dram_rd_req  : out std_logic;
	          dram_rd_addr : out std_logic_vector(31 downto 0);
	          dram_rd_data : in std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
	          dram_rd_valid : in std_logic;
	          -- SSD read/write address + read interface
	          ssd_wr_addr : out std_logic_vector(31 downto 0);
	          ssd_rd_req  : out std_logic;
	          ssd_rd_addr : out std_logic_vector(31 downto 0);
	          ssd_rd_data : in std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
	          ssd_rd_valid : in std_logic);
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
 
    signal sorted_start_level : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    signal sorted_end_level   : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    signal node_zeros  : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal node_ones   : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal split_level : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal fs_total_ones : count_1d_t(0 to N_LEVELS-1) := (others => 0);
    -- Per-leaf-node zero counts exposed from fs_scatter (for histogram)
    signal fs_leaf_zeros : count_2d_t(0 to N_LEVELS-1, 0 to LEVEL_SIZE/N - 1) := (others => (others => 0));

    -- Histogram memory (URAM-inferred)
    type hist_mem_t is array (0 to HIST_DEPTH-1) of std_logic_vector(W_ADDR-1 downto 0);
    signal hist_mem : hist_mem_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of hist_mem : signal is "ultra";
    signal hist_rd_addr : integer range 0 to HIST_DEPTH-1 := 0;
    signal hist_rd_data : std_logic_vector(W_ADDR-1 downto 0) := (others => '0');
    signal hist_wr_addr : integer range 0 to HIST_DEPTH-1 := 0;
    signal hist_wr_data : std_logic_vector(W_ADDR-1 downto 0) := (others => '0');
    signal hist_wr_en   : std_logic := '0';

    -- Phase 1 SRAM bin buffers with top/bottom split.
    -- TOP: lead bits [lnb..ln+2] & lb-bit pointer → narrow, sorted in Phase 2
    -- BOTTOM: trailing bits [0..lnb-1] → looked up by pointer after Phase 2 sort
    constant BIN_SRAM_DEPTH : integer := N_BINS * BIN_BUF_DEPTH;

    -- Top SRAM: stores TOP_ENTRY_WIDTH-bit records (lead bits + bottom pointer)
    type bin_top_entry_t is array (0 to BIN_BUF_DEPTH-1) of std_logic_vector(TOP_ENTRY_WIDTH-1 downto 0);
    type bin_top_sram_t is array (0 to N_BINS-1) of bin_top_entry_t;
    signal bin_top_sram : bin_top_sram_t := (others => (others => (others => '0')));
    attribute ram_style of bin_top_sram : signal is "ultra";

    -- Bottom SRAM: stores BOTTOM_ENTRY_WIDTH-bit trailing bits, indexed by pointer
    type bin_bot_entry_t is array (0 to BIN_BUF_DEPTH-1) of std_logic_vector(BOTTOM_ENTRY_WIDTH-1 downto 0);
    type bin_bot_sram_t is array (0 to N_BINS-1) of bin_bot_entry_t;
    signal bin_bot_sram : bin_bot_sram_t := (others => (others => (others => '0')));
    attribute ram_style of bin_bot_sram : signal is "ultra";

    -- Per-bin write/read pointers (independently driven by scatter and drain)
    type bin_ptr_t is array (0 to N_BINS-1) of integer range 0 to BIN_BUF_DEPTH-1;
    signal bin_wr_ptr : bin_ptr_t := (others => 0);  -- driven by scatter_write
    signal bin_rd_ptr : bin_ptr_t := (others => 0);  -- driven by drain_controller

    -- Per-bin cumulative write/read totals for deriving fill count
    type bin_total_t is array (0 to N_BINS-1) of integer range 0 to 2**20-1;
    signal bin_wr_total : bin_total_t := (others => 0);  -- driven by scatter_write
    signal bin_rd_total : bin_total_t := (others => 0);  -- driven by drain_controller

    -- Derived fill counts (combinational: wr_total - rd_total)
    type bin_cnt_t is array (0 to N_BINS-1) of integer range 0 to BIN_BUF_DEPTH;
    signal bin_count : bin_cnt_t;

    -- Scatter stall: assert when any bin is too full to accept a worst-case batch
    signal scatter_stall : std_logic := '0';

    -- Per-entry scatter: extract bin_id, lead bits, and trailing bits
    type scatter_bin_id_t is array (0 to LEVEL_SIZE-1) of integer range 0 to N_BINS-1;
    type scatter_top_t is array (0 to LEVEL_SIZE-1) of std_logic_vector(TOP_ENTRY_WIDTH-1 downto 0);
    type scatter_bot_t is array (0 to LEVEL_SIZE-1) of std_logic_vector(BOTTOM_ENTRY_WIDTH-1 downto 0);
    signal scatter_bin_ids : scatter_bin_id_t := (others => 0);
    signal scatter_tops    : scatter_top_t := (others => (others => '0'));
    signal scatter_bots    : scatter_bot_t := (others => (others => '0'));
    signal scatter_valid   : std_logic_vector(LEVEL_SIZE-1 downto 0) := (others => '0');

    -- Per-bin scatter write count: how many entries target each bin this cycle
    type bin_scatter_cnt_t is array (0 to N_BINS-1) of integer range 0 to LEVEL_SIZE;
    -- (computed combinationally in scatter_write process)

    -- HBM drain: round-robin scan, packs full HBM payload per drain cycle
    signal drain_bin : integer range 0 to N_BINS-1 := 0;
    signal drain_active : std_logic := '0';  -- drain is sending a payload
    signal drain_sub_idx : integer range 0 to HBM_ENTRIES_PER_PAYLOAD-1 := 0;  -- entry within payload

    -- Phase control
    type phase_t is (PHASE1_SCATTER, PHASE1_FLUSH, PHASE2_SORT, PHASE_DONE);
    signal phase : phase_t := PHASE1_SCATTER;

    -- Phase 1 HBM write: per-bin entry counts for Phase 2 readback
    type bin_hbm_cnt_t is array (0 to N_BINS-1) of integer range 0 to MAX_BIN_ENTRIES;
    signal hbm_bin_wr_count : bin_hbm_cnt_t := (others => 0);

    -- Phase 1/2 memory output mux intermediates (tier-agnostic)
    signal p1_mem_wr_en   : std_logic := '0';
    signal p1_mem_dout    : std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0) := (others => '0');
    signal p1_mem_wr_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal p2_mem_wr_en   : std_logic := '0';
    signal p2_mem_dout    : std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0) := (others => '0');
    signal p2_mem_wr_addr : std_logic_vector(31 downto 0) := (others => '0');
    -- Tier-agnostic read interface (internal)
    signal mem_rd_req   : std_logic := '0';
    signal mem_rd_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_rd_data  : std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0) := (others => '0');
    signal mem_rd_valid : std_logic := '0';
    signal mem_ready    : std_logic := '0';

    -- Phase 2 streaming pipeline: read and write sides run concurrently,
    -- with a shift register tracking batches through the sort pipeline.

    -- Read side: 1 read/cc by issuing next request on response arrival
    type p2_rd_state_t is (P2_RD_IDLE, P2_RD_REQ, P2_RD_WAIT, P2_RD_DONE);
    signal p2_rd_state : p2_rd_state_t := P2_RD_IDLE;
    signal p2_rd_bin : integer range 0 to N_BINS := 0;
    signal p2_rd_idx : integer := 0;  -- next request index
    signal p2_resp_idx : integer := 0;  -- index of the outstanding request (for response)
    signal p2_rd_batch_fill : integer range 0 to LEVEL_SIZE := 0;
    signal p2_batch_buf : std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0) := (others => '0');

    -- Feed: completed batch latched for 1 cc pipeline input
    signal p2_feed_buf : std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0) := (others => '0');
    signal p2_feed_valid : std_logic := '0';

    -- Pipeline validity shift register: tracks batches through the sort pipeline
    constant P2_SR_LEN : integer := PIPELINE_LATENCY + 2;
    signal p2_valid_sr : std_logic_vector(0 to P2_SR_LEN) := (others => '0');
    type p2_bv_sr_t is array(0 to P2_SR_LEN) of integer range 0 to LEVEL_SIZE;
    signal p2_bv_sr : p2_bv_sr_t := (others => 0);
    type p2_bin_sr_t is array(0 to P2_SR_LEN) of integer range 0 to N_BINS-1;
    signal p2_bin_sr : p2_bin_sr_t := (others => 0);

    -- Write side: packs sorted output into HBM payloads
    signal p2_sorted_latch : std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0) := (others => '0');
    signal p2_wr_active : std_logic := '0';
    signal p2_wr_idx : integer range 0 to LEVEL_SIZE := 0;
    signal p2_wr_batch_valid : integer range 0 to LEVEL_SIZE := 0;
    signal p2_wr_bin : integer range 0 to N_BINS-1 := 0;
    type p2_bin_wr_cnt_t is array (0 to N_BINS-1) of integer range 0 to MAX_BIN_ENTRIES;
    signal p2_bin_wr_count : p2_bin_wr_cnt_t := (others => 0);
    signal p2_finished : std_logic := '0';

    -- Pipeline input mux
    signal pipeline_input : std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0);
    



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
    type slv_segP_arr is array (natural range <>, natural range <>) of std_logic_vector(INPUT_SIZE*RAW_PRECISION-1 downto 0);
    
    signal sorted_level : slv_seg_arr (0 to N_SHARDS, 0 to N_LEVELS) := (others => (0 to N_LEVELS => (INPUT_SIZE-1 downto 0 => '0')));
    --signal numout_level : slv_segP_arr(0 to N_SHARDS, 0 to N_LEVELS) := (others => (0 to N_LEVELS => (INPUT_SIZE*PRECISIONS-1 downto 0 => '0')));
    signal numout_level : slv_segP_arr(0 to N_LEVELS, 0 to logNceil(LEVEL_SIZE,N)+1) := (others => (others => (INPUT_SIZE*RAW_PRECISION-1 downto 0 => '0')));
    --signal nodeids_level : slv_segP_arr(0 to N_SHARDS, 0 to N_LEVELS) := (others => (0 to N_LEVELS => (INPUT_SIZE*PRECISIONS-1 downto 0 => '0')));

       

    -- Sort-key bit layout within each PRECISIONS-bit entry:
    --   bits 0..2*LOGN   : metadata (not loaded from raw_numbers)
    --   bits 2*LOGN+1..PRECISIONS-1 : 41 raw key bits
    -- KEY_OFFSET = 7 (for LOGN=3), KEY_GROUPS = 14 distinct LOGN-bit groups.
    -- KBASE(l) gives the first bit of the key group used at pipeline level l.
    -- Defined here so it is available in both pipeline_regs and ff_cd_node_ids.
    constant KEY_OFFSET : integer := 2*LOGN + 1;
    constant KEY_GROUPS : integer := (PRECISIONS - KEY_OFFSET) / LOGN;
    -- Fractal swap tree depth: number of tree levels in fs_scatter
    constant FS_DEPTH : integer := logNceil(LEVEL_SIZE, N);
    -- Index width: bits needed to address LEVEL_SIZE entries
    constant IDX_WIDTH : integer := log2ceil(LEVEL_SIZE);  -- 6 for LEVEL_SIZE=64

    -- Index-based pipeline: route log2(LEVEL_SIZE)-bit indices instead of PRECISIONS-bit entries
    type slv_idx_arr is array (natural range <>, natural range <>) of
        std_logic_vector(LEVEL_SIZE*IDX_WIDTH-1 downto 0);
    signal idx_level : slv_idx_arr(0 to N_LEVELS, 0 to logNceil(LEVEL_SIZE,N));

    -- Pipeline timing constants
    constant STAGES_PER_LEVEL : integer := FS_DEPTH + 1;
    constant TOTAL_PIPELINE_STAGES : integer := STAGES_PER_LEVEL * N_LEVELS;

    ---------------------------------------------------------------------------
    -- SRL Key Bit Delays: replace data_delay for key bit extraction.
    -- For each key bit position b (0..RAW_PRECISION-1), we need the bit
    -- delayed by (l*STAGES_PER_LEVEL + d) cycles, where l is the pipeline
    -- level and d is the tree depth within that level.
    -- SRL approach: one SRL chain per bit position, LEVEL_SIZE bits wide.
    -- key_srl(stage)(bit)(entry) gives key bit 'bit' of entry 'entry'
    -- at pipeline delay 'stage'.
    -- We only need taps at stage = l*STAGES_PER_LEVEL + d for each (l,d).
    -- But SRL shift registers with different tap points share the same chain.
    ---------------------------------------------------------------------------
    -- key_bit_input: extracted key bits from pipeline_input, indexed [bit][entry]
    type key_bit_matrix_t is array (0 to RAW_PRECISION-1) of
        std_logic_vector(LEVEL_SIZE-1 downto 0);
    signal key_bit_input : key_bit_matrix_t;

    -- key_srl(b)(m) = bit b of all LEVEL_SIZE entries, delayed m clock cycles.
    -- key_srl(b)(0) = key_bit_input(b) (combinational, 0 delay).
    -- key_srl(b)(m) for m>=1 = registered, m cycles of delay.
    -- Bit b is only used at level l=b (since KEY_BIT = l mod RAW_PRECISION and
    -- N_LEVELS = RAW_PRECISION). Max tap depth for bit b = b*STAGES_PER_LEVEL + FS_DEPTH.
    -- We allocate per-bit variable-depth chains to save ~57K LUTs.
    -- Vivado infers SRL32 primitives for the registered portion.
    -- Note: srl_chain_t sized to max depth (bit 127). Bits with shorter chains
    -- leave upper indices undriven (optimized away by synthesis).
    constant MAX_SRL_DEPTH : integer := (RAW_PRECISION-1)*STAGES_PER_LEVEL + FS_DEPTH;
    type srl_chain_t is array (0 to MAX_SRL_DEPTH) of
        std_logic_vector(LEVEL_SIZE-1 downto 0);
    type srl_all_bits_t is array (0 to RAW_PRECISION-1) of srl_chain_t;
    signal key_srl : srl_all_bits_t;
    attribute shreg_extract : string;
    attribute shreg_extract of key_srl : signal is "yes";

    ---------------------------------------------------------------------------
    -- BRAM Entry FIFO: stores full entries for reconstruction at last stage.
    -- Depth = TOTAL_PIPELINE_STAGES, Width = LEVEL_SIZE * RAW_PRECISION = 8192 bits.
    -- Write: pipeline_input each cycle at wr_ptr.
    -- Read: at (wr_ptr - PIPELINE_LATENCY) for reconstruct_final.
    -- Uses BRAM inference via ram_style attribute.
    ---------------------------------------------------------------------------
    constant ENTRY_FIFO_DEPTH : integer := TOTAL_PIPELINE_STAGES;
    constant ENTRY_FIFO_WIDTH : integer := LEVEL_SIZE * RAW_PRECISION;
    type entry_fifo_mem_t is array (0 to ENTRY_FIFO_DEPTH-1) of
        std_logic_vector(ENTRY_FIFO_WIDTH-1 downto 0);
    signal entry_fifo : entry_fifo_mem_t := (others => (others => '0'));
    attribute ram_style of entry_fifo : signal is "block";
    signal entry_fifo_wr_ptr : integer range 0 to ENTRY_FIFO_DEPTH-1 := 0;
    signal entry_fifo_rd_data : std_logic_vector(ENTRY_FIFO_WIDTH-1 downto 0) := (others => '0');
    -- Read offset = PIPELINE_LATENCY (registered read aligns with reconstruct_final).
    constant ENTRY_FIFO_RD_OFFSET : integer := PIPELINE_LATENCY;

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
		
		
    -- Combinational: extract bin_id, lead bits (top), and trailing bits (bottom)
    -- from each sorted pipeline entry.
    -- Top = lead_bits[lnb..ln+2] & lb-bit pointer (pointer filled in scatter_write)
    -- Bottom = trailing_bits[0..lnb-1]
    scatter_extract: process(numout_level)
        variable raw_entry : std_logic_vector(RAW_PRECISION-1 downto 0);
        variable lead_bits : std_logic_vector(LEAD_BITS_WIDTH-1 downto 0);
    begin
        for i in 0 to LEVEL_SIZE-1 loop
            raw_entry := numout_level(N_LEVELS-1, FS_DEPTH)(
                (i+1)*RAW_PRECISION - 1 downto i*RAW_PRECISION);
            -- Bin ID = top BIN_ID_BITS of the raw entry
            scatter_bin_ids(i) <= to_integer(unsigned(
                raw_entry(RAW_PRECISION-1 downto RAW_PRECISION-BIN_ID_BITS)));
            -- Lead bits = bits [lnb .. ln+2] (above bin ID, below full precision)
            lead_bits := raw_entry(LN+2 downto LNB);
            -- Top entry = lead_bits & pointer placeholder (filled in scatter_write)
            scatter_tops(i) <= lead_bits & std_logic_vector(to_unsigned(0, LB));
            -- Bottom entry = trailing bits [0..lnb-1]
            scatter_bots(i) <= raw_entry(LNB-1 downto 0);
            if unsigned(raw_entry) /= 0 then
                scatter_valid(i) <= '1';
            else
                scatter_valid(i) <= '0';
            end if;
        end loop;
    end process;

    -- Derive bin fill counts combinationally from independent write/read totals
    bin_fill: process(bin_wr_total, bin_rd_total)
    begin
        for b in 0 to N_BINS-1 loop
            bin_count(b) <= bin_wr_total(b) - bin_rd_total(b);
        end loop;
    end process;

    -- Scatter stall: assert when any bin is close to full (worst case: all entries go to 1 bin)
    stall_check: process(bin_count)
    begin
        scatter_stall <= '0';
        for b in 0 to N_BINS-1 loop
            if bin_count(b) >= BIN_BUF_DEPTH - LEVEL_SIZE then
                scatter_stall <= '1';
            end if;
        end loop;
    end process;

    -- Tier-agnostic memory output mux: Phase 1 drain vs Phase 2 write-back
    -- Internal signals are tier-agnostic; routed to correct port below.
    sort_complete <= p2_finished;

    -- Tier input mux: route read response from active tier
    mem_rd_data  <= hbm_rd_data  when ACTIVE_TIER = 0 else
                    dram_rd_data when ACTIVE_TIER = 1 else
                    ssd_rd_data;
    mem_rd_valid <= hbm_rd_valid when ACTIVE_TIER = 0 else
                    dram_rd_valid when ACTIVE_TIER = 1 else
                    ssd_rd_valid;
    mem_ready    <= hbm_ready    when ACTIVE_TIER = 0 else
                    dram_ready   when ACTIVE_TIER = 1 else
                    ssd_ready;

    -- Tier output routing: write and read requests to active tier
    tier_route: process(phase, p1_mem_wr_en, p1_mem_dout, p1_mem_wr_addr,
                        p2_mem_wr_en, p2_mem_dout, p2_mem_wr_addr, mem_rd_req, mem_rd_addr)
        variable wr_en   : std_logic;
        variable wr_dout : std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
        variable wr_addr : std_logic_vector(31 downto 0);
    begin
        -- Phase mux
        if phase = PHASE2_SORT then
            wr_en := p2_mem_wr_en; wr_dout := p2_mem_dout; wr_addr := p2_mem_wr_addr;
        else
            wr_en := p1_mem_wr_en; wr_dout := p1_mem_dout; wr_addr := p1_mem_wr_addr;
        end if;

        -- Default: all inactive
        hbm_wr_en <= '0'; hbm_dout <= (others => '0'); hbm_wr_addr <= (others => '0');
        hbm_rd_req <= '0'; hbm_rd_addr <= (others => '0');
        dram_wr_en <= '0'; dram_dout <= (others => '0'); dram_wr_addr <= (others => '0');
        dram_rd_req <= '0'; dram_rd_addr <= (others => '0');
        ssd_wr_en <= '0'; ssd_dout <= (others => '0'); ssd_wr_addr <= (others => '0');
        ssd_rd_req <= '0'; ssd_rd_addr <= (others => '0');

        -- Route to active tier
        if ACTIVE_TIER = 0 then
            hbm_wr_en <= wr_en; hbm_dout <= wr_dout; hbm_wr_addr <= wr_addr;
            hbm_rd_req <= mem_rd_req; hbm_rd_addr <= mem_rd_addr;
        elsif ACTIVE_TIER = 1 then
            dram_wr_en <= wr_en; dram_dout <= wr_dout; dram_wr_addr <= wr_addr;
            dram_rd_req <= mem_rd_req; dram_rd_addr <= mem_rd_addr;
        else
            ssd_wr_en <= wr_en; ssd_dout <= wr_dout; ssd_wr_addr <= wr_addr;
            ssd_rd_req <= mem_rd_req; ssd_rd_addr <= mem_rd_addr;
        end if;
    end process tier_route;

    -- ff_dp_partition: pass-through register stage for indices.
    -- Copies idx_level(l, FS_DEPTH) to idx_level(l+1, 0).
    -- SRL key bit chains and BRAM entry FIFO handle entry data separately.
    ff_dp_partition:
    for l in 0 to N_LEVELS-2 generate
        process(clk)
        begin
            if rising_edge(clk) then
                idx_level(l+1, 0) <= idx_level(l, FS_DEPTH);
            end if;
        end process;
    end generate ff_dp_partition;

    numout_p <= numout_level(N_LEVELS-1, FS_DEPTH);  -- final scatter output of last stage

    -- ram_update disabled: variable-indexed writes to 65536-entry ram cause synthesis explosion
    -- ram_update: process(clk) ... end process ram_update;

    -- Stage-0 input: mux between raw pipeline input (Phase 1) and feed buffer (Phase 2)
    -- In Phase 2, feed_buf is presented for 1 cc when a batch is ready; zeros otherwise.
    pipeline_input <= p2_feed_buf when (phase = PHASE2_SORT and p2_feed_valid = '1')
                      else (others => '0') when phase = PHASE2_SORT
                      else numbers_p;
    numout_level(0, 0) <= pipeline_input;

    -- Identity permutation for level 0 index input
    gen_idx_identity: for i in 0 to LEVEL_SIZE-1 generate
        idx_level(0, 0)((i+1)*IDX_WIDTH-1 downto i*IDX_WIDTH)
            <= std_logic_vector(to_unsigned(i, IDX_WIDTH));
    end generate gen_idx_identity;

    -- Extract key bits from pipeline_input: key_bit_input(b)(i) = bit b of entry i
    gen_key_extract: for b in 0 to RAW_PRECISION-1 generate
        gen_key_entry: for i in 0 to LEVEL_SIZE-1 generate
            key_bit_input(b)(i) <= pipeline_input(i*RAW_PRECISION + b);
        end generate gen_key_entry;
    end generate gen_key_extract;

    -- SRL key bit delay chains: per-bit variable-depth shift registers.
    -- Bit b needs max depth b*STAGES_PER_LEVEL + FS_DEPTH.
    -- key_srl(b)(0) = combinational (0 delay), key_srl(b)(m>=1) = m cycles delay.
    -- Vivado infers SRL32 primitives from this pattern.
    gen_srl_bits: for b in 0 to RAW_PRECISION-1 generate
        constant SRL_DEPTH_B : integer := b * STAGES_PER_LEVEL + FS_DEPTH;
    begin
        key_srl(b)(0) <= key_bit_input(b);  -- combinational tap (0 delay)
        process(clk)
        begin
            if rising_edge(clk) then
                for k in 1 to SRL_DEPTH_B loop
                    key_srl(b)(k) <= key_srl(b)(k-1);
                end loop;
            end if;
        end process;
    end generate gen_srl_bits;

    -- BRAM entry FIFO: write pipeline_input, read delayed for reconstruct_final.
    process(clk)
        variable rd_addr : integer range 0 to ENTRY_FIFO_DEPTH-1;
    begin
        if rising_edge(clk) then
            -- Write
            entry_fifo(entry_fifo_wr_ptr) <= pipeline_input;
            -- Read (1 cycle early to account for registered BRAM output)
            if entry_fifo_wr_ptr >= ENTRY_FIFO_RD_OFFSET then
                rd_addr := entry_fifo_wr_ptr - ENTRY_FIFO_RD_OFFSET;
            else
                rd_addr := entry_fifo_wr_ptr + ENTRY_FIFO_DEPTH - ENTRY_FIFO_RD_OFFSET;
            end if;
            entry_fifo_rd_data <= entry_fifo(rd_addr);
            -- Advance write pointer
            if entry_fifo_wr_ptr = ENTRY_FIFO_DEPTH-1 then
                entry_fifo_wr_ptr <= 0;
            else
                entry_fifo_wr_ptr <= entry_fifo_wr_ptr + 1;
            end if;
        end if;
    end process;

    -- Fractal Swap (FS): index-based hierarchical tree radix sort stage.
    --
    -- Routes IDX_WIDTH-bit indices instead of PRECISIONS-bit entries.
    -- Key bit lookups use SRL delay chains (key_srl) instead of data_delay.
    -- key_srl(b)(m)(i) = bit b of entry i, delayed m cycles from pipeline_input.
    -- Timing: key_srl(KEY_BIT)(l*STAGES_PER_LEVEL) aligns with idx_level(l, 0).
    -- numout_level(l, FS_DEPTH) is reconstructed from idx_level + entry_fifo_rd_data.
    --
    -- Tree depth = FS_DEPTH = logNceil(LEVEL_SIZE, N).
    -- For LEVEL_SIZE=8: FS_DEPTH=1 (leaf only). LEVEL_SIZE=64: FS_DEPTH=2.
    fs_scatter:
    for l in 0 to N_LEVELS-1 generate
        -- Tree level d=1 (leaf nodes): partition N index entries by key bit.
        fs_leaf: for nd in 0 to LEVEL_SIZE/N - 1 generate
            process(clk)
                constant KEY_BIT : integer := l mod RAW_PRECISION;
                constant BASE : integer := nd * N;
                variable kb : std_logic_vector(N-1 downto 0);
                variable pz : int_child_arr(0 to N);
                variable zc : integer range 0 to N;
                variable out_idx : std_logic_vector(N*IDX_WIDTH-1 downto 0);
                variable found : boolean;
                variable orig_idx : integer range 0 to LEVEL_SIZE-1;
            begin
                if rising_edge(clk) then
                    -- Extract key bits via SRL delay chain
                    for i in 0 to N-1 loop
                        orig_idx := to_integer(unsigned(
                            idx_level(l, 0)((BASE+i+1)*IDX_WIDTH-1 downto (BASE+i)*IDX_WIDTH)));
                        kb(i) := key_srl(KEY_BIT)(l*STAGES_PER_LEVEL)(orig_idx);
                    end loop;

                    -- Prefix zero count
                    pz(0) := 0;
                    for i in 0 to N-1 loop
                        if kb(i) = '0' then pz(i+1) := pz(i) + 1;
                        else pz(i+1) := pz(i);
                        end if;
                    end loop;
                    zc := pz(N);
                    fs_leaf_zeros(l, nd) <= zc;

                    -- Per-output reverse-map (route indices, not data)
                    out_idx := (others => '0');
                    for j in 0 to N-1 loop
                        found := false;
                        -- Zero region: source shifts left from position >= j
                        for i in 0 to N-1 loop
                            if not found and i >= j
                               and kb(i) = '0' and pz(i) = j then
                                out_idx((j+1)*IDX_WIDTH-1 downto j*IDX_WIDTH)
                                    := idx_level(l, 0)((BASE+i+1)*IDX_WIDTH-1
                                                       downto (BASE+i)*IDX_WIDTH);
                                found := true;
                            end if;
                        end loop;
                        -- One region: source shifts right from position <= j
                        for i in 0 to N-1 loop
                            if not found and i <= j
                               and kb(i) = '1' and (i - pz(i)) = (j - zc) then
                                out_idx((j+1)*IDX_WIDTH-1 downto j*IDX_WIDTH)
                                    := idx_level(l, 0)((BASE+i+1)*IDX_WIDTH-1
                                                       downto (BASE+i)*IDX_WIDTH);
                                found := true;
                            end if;
                        end loop;
                    end loop;

                    idx_level(l, 1)((BASE+N)*IDX_WIDTH-1 downto BASE*IDX_WIDTH)
                        <= out_idx;
                end if;
            end process;
        end generate fs_leaf;

        -- Tree levels d=2..FS_DEPTH (internal nodes): merge child partitions.
        -- Routes indices with key bit lookup from SRL delay chain.
        fs_internal: for d in 2 to FS_DEPTH generate
            constant CHILD_SZ : integer := N**(d-1);
            constant NODE_SZ  : integer := N**d;
            constant N_NODES  : integer := LEVEL_SIZE / NODE_SZ;
        begin
            fs_node: for nd in 0 to N_NODES-1 generate
                process(clk)
                    constant KEY_BIT    : integer := l mod RAW_PRECISION;
                    constant NODE_BASE  : integer := nd * NODE_SZ;
                    variable child_zc   : int_child_arr(0 to N-1);
                    variable pz_child   : int_child_arr(0 to N);
                    variable po_child   : int_child_arr(0 to N);
                    variable total_zeros : integer range 0 to NODE_SZ;
                    variable out_idx    : std_logic_vector(NODE_SZ*IDX_WIDTH-1 downto 0);
                    variable src_pos    : integer range 0 to LEVEL_SIZE-1;
                    variable jp         : integer range 0 to NODE_SZ-1;
                    variable found      : boolean;
                    variable orig_idx   : integer range 0 to LEVEL_SIZE-1;
                begin
                    if rising_edge(clk) then
                        -- Step 1: Count zeros per child via index lookup
                        for c in 0 to N-1 loop
                            child_zc(c) := 0;
                            for i in 0 to CHILD_SZ-1 loop
                                orig_idx := to_integer(unsigned(
                                    idx_level(l, d-1)((NODE_BASE + c*CHILD_SZ + i + 1)*IDX_WIDTH-1
                                                      downto (NODE_BASE + c*CHILD_SZ + i)*IDX_WIDTH)));
                                if key_srl(KEY_BIT)(l*STAGES_PER_LEVEL + d - 1)(orig_idx) = '0' then
                                    child_zc(c) := child_zc(c) + 1;
                                end if;
                            end loop;
                        end loop;

                        -- Step 2: Prefix sums of zero/one counts across children
                        pz_child(0) := 0;
                        po_child(0) := 0;
                        for c in 0 to N-1 loop
                            pz_child(c+1) := pz_child(c) + child_zc(c);
                            po_child(c+1) := po_child(c) + (CHILD_SZ - child_zc(c));
                        end loop;
                        total_zeros := pz_child(N);

                        -- Step 3: Per-output reverse-map with N:1 child selection (indices)
                        out_idx := (others => '0');
                        for j in 0 to NODE_SZ-1 loop
                            found := false;
                            if j < total_zeros then
                                for c in 0 to N-1 loop
                                    if not found
                                       and j >= pz_child(c)
                                       and j < pz_child(c+1) then
                                        src_pos := NODE_BASE + c*CHILD_SZ + (j - pz_child(c));
                                        out_idx((j+1)*IDX_WIDTH-1 downto j*IDX_WIDTH)
                                            := idx_level(l, d-1)(
                                                (src_pos+1)*IDX_WIDTH-1 downto src_pos*IDX_WIDTH);
                                        found := true;
                                    end if;
                                end loop;
                            else
                                jp := j - total_zeros;
                                for c in 0 to N-1 loop
                                    if not found
                                       and jp >= po_child(c)
                                       and jp < po_child(c+1) then
                                        src_pos := NODE_BASE + c*CHILD_SZ + child_zc(c) + (jp - po_child(c));
                                        out_idx((j+1)*IDX_WIDTH-1 downto j*IDX_WIDTH)
                                            := idx_level(l, d-1)(
                                                (src_pos+1)*IDX_WIDTH-1 downto src_pos*IDX_WIDTH);
                                        found := true;
                                    end if;
                                end loop;
                            end if;
                        end loop;

                        idx_level(l, d)((NODE_BASE+NODE_SZ)*IDX_WIDTH-1 downto NODE_BASE*IDX_WIDTH)
                            <= out_idx;
                    end if;
                end process;
            end generate fs_node;
        end generate fs_internal;

        -- fs_total_ones from the final tree level (via index lookup)
        process(clk)
            constant KEY_BIT : integer := l mod RAW_PRECISION;
            variable ones_count : integer range 0 to LEVEL_SIZE;
            variable orig_idx : integer range 0 to LEVEL_SIZE-1;
        begin
            if rising_edge(clk) then
                ones_count := 0;
                for i in 0 to LEVEL_SIZE-1 loop
                    orig_idx := to_integer(unsigned(
                        idx_level(l, FS_DEPTH)((i+1)*IDX_WIDTH-1 downto i*IDX_WIDTH)));
                    if key_srl(KEY_BIT)(l*STAGES_PER_LEVEL + FS_DEPTH)(orig_idx) = '1' then
                        ones_count := ones_count + 1;
                    end if;
                end loop;
                fs_total_ones(l) <= ones_count;
            end if;
        end process;
    end generate fs_scatter;

    -- Reconstruction: derive numout_level for FINAL level only (needed by scatter_extract).
    -- Combinational LEVEL_SIZE:1 mux of RAW_PRECISION bits per entry, using the composed
    -- permutation in idx_level and the BRAM entry FIFO (delayed full entries).
    -- entry_fifo_rd_data is registered (1cc BRAM latency), aligned with the final stage.
    reconstruct_final: process(idx_level, entry_fifo_rd_data)
        variable orig_idx : integer range 0 to LEVEL_SIZE-1;
        constant l : integer := N_LEVELS-1;
    begin
        for j in 0 to LEVEL_SIZE-1 loop
            orig_idx := to_integer(unsigned(
                idx_level(l, FS_DEPTH)((j+1)*IDX_WIDTH-1 downto j*IDX_WIDTH)));
            numout_level(l, FS_DEPTH)((j+1)*RAW_PRECISION-1 downto j*RAW_PRECISION)
                <= entry_fifo_rd_data((orig_idx+1)*RAW_PRECISION-1 downto orig_idx*RAW_PRECISION);
        end loop;
    end process;


    -- Histogram components: enabled only for small precisions (ENABLE_HIST = PRECISIONS < 32).
    -- Derives node_zeros/node_ones directly from fs_leaf_zeros and fs_total_ones,
    -- eliminating the need for ff_cd_node_ids and ff_cd_shards.
    -- When ENABLE_HIST is false, none of these processes are synthesized — zero resources.
    hist_gen: if ENABLE_HIST generate
        -- Drive node_zeros / node_ones from fs_scatter outputs.
        -- For FS_DEPTH=1: single leaf covers all N entries, so leaf nd=0 gives root count.
        -- For FS_DEPTH>=2: each leaf gives its N-entry partition count.
        hist_node_counts:
        for l in 0 to N_LEVELS-1 generate
            hist_leaf: for nd in 0 to LEVEL_SIZE/N - 1 generate
                process(clk)
                begin
                    if rising_edge(clk) then
                        node_zeros(l, nd) <= fs_leaf_zeros(l, nd);
                        node_ones(l, nd)  <= N - fs_leaf_zeros(l, nd);
                    end if;
                end process;
            end generate hist_leaf;
        end generate hist_node_counts;

        -- Histogram SRAM (URAM): simple dual-port read/write
        hist_sram: process(clk)
        begin
            if rising_edge(clk) then
                hist_rd_data <= hist_mem(hist_rd_addr);
                if hist_wr_en = '1' then
                    hist_mem(hist_wr_addr) <= hist_wr_data;
                end if;
            end if;
        end process;

        -- hist_update: FSM to accumulate node_zeros/node_ones into histogram memory.
        -- (placeholder — will be implemented when histogram readback is needed)
    end generate hist_gen;

    -- Old FIFO interface now unused (histogram is local SRAM, bins drain via HBM/DRAM/SSD)
    fifo_wr_en <= '0';
    fifo_re_en <= '0';
    fifo_dw    <= (others => '0');

    -- DRAM/SSD/HBM write routing is handled by tier_route process above.

    -- Phase controller: manages phase transitions independently
    phase_ctrl: process(clk)
        variable all_empty : boolean;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                phase <= PHASE1_SCATTER;
            else
                if phase = PHASE1_SCATTER and phase1_complete = '1' then
                    phase <= PHASE1_FLUSH;
                end if;
                if phase = PHASE1_FLUSH then
                    all_empty := true;
                    for b in 0 to N_BINS-1 loop
                        if bin_count(b) > 0 then
                            all_empty := false;
                        end if;
                    end loop;
                    if all_empty then
                        phase <= PHASE2_SORT;
                    end if;
                end if;
                if phase = PHASE2_SORT and p2_finished = '1' then
                    phase <= PHASE_DONE;
                end if;
            end if;
        end if;
    end process;

    -- scatter_write: Parallel write of all INPUT_SIZE entries to bins in 1 cc.
    -- Each bin has its own SRAM with independent write port.
    -- Stalls when scatter_stall is asserted (bin near full).
    scatter_write: process(clk)
        variable wr_cnt : bin_scatter_cnt_t;  -- per-bin write count this cycle
        variable wr_bid : integer range 0 to N_BINS-1;
        variable wr_slot : integer range 0 to BIN_BUF_DEPTH-1;
        variable bot_ptr : integer range 0 to MAX_BIN_ENTRIES-1;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                for b in 0 to N_BINS-1 loop
                    bin_wr_ptr(b) <= 0;
                    bin_wr_total(b) <= 0;
                end loop;
            elsif phase = PHASE1_SCATTER and scatter_stall = '0' then
                -- Count how many entries target each bin and write top+bottom
                wr_cnt := (others => 0);
                for i in 0 to LEVEL_SIZE-1 loop
                    if scatter_valid(i) = '1' then
                        wr_bid := scatter_bin_ids(i);
                        wr_slot := (bin_wr_ptr(wr_bid) + wr_cnt(wr_bid)) mod BIN_BUF_DEPTH;
                        -- Bottom pointer = current total writes for this bin + offset this cycle
                        bot_ptr := bin_wr_total(wr_bid) + wr_cnt(wr_bid);
                        -- Write top: lead bits & bottom pointer
                        bin_top_sram(wr_bid)(wr_slot) <=
                            scatter_tops(i)(TOP_ENTRY_WIDTH-1 downto LB) &
                            std_logic_vector(to_unsigned(bot_ptr, LB));
                        -- Write bottom: trailing bits
                        bin_bot_sram(wr_bid)(wr_slot) <= scatter_bots(i);
                        wr_cnt(wr_bid) := wr_cnt(wr_bid) + 1;
                    end if;
                end loop;
                -- Advance write pointers and totals for bins that received entries
                for b in 0 to N_BINS-1 loop
                    if wr_cnt(b) > 0 then
                        bin_wr_ptr(b) <= (bin_wr_ptr(b) + wr_cnt(b)) mod BIN_BUF_DEPTH;
                        bin_wr_total(b) <= bin_wr_total(b) + wr_cnt(b);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- drain_controller: Two-cycle HBM drain with top/bottom split.
    -- Cycle 1 (drain_active='0'): write top payload (lead bits + pointer)
    -- Cycle 2 (drain_active='1'): write bottom payload (trailing bits)
    -- HBM layout per bin: [top region: MAX_BIN_ENTRIES] [bottom region: MAX_BIN_ENTRIES]
    drain_controller: process(clk)
        variable has_payload : boolean;
        variable fill : integer range 0 to BIN_BUF_DEPTH;
        variable drain_count : integer range 0 to HBM_ENTRIES_PER_PAYLOAD;
        variable payload : std_logic_vector(HBM_PAYLOAD_BITS-1 downto 0);
    begin
        if rising_edge(clk) then
            p1_mem_wr_en <= '0';
            if reset = '1' then
                drain_bin <= 0;
                drain_active <= '0';
                drain_sub_idx <= 0;
                for b in 0 to N_BINS-1 loop
                    bin_rd_ptr(b) <= 0;
                    bin_rd_total(b) <= 0;
                    hbm_bin_wr_count(b) <= 0;
                end loop;
            elsif phase = PHASE1_SCATTER or phase = PHASE1_FLUSH then

                if drain_active = '1' then
                    -- Cycle 2: write bottom payload for the same drain_bin
                    if mem_ready = '1' then
                        payload := (others => '0');
                        for e in 0 to HBM_ENTRIES_PER_PAYLOAD-1 loop
                            if e < drain_sub_idx then
                                payload((e+1)*BOTTOM_ENTRY_WIDTH-1 downto e*BOTTOM_ENTRY_WIDTH)
                                    := bin_bot_sram(drain_bin)(
                                        (bin_rd_ptr(drain_bin) - drain_sub_idx + e) mod BIN_BUF_DEPTH);
                            end if;
                        end loop;
                        p1_mem_dout <= payload;
                        p1_mem_wr_en <= '1';
                        -- Bottom region starts at bin * 2 * MAX_BIN_ENTRIES + MAX_BIN_ENTRIES
                        p1_mem_wr_addr <= std_logic_vector(to_unsigned(
                            drain_bin * 2 * MAX_BIN_ENTRIES + MAX_BIN_ENTRIES +
                            hbm_bin_wr_count(drain_bin) - drain_sub_idx, 32));

                        drain_active <= '0';
                        -- Advance to next bin
                        if drain_bin = N_BINS - 1 then
                            drain_bin <= 0;
                        else
                            drain_bin <= drain_bin + 1;
                        end if;
                    end if;
                else
                    -- Cycle 1: check bin fill and write top payload
                    fill := bin_count(drain_bin);

                    if phase = PHASE1_FLUSH then
                        has_payload := (fill > 0);
                    else
                        has_payload := (fill >= HBM_ENTRIES_PER_PAYLOAD);
                    end if;

                    if mem_ready = '1' and has_payload then
                        if fill >= HBM_ENTRIES_PER_PAYLOAD then
                            drain_count := HBM_ENTRIES_PER_PAYLOAD;
                        else
                            drain_count := fill;
                        end if;

                        -- Pack and write top payload
                        payload := (others => '0');
                        for e in 0 to HBM_ENTRIES_PER_PAYLOAD-1 loop
                            if e < drain_count then
                                payload((e+1)*TOP_ENTRY_WIDTH-1 downto e*TOP_ENTRY_WIDTH)
                                    := bin_top_sram(drain_bin)(
                                        (bin_rd_ptr(drain_bin) + e) mod BIN_BUF_DEPTH);
                            end if;
                        end loop;
                        p1_mem_dout <= payload;
                        p1_mem_wr_en <= '1';
                        -- Top region at bin * 2 * MAX_BIN_ENTRIES
                        p1_mem_wr_addr <= std_logic_vector(to_unsigned(
                            drain_bin * 2 * MAX_BIN_ENTRIES + hbm_bin_wr_count(drain_bin), 32));

                        -- Advance pointers
                        bin_rd_ptr(drain_bin) <= (bin_rd_ptr(drain_bin) + drain_count) mod BIN_BUF_DEPTH;
                        bin_rd_total(drain_bin) <= bin_rd_total(drain_bin) + drain_count;
                        hbm_bin_wr_count(drain_bin) <= hbm_bin_wr_count(drain_bin) + drain_count;

                        -- Move to cycle 2 for bottom write
                        drain_active <= '1';
                        drain_sub_idx <= drain_count;
                    else
                        -- Nothing to drain, advance to next bin
                        if drain_bin = N_BINS - 1 then
                            drain_bin <= 0;
                        else
                            drain_bin <= drain_bin + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Phase 2 streaming controller: read side and write side run concurrently.
    -- A shift register tracks batches through the sort pipeline so the write side
    -- knows exactly when sorted output is valid at numout_level.
    -- Reads are continuous; no waiting for sort. Writes happen as sorted data emerges.
    phase2_stream: process(clk)
        variable v_consume : integer range 0 to HBM_ENTRIES_PER_PAYLOAD;
        variable v_batch_full : boolean;
        variable v_bin_done : boolean;
        variable v_bv : integer range 0 to LEVEL_SIZE;
        variable v_need_more_reads : boolean;
        variable v_wr_remain : integer range 0 to LEVEL_SIZE;
        variable v_wr_pack : integer range 0 to HBM_ENTRIES_PER_PAYLOAD;
        variable v_rd_all_done : boolean;
    begin
        if rising_edge(clk) then
            p2_mem_wr_en <= '0';
            p2_feed_valid <= '0';
            -- NOTE: mem_rd_req is NOT cleared here by default.
            -- It stays asserted until the arbiter picks it up and we get a response.

            if reset = '1' then
                mem_rd_req <= '0';
                p2_rd_state <= P2_RD_IDLE;
                p2_rd_bin <= 0;
                p2_rd_idx <= 0;
                p2_rd_batch_fill <= 0;
                p2_batch_buf <= (others => '0');
                p2_feed_buf <= (others => '0');
                p2_valid_sr <= (others => '0');
                p2_bv_sr <= (others => 0);
                p2_bin_sr <= (others => 0);
                p2_sorted_latch <= (others => '0');
                p2_wr_active <= '0';
                p2_wr_idx <= 0;
                p2_wr_batch_valid <= 0;
                p2_wr_bin <= 0;
                for b in 0 to N_BINS-1 loop
                    p2_bin_wr_count(b) <= 0;
                end loop;
                p2_finished <= '0';
            else
                -- === SHIFT REGISTER: advance pipeline tracking ===
                for i in P2_SR_LEN downto 1 loop
                    p2_valid_sr(i) <= p2_valid_sr(i-1);
                    p2_bv_sr(i) <= p2_bv_sr(i-1);
                    p2_bin_sr(i) <= p2_bin_sr(i-1);
                end loop;
                p2_valid_sr(0) <= '0';
                p2_bv_sr(0) <= 0;
                p2_bin_sr(0) <= 0;

                -- === READ SIDE: 1 read/cc by issuing next req in WAIT state ===
                -- REQ issues the first request. WAIT processes response AND issues
                -- next request in the same cc, achieving 1 read/cc steady state.
                case p2_rd_state is
                    when P2_RD_IDLE =>
                        mem_rd_req <= '0';
                        if phase = PHASE2_SORT then
                            p2_rd_bin <= 0;
                            p2_rd_idx <= 0;
                            p2_rd_batch_fill <= 0;
                            p2_batch_buf <= (others => '0');
                            p2_rd_state <= P2_RD_REQ;
                        end if;

                    when P2_RD_REQ =>
                        mem_rd_req <= '0';  -- Clear until we issue
                        -- Skip empty/exhausted bins
                        if p2_rd_bin >= N_BINS then
                            p2_rd_state <= P2_RD_DONE;
                        elsif hbm_bin_wr_count(p2_rd_bin) = 0 or
                              p2_rd_idx >= hbm_bin_wr_count(p2_rd_bin) then
                            p2_rd_bin <= p2_rd_bin + 1;
                            p2_rd_idx <= 0;
                        else
                            -- Issue first read request
                            mem_rd_req <= '1';
                            mem_rd_addr <= std_logic_vector(to_unsigned(
                                p2_rd_bin * 2 * MAX_BIN_ENTRIES + p2_rd_idx, 32));
                            p2_resp_idx <= p2_rd_idx;
                            p2_rd_idx <= p2_rd_idx + HBM_ENTRIES_PER_PAYLOAD;
                            p2_rd_state <= P2_RD_WAIT;
                        end if;

                    when P2_RD_WAIT =>
                        if mem_rd_valid = '1' then
                            -- Process response: unpack top entries
                            v_consume := HBM_ENTRIES_PER_PAYLOAD;
                            if LEVEL_SIZE - p2_rd_batch_fill < v_consume then
                                v_consume := LEVEL_SIZE - p2_rd_batch_fill;
                            end if;
                            if hbm_bin_wr_count(p2_rd_bin) - p2_resp_idx < v_consume then
                                v_consume := hbm_bin_wr_count(p2_rd_bin) - p2_resp_idx;
                            end if;

                            for e in 0 to HBM_ENTRIES_PER_PAYLOAD-1 loop
                                if e < v_consume then
                                    -- Reconstruct RAW_PRECISION entry from top record:
                                    -- MSBs = bin_id & lead_bits (for sorting), LSBs = pointer (preserved)
                                    -- Top record layout: [lead_bits | pointer(LB)]
                                    -- Reconstructed: [bin_id(BIN_ID_BITS) | lead_bits | zeros | pointer(LB)]
                                    p2_batch_buf(
                                        (p2_rd_batch_fill + e + 1)*RAW_PRECISION - 1
                                        downto
                                        (p2_rd_batch_fill + e)*RAW_PRECISION + LN + 3
                                    ) <= (others => '0');  -- pad upper bits above ln+2
                                    p2_batch_buf(
                                        (p2_rd_batch_fill + e)*RAW_PRECISION + LN + 2
                                        downto
                                        (p2_rd_batch_fill + e)*RAW_PRECISION + LNB
                                    ) <= mem_rd_data((e+1)*TOP_ENTRY_WIDTH-1 downto e*TOP_ENTRY_WIDTH + LB);  -- lead bits
                                    p2_batch_buf(
                                        (p2_rd_batch_fill + e)*RAW_PRECISION + LNB - 1
                                        downto
                                        (p2_rd_batch_fill + e)*RAW_PRECISION + LB
                                    ) <= (others => '0');  -- gap between pointer and lead bits
                                    p2_batch_buf(
                                        (p2_rd_batch_fill + e)*RAW_PRECISION + LB - 1
                                        downto
                                        (p2_rd_batch_fill + e)*RAW_PRECISION
                                    ) <= mem_rd_data(e*TOP_ENTRY_WIDTH + LB - 1 downto e*TOP_ENTRY_WIDTH);  -- pointer
                                end if;
                            end loop;

                            v_bv := p2_rd_batch_fill + v_consume;
                            v_batch_full := (v_bv >= LEVEL_SIZE);
                            v_bin_done := (p2_resp_idx + v_consume >= hbm_bin_wr_count(p2_rd_bin));

                            if v_batch_full or v_bin_done then
                                -- Feed completed batch to pipeline
                                p2_feed_buf <= p2_batch_buf;
                                for e in 0 to HBM_ENTRIES_PER_PAYLOAD-1 loop
                                    if e < v_consume then
                                        -- Same reconstruction as batch_buf above
                                        p2_feed_buf(
                                            (p2_rd_batch_fill + e + 1)*RAW_PRECISION - 1
                                            downto
                                            (p2_rd_batch_fill + e)*RAW_PRECISION + LN + 3
                                        ) <= (others => '0');
                                        p2_feed_buf(
                                            (p2_rd_batch_fill + e)*RAW_PRECISION + LN + 2
                                            downto
                                            (p2_rd_batch_fill + e)*RAW_PRECISION + LNB
                                        ) <= mem_rd_data((e+1)*TOP_ENTRY_WIDTH-1 downto e*TOP_ENTRY_WIDTH + LB);
                                        p2_feed_buf(
                                            (p2_rd_batch_fill + e)*RAW_PRECISION + LNB - 1
                                            downto
                                            (p2_rd_batch_fill + e)*RAW_PRECISION + LB
                                        ) <= (others => '0');
                                        p2_feed_buf(
                                            (p2_rd_batch_fill + e)*RAW_PRECISION + LB - 1
                                            downto
                                            (p2_rd_batch_fill + e)*RAW_PRECISION
                                        ) <= mem_rd_data(e*TOP_ENTRY_WIDTH + LB - 1 downto e*TOP_ENTRY_WIDTH);
                                    end if;
                                end loop;
                                p2_feed_valid <= '1';
                                p2_valid_sr(0) <= '1';
                                p2_bv_sr(0) <= v_bv;
                                p2_bin_sr(0) <= p2_rd_bin;
                                p2_rd_batch_fill <= 0;
                                p2_batch_buf <= (others => '0');

                                if v_bin_done then
                                    p2_rd_bin <= p2_rd_bin + 1;
                                    p2_rd_idx <= 0;
                                end if;
                            else
                                p2_rd_batch_fill <= v_bv;
                            end if;

                            -- Issue NEXT request in the same cc (pipelined)
                            -- Determine if more reads are needed
                            v_need_more_reads := true;
                            if v_bin_done then
                                -- Will move to next bin; go through REQ to skip empties
                                v_need_more_reads := false;
                            end if;

                            if v_need_more_reads and p2_rd_idx < hbm_bin_wr_count(p2_rd_bin) then
                                mem_rd_req <= '1';
                                mem_rd_addr <= std_logic_vector(to_unsigned(
                                    p2_rd_bin * 2 * MAX_BIN_ENTRIES + p2_rd_idx, 32));
                                p2_resp_idx <= p2_rd_idx;
                                p2_rd_idx <= p2_rd_idx + HBM_ENTRIES_PER_PAYLOAD;
                                -- Stay in P2_RD_WAIT
                            else
                                -- No more reads for this bin; go to REQ to advance
                                mem_rd_req <= '0';
                                p2_rd_state <= P2_RD_REQ;
                            end if;
                        end if;
                        -- When mem_rd_valid='0', mem_rd_req stays asserted from
                        -- when the request was issued, so the arbiter will eventually pick it up.

                    when P2_RD_DONE =>
                        mem_rd_req <= '0';
                end case;

                -- === WRITE SIDE: latch sorted output, pack into HBM payloads ===
                -- When shift register output fires, latch the sorted pipeline output
                if p2_valid_sr(P2_SR_LEN) = '1' and p2_wr_active = '0' then
                    p2_sorted_latch <= numout_level(N_LEVELS-1, FS_DEPTH);
                    p2_wr_batch_valid <= p2_bv_sr(P2_SR_LEN);
                    p2_wr_bin <= p2_bin_sr(P2_SR_LEN);
                    p2_wr_idx <= 0;
                    p2_wr_active <= '1';
                end if;

                if p2_wr_active = '1' then
                    v_wr_remain := p2_wr_batch_valid - p2_wr_idx;
                    if v_wr_remain > 0 then
                        -- Pack up to HBM_ENTRIES_PER_PAYLOAD entries
                        if v_wr_remain >= HBM_ENTRIES_PER_PAYLOAD then
                            v_wr_pack := HBM_ENTRIES_PER_PAYLOAD;
                        else
                            v_wr_pack := v_wr_remain;
                        end if;

                        p2_mem_dout <= (others => '0');
                        for e in 0 to HBM_ENTRIES_PER_PAYLOAD-1 loop
                            if e < v_wr_pack then
                                -- Store sorted top record: lead_bits & pointer
                                -- Extract from sorted RAW_PRECISION entry:
                                --   lead_bits = bits [LNB .. LN+2], pointer = bits [LB-1 .. 0]
                                p2_mem_dout((e+1)*TOP_ENTRY_WIDTH-1 downto e*TOP_ENTRY_WIDTH + LB)
                                    <= p2_sorted_latch(
                                        (LEVEL_SIZE - p2_wr_batch_valid + p2_wr_idx + e)*RAW_PRECISION + LN + 2
                                        downto
                                        (LEVEL_SIZE - p2_wr_batch_valid + p2_wr_idx + e)*RAW_PRECISION + LNB);
                                p2_mem_dout(e*TOP_ENTRY_WIDTH + LB - 1 downto e*TOP_ENTRY_WIDTH)
                                    <= p2_sorted_latch(
                                        (LEVEL_SIZE - p2_wr_batch_valid + p2_wr_idx + e)*RAW_PRECISION + LB - 1
                                        downto
                                        (LEVEL_SIZE - p2_wr_batch_valid + p2_wr_idx + e)*RAW_PRECISION);
                            end if;
                        end loop;
                        p2_mem_wr_en <= '1';
                        p2_mem_wr_addr <= std_logic_vector(to_unsigned(
                            N_BINS * 2 * MAX_BIN_ENTRIES +
                            p2_wr_bin * MAX_BIN_ENTRIES +
                            p2_bin_wr_count(p2_wr_bin), 32));

                        p2_bin_wr_count(p2_wr_bin) <= p2_bin_wr_count(p2_wr_bin) + v_wr_pack;
                        p2_wr_idx <= p2_wr_idx + v_wr_pack;
                    else
                        p2_wr_active <= '0';
                    end if;
                end if;

                -- === DONE DETECTION ===
                -- All reads done, pipeline drained (no valid in SR), writes idle
                v_rd_all_done := (p2_rd_state = P2_RD_DONE);
                if v_rd_all_done and p2_wr_active = '0' and
                   p2_valid_sr = (p2_valid_sr'range => '0') then
                    p2_finished <= '1';
                end if;
            end if;
        end if;
    end process;

    -- Drive count from pipeline output so the design is not optimized away.
    count <= to_integer(unsigned(numout_level(N_LEVELS-1, FS_DEPTH)(LOGN-1 downto 0)))
           + fs_total_ones(0);

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
                -- L0 input: top 31 bits of each RAW_PRECISION entry
                write(l_out, string'("[cyc=" & integer'image(sim_cyc) & "] INPUT :"));
                for i in 0 to LEVEL_SIZE-1 loop
                    write(l_out, string'( integer'image(to_integer(unsigned(
                        numout_level(0,0)((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION+RAW_PRECISION-31)))) & " "));
                end loop;
                writeline(output, l_out);
                -- Final output: top 31 bits of each sorted entry
                write(l_out, string'("[cyc=" & integer'image(sim_cyc) & "] OUTPUT:"));
                for i in 0 to LEVEL_SIZE-1 loop
                    write(l_out, string'( integer'image(to_integer(unsigned(
                        numout_level(N_LEVELS-1,FS_DEPTH)((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION+RAW_PRECISION-31)))) & " "));
                end loop;
                writeline(output, l_out);
                -- Check if output is non-decreasing (using top 31 bits)
                sorted := true;
                prev_val := 0;
                for i in 0 to LEVEL_SIZE-1 loop
                    cur_val := to_integer(unsigned(
                        numout_level(N_LEVELS-1,FS_DEPTH)((i+1)*RAW_PRECISION-1 downto i*RAW_PRECISION+RAW_PRECISION-31)));
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
