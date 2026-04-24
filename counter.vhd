
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
    CONSTANT N_BKTS: INTEGER := 3;

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
	        d_p : in std_logic_vector(LEVEL_SIZE-1 downto 0);
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
    
    type count_1d_t is array (natural range <>) of integer;
    type count_2d_t is array (natural range <>, natural range <>) of integer;
    type count_3d_t is array (natural range<>, natural range <>, natural range <>) of integer;

	
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
	
	
	alias MyInput: std_logic_vector(d_p'Length-1 downto 0) IS d_p;
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
    signal node_count : count_3d_t(0 to N_LEVELS, 0 to logNceil(LEVEL_SIZE, N), 0 to LEVEL_SIZE-1) := (others => (others => (others => 0)));
    --signal node_ids : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    --signal sorted_node_ids : count_3d_t(0 to N_SHARDS, 0 to N_LEVELS, 0 to LEVEL_SIZE-1) := (others => (others => (others => 0)));
    --signal start_pos : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE-1) := (others => (others => 0));
    signal start_pos : count_1d_t(0 to LEVEL_SIZE) := (others => 0);
    signal sorted_start_level1 : count_1d_t(0 to N_LEVELS*LEVEL_SIZE) := (others => 0);
    signal sorted_start_level : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    signal sorted_end_level : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    signal ram : slv_ram_arr(0 to RAM_LEN-1) := (others => (others => '0'));
    --signal n_address1 : count_1d_t(0 to N_BKTS*LEVEL_SIZE) := (others => 0);
    signal n_address : count_2d_t(0 to N_LEVELS, 0 to LEVEL_SIZE) := (others => (others => 0));
    signal req_qhead: integer := 0;
    signal req_qtail: integer := 0;
    signal req_q : count_1d_t(0 to N_BKTS*LEVEL_SIZE) := (others => 0);
    signal req_addr  : addr_array(0 to N_BKTS*LEVEL_SIZE) := (others => (others => '0'));
    signal req_data  : data_array(0 to N_BKTS*LEVEL_SIZE) := (others => (others => '0'));
    signal req_valid : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
    signal req_ack   : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
    signal req_re_en : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
    signal req_wr_en : std_logic_vector(0 to N_BKTS*LEVEL_SIZE-2) := (others => '0');
	signal fifo_wr_ens: std_logic := '0';
	signal fifo_re_ens: std_logic := '0';
	signal fifo_dws: std_logic_vector(4*W_ADDR-1 downto 0) := (others => '0');
    signal fifo_drs: std_logic_vector(4*W_ADDR-1 downto 0) := (others => '0');
	signal fifo_dreadys: std_logic := '0';
    

	signal e1_1 : slv1_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal e1_2 : slv2_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal e1_3 : slv3_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal e2_1 : slv1_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal e2_2 : slv2_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal e2_3 : slv3_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal e3_1 : slv1_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal e3_2 : slv2_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal e3_3 : slv3_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal n1_1 : slv_p_arr   (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal n1_2 : slv_2p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal n1_3 : slv_3p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal n2_1 : slv_p_arr   (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal n2_2 : slv_2p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal n2_3 : slv_3p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal n3_1 : slv_p_arr   (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal n3_2 : slv_2p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal n3_3 : slv_3p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal m1_1 : slv_p_arr   (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal m1_2 : slv_2p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal m1_3 : slv_3p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal m2_1 : slv_p_arr   (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal m2_2 : slv_2p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal m2_3 : slv_3p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    signal m3_1 : slv_p_arr   (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal m3_2 : slv_2p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal m3_3 : slv_3p_arr  (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    
    
    signal o1   : slv_base_arr (0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal o3   : slv_basep_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));
    signal o5   : slv_basep_arr(0 to N_SHARDS, 0 to N_BASE-1) := (others => (others => (others => '0')));


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
		
		
    ff_cd_node_ids: process(clk, sorted_end_level, sorted_start_level, n_address, numout_level)
        variable total_count: integer := to_integer(unsigned(ram(0))); -- TODO: Align counter width
    begin
        for l in 0 to N_LEVELS-2 loop
          for i in 0 to LEVEL_SIZE-2 loop
            if (rising_edge(clk)) then
              if ((numout_level(l, logNceil(LEVEL_SIZE, N))(min(((i+0)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS)-1 downto min(((i+0)*PRECISIONS)+(2*LOGN), LEVEL_SIZE*PRECISIONS)-1) = 
                    numout_level(l, logNceil(LEVEL_SIZE, N))(min(((i+1)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS)-1 downto min(((i+1)*PRECISIONS)+(2*LOGN), LEVEL_SIZE*PRECISIONS)-1)) and
                (numout_level(l, logNceil(LEVEL_SIZE, N))((min(((i+1)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS)-1)) /= 
                    numout_level(l, logNceil(LEVEL_SIZE, N))((min(((i+0)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS)-1))) and 
                (numout_level(l, logNceil(LEVEL_SIZE, N))(min(((i+0)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS)-1) = '0')) then
                    sorted_start_level(l, get_nid(l, i)) <= i;
                    sorted_end_level(l, max(0, get_nid(l,i)-1)) <= i;
               end if;
               if ((sorted_end_level(l, get_nid(l,i))>sorted_start_level(l, get_nid(l,i)) and 
                         sorted_end_level(l, max(0,get_nid(l,i)-1))>sorted_start_level(l, max(0,get_nid(l,i)-1)))) then
                   if (p > P_COMPUTABLE and n_address(l, get_nid(l,i)) = 0) then
                        --create new node
                         req_wr_en(get_nid(l,i)) <= '1';
                         n_address(l, get_nid(l,i)) <= total_count;
                   elsif n_address(l, get_nid(l,i)) > 0 and (req_data(get_nid(l,i))((3*W_ADDR-(p-P_COMPUTABLE)-1)) /= 
                        numout_level(l, logNceil(LEVEL_SIZE, N))((i*PRECISIONS) mod LEVEL_SIZE) or 
                        p >= P+N_LEVELS-1) then
                         -- update existing node count and create new node
                         n_address(l, get_nid(l,i)) <= total_count;
                   end if;
               end if;
             end if;
          end loop;
        end loop;
    end process;
    
    
    ff_cd_shards:
    for s in 0 to N_SHARDS-1 generate
      ff_shifters:
      for l in 0 to N_LEVELS-2 generate
        ff_shift_level:
        for i in 0 to LEVEL_SIZE-2 generate
            ff_cd_prefix_sum: process (clk, sorted_end_level, sorted_start_level, n_address,
                numout_level(l, logNceil(LEVEL_SIZE, N))((i+1)*PRECISIONS-1 downto i*PRECISIONS)) --,
                --sorted_node_ids(l, i), sorted_node_ids(l, i+1))
                alias level: std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) is numout_level(l, logNceil(LEVEL_SIZE, N));
                variable node_id: integer := max(0, min(LEVEL_SIZE-1, to_integer(unsigned(level(i*PRECISIONS+2*LOGN-1 downto i*PRECISIONS+LOGN)))));
                variable entry_id: integer := to_integer(unsigned(level(i*PRECISIONS+LOGN-1 downto i*PRECISIONS)));
                variable entry_id1: integer := to_integer(unsigned(level((i+1)*PRECISIONS+LOGN-1 downto (i+1)*PRECISIONS)));
                variable parent_id: integer := node_id / 2;
                variable p: integer := P+l; -- mod (PRECISIONS/2);
                variable p_comp: integer := max(P_COMPUTABLE, P);
                variable start: integer := start_pos(parent_id);
                variable old_count: integer := 0;
                variable old_count1: integer := 0;
                --variable countl: integer := sorted_end_level(l, node_id)-sorted_start_level(l, node_id);
                --variable countr: integer := sorted_end_level(l, node_id-1)-sorted_start_level(l, node_id-1);
                variable n_addr: tuple := get_addr(node_id, LEVEL_SIZE); -- when p<32 else (n_address(l, node_id), W_ADDR);
                variable n_val: std_logic_vector(2*W_ADDR-1 downto 0) := 
                    ram(n_addr(0)/W_ADDR) & ram(((n_addr(0)/W_ADDR)+1) mod RAM_LEN);
                variable non_comp_naddr : integer := n_address(l, node_id);
                variable s: natural := n_addr(0) mod W_ADDR; 
                variable w: natural := n_addr(1);
                variable countn: integer := (sorted_end_level(l, node_id)-sorted_start_level(l, node_id));
                variable countl: integer := (sorted_end_level(l, node_id)-sorted_start_level(l, node_id)) * 2**(2*W_ADDR-(s+w));
                variable countr: integer := (sorted_end_level(l, max(0,node_id-1))-sorted_start_level(l, max(0,node_id-1))) * 2**(2*W_ADDR-(s+w));
                -- Need to fix the width and alignment of countv to match `s`
                variable countv: std_logic_vector(2*W_ADDR-1 downto 0) := std_logic_vector(to_unsigned(countl, 2*W_ADDR));
                variable new_count: std_logic_vector(2*W_ADDR-1 downto 0) := 
                    std_logic_vector(to_unsigned(to_integer(unsigned(n_val)) + countl, 2*W_ADDR));
                variable total_count: integer := to_integer(unsigned(ram(0))); -- TODO: Align counter width
                --variable b0: std_logic_vector(0 downto 0) := "1" when P < RAW_PRECISION else "0";
                variable i1p: integer := min(((i+1)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS);
                variable i0p: integer := min(((i+0)*PRECISIONS)+(2*LOGN)+p, LEVEL_SIZE*PRECISIONS);
                variable i1: integer := min(((i+1)*PRECISIONS)+(2*LOGN), LEVEL_SIZE*PRECISIONS);
                variable i0: integer := min(((i+0)*PRECISIONS)+(2*LOGN), LEVEL_SIZE*PRECISIONS);
            begin
            if (rising_edge(clk) and (level(i0p-1 downto i0-1) = level(i1p-1 downto i1-1)) and
                    (level((i1p-1)) /= level((i0p-1))) and 
                    (level(i0p-1) = '0') and (sorted_start_level1(node_id) /= i)) then
                    --sorted_start_level1(node_id) <= i;
                    --sorted_start_level(l, node_id) <= i; -- sorted_node_ids(s, l, i)) <= i;
                    --sorted_end_level(l, max(0,node_id-1)) <= i; --sorted_node_ids(s, l, i+1)) <= i;
                end if;
                
                
                if (rising_edge(clk)) then -- and i>=sorted_start_level(l, node_id) and i<sorted_start_level(l, node_id+1)) then
                    if ((sorted_end_level(l, node_id)>sorted_start_level(l, node_id) and 
                         sorted_end_level(l, max(0,node_id-1))>sorted_start_level(l, max(0,node_id-1)))) then -- or (p >= P+N_LEVELS-1))) then
                      if (p < P_CACHE or DATASET_SIZE < 2**29) then 
                        ram((n_addr(0) / W_ADDR) mod RAM_LEN) <= new_count(2*W_ADDR-1 downto W_ADDR);
                        ram(((n_addr(0) / W_ADDR)+1) mod RAM_LEN) <= new_count(W_ADDR-1 downto 0);
                      elsif (p < P_COMPUTABLE or DATASET_SIZE < 2**32) then
                            req_re_en(node_id) <= '1';
                            req_addr(node_id) <= std_logic_vector(to_unsigned(n_addr(0) / W_ADDR, 32));
                            req_data(node_id*2) <= countv;     
                      elsif (n_address(l, node_id) = 0) then
                        --create new node
                         req_wr_en(node_id) <= '1';
                         --n_address(l, node_id) <= total_count;
                         req_addr(node_id) <= std_logic_vector(to_unsigned(total_count, 32));
                         req_data(node_id) <= std_logic_vector(to_unsigned(countn, W_ADDR)) &
                             level(i*PRECISIONS+p downto i*PRECISIONS+p_comp) & ((N_LEVELS-p)+(2*W_ADDR)-4 downto 0 => '0'); --count, identifier, left, right
                         --req_valid(i) <= '1';
                      elsif n_address(l, node_id) > 0 and req_data(node_id)(3*W_ADDR-(p-P_COMPUTABLE)-1) = level(i*PRECISIONS) then
                         --update existing node count
                         req_re_en(node_id) <= '1';
                         req_addr(node_id) <= std_logic_vector(to_unsigned(n_address(l, node_id), 32));
                         req_data(node_id) <= std_logic_vector(to_unsigned(countn, W_ADDR));
                      elsif n_address(l, node_id) > 0 and (req_data(node_id)(3*W_ADDR-(p-P_COMPUTABLE)-1) /= level(i*PRECISIONS) or
                                                           p >= P+N_LEVELS-1) then
                         -- update existing node count and create new node
                         req_re_en(node_id) <= '1';
                         req_addr(node_id) <= std_logic_vector(to_unsigned(non_comp_naddr, 32));
                         req_data(node_id) <= std_logic_vector(to_unsigned(countn, W_ADDR));
                         --n_address(l, node_id) <= 0; --total_count;                        
                      end if;
                    end if;
                    if l < N_LEVELS-1 and (i < sorted_end_level(l, node_id)) and (i>=sorted_start_level(l, node_id)) then
                      --numout_level(l+1, 0)(start_pos(node_id) + (i-sorted_start_level(l, node_id))) <= level(i);
                    end if;
                end if;
                
                
            end process;
                        
            --start_pos(l+1, i) <= start_pos(l, i) + (sorted_end_level(l, 0)-sorted_start_level(l, 0)); --node_ids(l, i)));
            --node_ids(l+1, i) <= node_ids(l, i)*2 + 1 
                --when (sorted_end_level(l, node_ids(l, i))-sorted_start_level(l, node_ids(l, i))) > (i-start_pos(l,i)) else node_ids(l, i)*2;
                --when (sorted_end_level(l, 0)-sorted_start_level(l, 0)) > (i-start_pos(l,i)) else node_ids(l, i)*2;
            --numout_p(i-start_pos(l+1, i) + sorted_start_level(l, node_ids(l, i))) <= 
            --numout_p(i-start_pos(l+1, i) + sorted_start_level(l, 0)) <= 
                --numout_level(0)(i-start_pos(l+1, i) + sorted_start_level(l, node_ids(l, i)));
                --numout_level(N_SHARDS-1, 0)(i-start_pos(l+1, i) + sorted_start_level(l, 0));
                
                
            --numout_p(i-start_pos(l+1, i) + sorted_start_level(l, 0)) <= 
            --    --numout_level(0)(i-start_pos(l+1, i) + sorted_start_level(l, node_ids(l, i)));
            --    numout_level(N_SHARDS-1, 0)(i-start_pos(l+1, i) + sorted_start_level(l, 0));
        end generate ff_shift_level;
        
        
        counts0: for i in 0 to LEVEL_SIZE-1 generate
            --node_count(l, 0, i) <= 0 when numout_level(l, logNceil(LEVEL_SIZE, N)-1)(i*PRECISIONS+PRECISIONS/2-1) = '0' else 1;
            node_count(l, 0, i) <= 0 when numout_level(l, 0)(i*PRECISIONS+PRECISIONS/2-1) = '0' else 1;
        end generate counts0;   
        
        
        gen_levels :
        for lc in 1 to logNceil(LEVEL_SIZE, N) generate
          -- Nodes at level l
          --gen_nodes:
          --for n in 0 to (N**(lc-1))-1 generate
          gen_nodes: for n in 0 to 0 generate --(LEVEL_SIZE / (N**lc)) - 1 generate
          
            -- N is the base (8)
            -- SIZE is the total number of inputs
            -- LOGNSIZE is ceil(log8(SIZE))
            
            -- Calculate how many nodes exist at this specific level
            -- Level 1 has SIZE/8 nodes, Level 2 has SIZE/64, etc.
                
            -- Each node (n) at level (lc) is the sum of N children 
            -- from level (lc-1)
            process(node_count)
                variable temp_sum : natural := 0;
                variable B : natural := 8; --N;
                variable start : natural := n*(B**lc) mod LEVEL_SIZE; 
            begin
                temp_sum := 0;
                for i in 0 to B-1 loop --N-1 loop
                    -- Indexing logic: 
                    -- The 8 children of node 'n' are located at (n*8) through (n*8 + 7)
                    --temp_sum := temp_sum + node_count(l, lc-1, start + (i*B**(lc-1))); --(n*N + i) mod LEVEL_SIZE);
                    temp_sum := temp_sum + node_count(l, lc-1, (n*N + i) mod LEVEL_SIZE);
                end loop;
                
                node_count(l, lc, n) <= temp_sum;
            end process;
            
            -- Same binary-tree aggregation as before
            --fastcount_node:
            --for b in 1 to LOGNSIZE-1 generate
            --  innercount_node:
            --  for c in 0 to N/(2**b)-1 generate
            --    node_count(lc, (n+1) * 2*N - N/(2**(b-1)) + c) <= 
            --        node_count(lc, (n+1) * 2*N - N/(2**(b-2)) + 2*c) + node_count(lc, (n+1) * N - N/(2**(b-2)) + 2*c+1); 
            --  end generate innercount_node;
            --end generate fastcount_node;
    
            
            process(node_count)
                variable temp_sum : natural := 0;
                variable temp_sum1: natural := 0;
                variable ncount : natural := 0;
            begin
                temp_sum := 0;
                for i in 0 to N-1 loop
                    temp_sum1 := (i+1)*(N**(lc-1)) - temp_sum + node_count(l, lc, (n*N) mod LEVEL_SIZE);
                    ncount := (N**(lc-1)) - node_count(l, lc-1, (n*N + i) mod LEVEL_SIZE);
                    -- Indexing logic: 
                    -- The 8 children of node 'n' are located at (n*8) through (n*8 + 7)
                    numout_level(l, lc)(temp_sum+node_count(l, lc-1, (n*N + i) mod LEVEL_SIZE) downto temp_sum) <= 
                        numout_level(l, lc-1)(node_count(l, lc-1, (n*N + i) mod LEVEL_SIZE)+(n*(N**(lc-1)))*PRECISIONS downto (n*(N**(lc-1)))*PRECISIONS);
                    numout_level(l,lc)(temp_sum1+ncount downto temp_sum1) <= 
                        numout_level(l, lc-1)(((n+1)*(N**(lc-1)))*PRECISIONS-1 downto node_count(l, lc-1, (n*N + i) mod LEVEL_SIZE)+(n*(N**(lc-1)))*PRECISIONS);
                    temp_sum := temp_sum + node_count(l, lc-1, (n*N + i) mod LEVEL_SIZE);
                end loop;
                
            end process;
            
            --FastShifts_node:
            --for c in 0 to integer(real(INPUT_SIZE) / real(N**lc))-1 generate 
            --  numout_level(l, lc)((INPUT_SIZE / (N**lc) + c+1)*PRECISIONS-1 downto (INPUT_SIZE / (N**lc) + c)*PRECISIONS) <= 
            --     numout_level(s, l+1)(8*(LEVEL_SIZE*PRECISIONS/N) + (c-get_base(8)) when node_count(s, l+1, (n+1+7) * 2*N - 1)>0 and c-get_base(8) <= counts(8) else
            --     --node_level(s, l+1)(8*(LEVEL_SIZE*PRECISIONS/N) + (c-get_base(8)) when node_count(s, l+1, (n+1+7) * 2*N - 1)>0 and c-get_base(8) <= counts(8) else
            --     --((INPUT_SIZE / (N**lc) + c+1)*PRECISIONS-1 downto (INPUT_SIZE / (N**lc) + c)*PRECISIONS => '0');
            --end generate FastShifts_node;
          end generate gen_nodes;
    
        end generate gen_levels;
      end generate ff_shifters;
    end generate ff_cd_shards;
    
    numout_level(0, 0) <= numbers_p;
    
    numout_p <= numout_level(N_LEVELS-1, 0);
	
end Behavioral;
