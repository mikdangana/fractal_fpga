
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
    CONSTANT INPUT_SIZE : INTEGER := 1*N; --4*BASE_INPUT_SIZE; --8*8*8*9=4608; --depth*fanout*base_size --1152; --9216; --288/PRECISION;
    CONSTANT DATASET_SIZE: INTEGER := 2**28;
    CONSTANT W_ADDR : INTEGER := 16;
    CONSTANT RAM_LEN: INTEGER := (2**20) / W_ADDR; --(2**28) / W_ADDR;
    CONSTANT N_BKTS: INTEGER := 2;  -- slot 0: write zeros+ones count; slot 1: read-back for accumulation

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
	          fifo_dready: in std_logic);
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
    signal ram : slv_ram_arr(0 to RAM_LEN-1) := (others => (others => '0'));
    --signal n_address1 : count_1d_t(0 to N_BKTS*LEVEL_SIZE) := (others => 0);
    signal req_addr  : addr_array(0 to N_BKTS*LEVEL_SIZE) := (others => (others => '0'));
    signal req_data  : data_array(0 to N_BKTS*LEVEL_SIZE) := (others => (others => '0'));
    signal req_valid : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
    signal req_ack   : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
    signal req_re_en : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
    signal req_wr_en : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
	signal req_turn  : integer range 0 to N_BKTS*LEVEL_SIZE-2 := 0;
	signal fifo_wr_ens: std_logic := '0';
	signal fifo_re_ens: std_logic := '0';
	signal fifo_dws: std_logic_vector(4*W_ADDR-1 downto 0) := (others => '0');
    signal fifo_drs: std_logic_vector(4*W_ADDR-1 downto 0) := (others => '0');
	signal fifo_dreadys: std_logic := '0';
    



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

	signal starts : level_ints := (N-1 downto 0 => 0);
	signal stops : level_ints := (N-1 downto 0 => 0);
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
		
		
    -- ff_cd_node_ids: single combinational process.
    -- Node ID grows with l: bits min(l,LOGN)-1..0 hold the node address.
    -- Reads LOGN bits, masks off bits above min(l,LOGN)-1 at runtime.
    ff_cd_node_ids: process(numout_level)
        variable nid_raw  : std_logic_vector(LOGN-1 downto 0);
        variable nid_i    : integer range 0 to LEVEL_SIZE-1;
        variable v_start  : integer;
        variable v_end    : integer;
        variable nid_bits : integer range 0 to LOGN;
    begin
        for l in 0 to N_LEVELS-2 loop
            if l = 0 then nid_bits := 0;
            elsif l < LOGN then nid_bits := l;
            else nid_bits := LOGN;
            end if;
            for nid in 0 to LEVEL_SIZE-1 loop
                v_start := LEVEL_SIZE; v_end := 0;
                if l = 0 then
                    if nid = 0 then v_start := 0; v_end := LEVEL_SIZE; end if;
                else
                    for i in 0 to LEVEL_SIZE-1 loop
                        nid_raw := numout_level(l, 1)(i*PRECISIONS+LOGN-1 downto i*PRECISIONS);
                        for b in 0 to LOGN-1 loop
                            if b >= nid_bits then nid_raw(b) := '0'; end if;
                        end loop;
                        nid_i := to_integer(unsigned(nid_raw));
                        if nid_i = nid then
                            if i < v_start then v_start := i; end if;
                            if i+1 > v_end  then v_end   := i+1; end if;
                        end if;
                    end loop;
                end if;
                sorted_start_level(l, nid) <= v_start;
                sorted_end_level(l, nid)   <= v_end;
            end loop;
        end loop;
    end process;
    
    
    -- ff_cd_shards: counter + filter circuit.
    --
    -- Counter: for each (level l, node pos), count how many entries i in
    --   [sorted_start_level(l,pos), sorted_end_level(l,pos)) have d_p(i)=0
    --   and how many have d_p(i)=1.
    --
    -- Filter (prefix sum): split_level(l,pos) = sorted_start_level(l,pos)
    --   + node_zeros(l,pos) is the boundary between the 0-group and 1-group
    --   within the sorted node window.
    --
    -- Synthesis note: the generate loop instantiates one process per (l,pos)
    -- pair.  Every signal write uses the generate-time constants l and pos as
    -- indices, so all assignments elaborate to FIXED addresses — no variable-
    -- indexed writes and no mux explosion.
    -- Combinational: split_level always tracks the current numout_level(l,1)
    -- so ff_dp_partition reads consistent data at the same clock edge.
    ff_cd_shards:
    for l in 0 to N_LEVELS-2 generate
        shards_pos: for pos in 0 to LEVEL_SIZE-2 generate
            process(numout_level, sorted_start_level, sorted_end_level)
                constant KEY_BIT : integer := KEY_OFFSET + (l mod (PRECISIONS - KEY_OFFSET));
                variable n_z : integer range 0 to LEVEL_SIZE;
            begin
                n_z := 0;
                for i in 0 to LEVEL_SIZE-1 loop
                    if i >= sorted_start_level(l, pos) and
                       i <  sorted_end_level(l, pos) and
                       numout_level(l, 1)(i*PRECISIONS + KEY_BIT) = '0' then
                        n_z := n_z + 1;
                    end if;
                end loop;
                node_zeros(l, pos)  <= n_z;
                node_ones(l, pos)   <= sorted_end_level(l, pos)
                                    - sorted_start_level(l, pos) - n_z;
                split_level(l, pos) <= sorted_start_level(l, pos) + n_z;
            end process;
        end generate shards_pos;
    end generate ff_cd_shards;
    
    -- mem_update: clocked process that writes per-node sorted statistics to
    -- external RAM via the req signals, one N_BKTS-slot group per node pos.
    --   slot pos*N_BKTS+0 : write  node_zeros & node_ones  (zeros/ones count pair)
    --   slot pos*N_BKTS+1 : read-back the same address for host accumulation
    -- split_level and sorted_end are NOT stored separately: they are fully
    -- derivable as sorted_start + node_zeros and sorted_start + node_zeros + node_ones.
    -- The 0-child address pointer is written only on first-time node creation
    -- (n_address = 0, p >= P_COMPUTABLE) — not yet implemented; requires
    -- n_address tracking to be added.
    -- Addressing uses get_addr(node_id, N) for tree-hierarchy RAM layout.
    mem_update:
    for pos in 0 to LEVEL_SIZE-2 generate
        process(clk)
        begin
            if rising_edge(clk) then
                -- Slot 0: write zeros + ones counts
                req_addr(pos * N_BKTS + 0) <= std_logic_vector(
                    to_unsigned(get_addr(pos, N)(0), 32));
                req_data(pos * N_BKTS + 0) <=
                    std_logic_vector(to_unsigned(node_zeros(N_LEVELS-2, pos), W_ADDR)) &
                    std_logic_vector(to_unsigned(node_ones (N_LEVELS-2, pos), W_ADDR));
                req_wr_en(pos * N_BKTS + 0) <= '1';
                req_re_en(pos * N_BKTS + 0) <= '0';

                -- Slot 1: read-back same address for host to accumulate across batches
                req_addr(pos * N_BKTS + 1) <= std_logic_vector(
                    to_unsigned(get_addr(pos, N)(0), 32));
                req_data(pos * N_BKTS + 1) <= (others => '0');
                req_wr_en(pos * N_BKTS + 1) <= '0';
                req_re_en(pos * N_BKTS + 1) <= '1';
            end if;
        end process;
    end generate mem_update;

    -- ff_dp_partition: for each level l, reorder entries within each node
    -- so that d_p=0 entries fill [sorted_start, split) and d_p=1 entries fill
    -- [split, sorted_end), writing the result to numout_level(l+1, 0) which
    -- becomes the input for the next pipeline stage.
    --
    -- Outer generate over l: one process per level, so numout_level(l+1,0)
    -- has exactly one driver per level — no multi-driver conflict.
    -- Inner j loop (0..LEVEL_SIZE-1) is unrolled to compile-time constants,
    -- so every slice write has a fixed address — no mux explosion.
    --
    -- numout_level(0,0) is driven by fs_scatter (= numbers_p).
    -- ff_dp_partition writes numout_level(l+1,0) after fs_scatter sorts each level.
    -- ff_dp_partition: reorder entries within each node so d_p=0 entries fill
    -- [sorted_start, split) and d_p=1 entries fill [split, sorted_end), writing
    -- the result to numout_level(l+1, 0) for the next pipeline stage.
    --
    -- Generate over both l and j: 41*8=328 instances, each owning one output
    -- slice — exactly one driver per (l+1, 0, j) with no multi-driver conflict.
    --
    -- Each process has two SEQUENTIAL (not nested) for loops:
    --   1. pos loop (7 iters): find this j's node bounds → local variables
    --   2. i   loop (8 iters): find the rank-th same-type entry in the node
    -- Total: 7+8=15 iterations vs the naive 7*8=56 nested approach.
    ff_dp_partition:
    for l in 0 to N_LEVELS-2 generate
        part_j: for j in 0 to LEVEL_SIZE-1 generate
            process(clk)
                constant KEY_BIT : integer := KEY_OFFSET + (l mod (PRECISIONS - KEY_OFFSET));
                variable v_start : integer range 0 to LEVEL_SIZE;
                variable v_split : integer range 0 to LEVEL_SIZE;
                variable v_end   : integer range 0 to LEVEL_SIZE;
                variable rank    : integer range 0 to LEVEL_SIZE;
                variable cnt     : integer range 0 to LEVEL_SIZE;
                variable entry_i : std_logic_vector(PRECISIONS-1 downto 0);
            begin
                if rising_edge(clk) then
                    -- Pass 1: find the node that owns output position j
                    v_start := 0; v_split := 0; v_end := 0;
                    for pos in 0 to LEVEL_SIZE-1 loop
                        if j >= sorted_start_level(l, pos) and
                           j <  sorted_end_level(l, pos) then
                            v_start := sorted_start_level(l, pos);
                            v_split := split_level(l, pos);
                            v_end   := sorted_end_level(l, pos);
                        end if;
                    end loop;
                    -- Rank of j within its type group (0s first)
                    if j < v_split then
                        rank := j - v_start;   -- 0-slot
                    else
                        rank := j - v_split;   -- 1-slot
                    end if;
                    -- Pass 2: find the rank-th same-type entry within the node
                    -- Key bit read directly from entry; no d_p port needed
                    entry_i := (others => '0');
                    cnt := 0;
                    for i in 0 to LEVEL_SIZE-1 loop
                        if i >= v_start and i < v_end then
                            if (j < v_split and numout_level(l, 1)(i*PRECISIONS + KEY_BIT) = '0') or
                               (j >= v_split and numout_level(l, 1)(i*PRECISIONS + KEY_BIT) = '1') then
                                if cnt = rank then
                                    entry_i := numout_level(l, 1)
                                        ((i+1)*PRECISIONS-1 downto i*PRECISIONS);
                                end if;
                                cnt := cnt + 1;
                            end if;
                        end if;
                    end loop;
                    -- Record which group this output slot belongs to (0=zeros, 1=ones).
                    -- Bit l of entry encodes the node ID bit for level l (for l < LOGN).
                    if l < LOGN then
                        if j < v_split then
                            entry_i(l) := '0';
                        else
                            entry_i(l) := '1';
                        end if;
                    end if;
                    numout_level(l+1, 0)((j+1)*PRECISIONS-1 downto j*PRECISIONS) <= entry_i;
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

    -- fs_scatter: clocked, one process per (l,j).
    -- Uses shared fs_total_ones(l) (2 scan loops, no count loop duplication).
    -- 0-entries mapped to positions 0..total_zeros-1,
    -- 1-entries mapped to positions total_zeros..LEVEL_SIZE-1.

    -- Stage-0 input: register raw numbers input
    numout_level(0, 0) <= numbers_p;

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


    mem_req_arbiter: process(clk)
        -- Round-robin over all N_BKTS*LEVEL_SIZE-1 request slots.
        -- Sends one request per cycle unconditionally (fire-and-forget for writes;
        -- reads are also pipelined). The outer arbiter in fractal.vhd rate-limits
        -- forwarding via fifo_ready, but we don't block here — that way the
        -- inner req_turn advances every cycle and cycles through all node slots.
        constant N_SLOTS : integer := N_BKTS * LEVEL_SIZE - 1;
        variable next_s  : integer range 0 to N_BKTS*LEVEL_SIZE-2;
        variable found   : boolean;
    begin
        if rising_edge(clk) then
            fifo_wr_en <= '0';
            fifo_re_en <= '0';
            fifo_dw    <= (others => '0');
            found := false;
            for i in 0 to N_BKTS*LEVEL_SIZE-2 loop
                next_s := (req_turn + i) mod N_SLOTS;
                if not found then
                    if req_wr_en(next_s) = '1' then
                        fifo_wr_en <= '1';
                        fifo_dw    <= req_addr(next_s) & req_data(next_s);
                        req_turn   <= (next_s + 1) mod N_SLOTS;
                        found      := true;
                    elsif req_re_en(next_s) = '1' then
                        fifo_re_en <= '1';
                        fifo_dw    <= req_addr(next_s) & req_data(next_s);
                        req_turn   <= (next_s + 1) mod N_SLOTS;
                        found      := true;
                    end if;
                end if;
            end loop;
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
