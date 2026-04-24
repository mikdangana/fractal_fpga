

-- clk = 100MHz:
----------------
-- Throughput (T_bits): 6 * 8 * 8 * 9 * 100MHz = 345600Mb/s = 345.6Gb/s = 43.2GB/s
-- Throughput (T_records): T_bits / 20 = 2.16G records/s

-- clk = 1LEVEL_WIDTHMHz:
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
use IEEE.Numeric_Std.ALL;


entity fractal is
    Generic ( LEVEL_SIZE : integer := INPUT_SIZE;
	           LEVEL : integer := 0;
	           LEVEL_POS : integer := 0;
				  LEVEL_WIDTH : integer := PWIDTH;
	           PRECISIONS : integer := PRECISIONS;
				  PADDING : integer := PADDING;
				  BASE_LEVEL_SIZE : integer := 1;
				  N : integer := 2 ;
				  N_FF_LEVELS : integer := log2ceil(INPUT_SIZE/1); -- log2ceil(INPUT_SIZE/BASE_LEVEL_SIZE)
				  N_BASE_LEVELS : integer := 1; --log2ceil(INPUT_SIZE/1)-1;
				  LOGN : integer := 1 );
	 Port ( clk : in std_logic;
	        reset : in std_logic;
			  --d : in std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
			  --numbers : in std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	
	        d_p : in std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
--			  numbers_p : in std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
--			  --levels_p : in std_logic_vector(N_LEVELS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_LEVELS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
--			  path : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
--			  path_mask : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
--			  bkey : inout std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
--	          bmask : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
--	          nxt_mask : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-1 downto 1 => '0');
--			  --nxt_i : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0'); --(not MyMask) and ('1' & MyMask(PRECISIONS-1 downto 1));
--              start : in integer;                                              -- Inclusive index
--			  stop : in integer;                                               -- Non-inclusive index
--			  active_level: inout integer := 0;
--			  --sorted : out std_logic_vector(LEVEL_SIZE-1 downto 0);
--			  --indices : out std_logic_vector(LEVEL_SIZE*(SIZE_PRECISION+PRECISION)-1 downto 0);
--			  --dout: inout std_logic_vector(LEVEL_SIZE-1 downto 0);
--			  --numout : inout std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
		
--			  dout_p: out std_logic_vector(LEVEL_SIZE-1 downto 0);
--			  numout_p : out std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
			  count : out integer;
	          fifo_wr_en: out std_logic;
	          fifo_re_en: out std_logic;
	          fifo_dout: out std_logic_vector(4*W_ADDR-1 downto 0);
	          fifo_din: in std_logic_vector(4*W_ADDR-1 downto 0);
	          fifo_ready: in std_logic );
end fractal;

architecture Behavioral of fractal is

	component sub_fractal is
         --Generic ( LEVEL_SIZE : integer := LEVEL_SIZE;
	     --          PRECISIONS : integer := PRECISIONS;
 		 Port ( clk : in std_logic;
 		        reset : in std_logic;
		        d_p : inout std_logic_vector;
			     numbers_p : in std_logic_vector;
			     --levels_p : in std_logic_vector;
				  path : inout std_logic_vector;
				  path_mask : inout std_logic_vector;
				  start : in integer;
				  stop : in integer;
				  
				  active_level: inout integer := 0;
				  --sorted : out std_logic_vector;
				  --indices : out std_logic_vector;
				  numout_p : out std_logic_vector;
				  --filterout: out std_logic_vector(LEVEL_SIZE-1 downto 0);
				  count : out integer;
	              fifo_wr_en: out std_logic;
	              fifo_din: out std_logic_vector(4*W_ADDR-1 downto 0) );
	end component;
		  	 
    
    signal numbers_p :  std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
			  --levels_p : in std_logic_vector(N_LEVELS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_LEVELS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	signal 		  path :  std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
	signal 		  path_mask :  std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
	signal 		  bkey :  std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	signal           bmask :  std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
	signal           nxt_mask :  std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-1 downto 1 => '0');
			  --nxt_i : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0'); --(not MyMask) and ('1' & MyMask(PRECISIONS-1 downto 1));
    signal           start :  integer;                                              -- Inclusive index
	signal 		  stop :  integer;                                               -- Non-inclusive index
	signal 		  active_level: integer := 0;
			  --sorted : out std_logic_vector(LEVEL_SIZE-1 downto 0);
			  --indices : out std_logic_vector(LEVEL_SIZE*(SIZE_PRECISION+PRECISION)-1 downto 0);
			  --dout: inout std_logic_vector(LEVEL_SIZE-1 downto 0);
			  --numout : inout std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
		
	signal 		  dout_p: std_logic_vector(LEVEL_SIZE-1 downto 0);
	signal 		  numout_p : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	          
	attribute keep : boolean;
    attribute keep of numbers_p : signal is true;
    attribute keep of numout_p : signal is true;
			  
	signal d : std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
	signal numbers : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	signal d_cnt : std_logic_vector(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => '0');
			  
	signal dout: std_logic_vector(LEVEL_SIZE-1 downto 0);
	signal numout : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	--signal levels : std_logic_vector(N_LEVELS*LEVEL_SIZE*PRECISIONS-1 downto 0);
			  
	--signal numout : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	signal			 match_0: std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
	signal          match_i_1: std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
	signal          match_i_2: std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
	signal          ready : integer := 0;
	signal          key_v0: std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0, 32));
	signal          key_v1: std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0, 32));
	signal          key_v2: std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0, 32));
	signal          key_v3: std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0, 32));
	signal          key0: integer := 0;
    signal           key1: integer := 0;
    signal           key2: integer := 0;
    signal           key3: integer := 0;
    signal         nxt_i : std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0'); --(not MyMask) and ('1' & MyMask(PRECISIONS-1 downto 1));
           
				  
	type level_inp is array(FULL_PRECISION-1 downto 0) of std_logic_vector(LEVEL_SIZE-1 downto 0);
	type level_bits is array(31 downto 0) of std_logic_vector(LEVEL_SIZE-1 downto 0);
	type level_nums is array(N_FF_LEVELS downto 0) of std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	type n_LEVEL_SIZE is array(N-1 downto 0) of std_logic_vector(LEVEL_SIZE-1 downto 0);
	type level_fbits is array(19 downto 0) of std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	type level_fbits_array is array(N-1 downto 0) of std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0);
	type level_tfbits is array(LEVEL_SIZE*PRECISIONS-1 downto 0) of std_logic_vector(LEVEL_SIZE-1 downto 0);
	type level_keys is array(LEVEL_SIZE-1 downto 0) of integer;
	type level_ints is array(FULL_PRECISION-1 downto 0) of integer;
	type level_cnts is array(N-1 downto 0) of integer;
	type level_path is array(N-1 downto 0) of std_logic_vector(PRECISIONS-1 downto 0);
	type level_pathmasks is array(PRECISIONS-1 downto 0) of std_logic_vector(PRECISIONS-1 downto 0);
	type level_keybits is array(LEVEL_SIZE-1 downto 0) of std_logic_vector(PRECISIONS-1 downto 0);
	type level_ptrs is array(N_FF_LEVELS downto 0) of std_logic_vector(LEVEL_SIZE*log2ceil(LEVEL_SIZE)-1 downto 0);
	type precision_LEVEL_SIZE is array(PRECISIONS-1 downto 0) of std_logic_vector(LEVEL_SIZE-1 downto 0);
	type LEVEL_SIZE_precision is array(LEVEL_SIZE-1 downto 0) of std_logic_vector(PRECISIONS-1 downto 0);
	type level_3d is array(PRECISIONS-1 downto 0) of precision_LEVEL_SIZE;
	type level_t3d is array(PRECISIONS-1 downto 0) of LEVEL_SIZE_precision;
	type LEVEL_SIZE_int32 is array(LEVEL_SIZE-1 downto 0) of std_logic_vector(31 downto 0); 
    type slv_inp_arr is array (natural range <>) of std_logic_vector(LEVEL_SIZE*RAW_PRECISION-1 downto 0);
	type slv_fifo_arr is array (natural range <>) of std_logic_vector(4*W_ADDR-1 downto 0);
    type count_1d_t is array (natural range <>) of integer;
	
	
	
	 --impure function clean(data : std_logic_vector) return std_logic_vector is
	 --    variable ones : std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '1');
	 --begin
		--  return not(ones or not(data));
	 --end function;
	
	alias MyInput: std_logic_vector(LEVEL_SIZE-1 downto 0) IS d;
    alias MyNumbers: std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) IS numbers; --LEVEL_SIZE*PRECISIONS-1 downto 0) IS numbers;
	alias MyPath: std_logic_vector(PRECISIONS-1 downto 0) IS path;
	alias MyMask: std_logic_vector(PRECISIONS-1 downto 0) IS path_mask;
	
    signal    fifo_wr_ens: std_logic_vector(N_FF_LEVELS downto 0) := (others => '0');
    signal    fifo_re_ens: std_logic_vector(N_FF_LEVELS downto 0) := (others => '0');
    signal    fifo_readys: std_logic_vector(N_FF_LEVELS downto 0) := (others => '0');
	signal    fifo_dins: slv_fifo_arr(N_FF_LEVELS downto 0) := (others => (others => '0'));
	signal    fifo_douts: slv_fifo_arr(N_FF_LEVELS downto 0) := (others => (others => '0'));
	signal turn: integer := 0;
	
    signal raw_numbers : slv_inp_arr(0 to RAW_PRECISION-1) := (others => (others => '0'));
	signal one : std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-2 downto 0 => '0');
	signal zero : std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	signal zero_LEVEL_SIZE : std_logic_vector(LEVEL_SIZE-1 downto 0) := (LEVEL_SIZE-1 downto 0 => '0');
	signal in_numbers : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	signal level_p : level_nums := (N_FF_LEVELS downto 0 => (INPUT_SIZE*PRECISIONS-1 downto 0 => '0'));
			  
	signal ZERO_STARTS: level_ptrs := 
	   (N_FF_LEVELS downto 0 => (LEVEL_SIZE*log2ceil(LEVEL_SIZE)-1 downto 0 => '0'));
	signal delta0: std_logic_vector(19 downto 0) := (others => '0'); 
    signal delta1: std_logic_vector(19 downto 0) := (others => '0'); 
	signal numout_s : std_logic_vector(LEVEL_SIZE*PRECISIONS-1 downto 0) := (LEVEL_SIZE*PRECISIONS-1 downto 0 => '0');
	--signal matches: level_inp := (FULL_PRECISION-1 downto 0 => (LEVEL_SIZE-1 downto 0 => '0'));
	--signal matchkeys : precision_LEVEL_SIZE := (PRECISIONS-1 downto 0 => (LEVEL_SIZE-1 downto 0 => '0'));
	--signal matchkey_i : std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	--signal mask : level_pathmasks := (PRECISIONS-1 downto 0 => (PRECISIONS-1 downto 0 => '0'));
	--signal cmask : std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	--signal match : std_logic_vector(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => '0');
	signal fifo_qhead: integer := 0;
    signal fifo_qtail: integer := 0;
    signal fifo_q : count_1d_t(0 to N_BKTS*LEVEL_SIZE) := (others => 0);
	
	--impure function equal(a : std_logic_vector; b : std_logic_vector) return std_logic is
	  --  variable av : std_logic_vector(a'length-1 downto 0) := a;
	  --  variable bv : std_logic_vector(a'length-1 downto 0) := b;
	  --  variable res : std_logic := '1';
	  --  variable i : integer := 0;
	--begin
	  --  for j in a'length/2-1 downto 0 loop
	  --      res := res and not(av(i) xor bv(i)) and not(av(i+1) xor bv(i+1));
	  --      i := i + 2;
	  --  end loop;
	  --  return res;
	--end function;
	
	 
	for all:sub_fractal use entity fractal(Behavioral); 
	
	begin
	
	
	GeneralFFCase:
	if LEVEL_SIZE > 0 generate
	   
	   level_bits:
		for i in 0 to 0 generate
		
			Levels:
			for l in 1 to N_FF_LEVELS-N_BASE_LEVELS generate
			    input_row: for lc in 1 to (RAW_PRECISION/N_FF_LEVELS)-1 generate
			         input_entry: for j in 0 to INPUT_SIZE-1 generate
			             level_p(l)(((j+1)*PRECISIONS)-1-(RAW_PRECISION/N_FF_LEVELS)+lc) <= 
			                 raw_numbers(((l-1)*(RAW_PRECISION/N_FF_LEVELS))-1+lc)
			                     (((j+1)*PRECISIONS)-1-(RAW_PRECISION/N_FF_LEVELS)+lc);
			         end generate input_entry;
			    end generate input_row;
				
				Level:
				for p in 0 to 0 generate --2**l-1 generate
									
					LevelCounterPos:
					if p = 0 generate
						selectrow:
						for i in INPUT_SIZE-1 downto 0 generate
							--d_cnt(i) <= level_p(l)(i*PRECISIONS + l);
							--d_cnt(i) <= level_p(l)(i*PRECISIONS);
							--d_p(i) <= level_p(l)(i*PRECISIONS+p);
						end generate selectrow;
						
						
						--LevelCounter:
						--if LEVEL_POS = 0 generate
						
							counterP0: 
							entity work.counter
								generic map( LEVEL_SIZE => INPUT_SIZE, N_FF_NODES => N**l, FF_LEVEL_SIZE => LEVEL_SIZE/(N**l),
								             P => (l-1)*(RAW_PRECISION/N_FF_LEVELS) ) 
							port map (clk, reset => reset, 
									  d_p => d_p, 
									  numbers_p => level_p(l), --levels_p((0+1)*PRECISIONS*INPUT_SIZE-1 downto 0*PRECISIONS*INPUT_SIZE),
									  start => 0, stop => INPUT_SIZE, starts_p => ZERO_STARTS(l),
									  --sorted_p => dout_p, --((p+1)*INPUT_SIZE-1 downto p*INPUT_SIZE),
									  --numout_p => level_p(l+1)((p+1)*INPUT_SIZE*PRECISIONS-1 downto p*INPUT_SIZE*PRECISIONS),
									  --startout_p => ZERO_STARTS(l+1),
									  --numout_p => level_p(l)((p+1)*INPUT_SIZE*PRECISIONS-1 downto p*INPUT_SIZE*PRECISIONS),
									  startout_p => ZERO_STARTS(l),
									  fifo_wr_en => fifo_wr_ens(l),
									  fifo_re_en => fifo_re_ens(l),
									  fifo_dw => fifo_douts(l),
									  fifo_dr => fifo_dins(l),
									  fifo_dready => fifo_readys(l));
	
						--end generate levelCounter;
					end generate levelCounterPos;
				
				end generate Level;
			end generate Levels;
			
			last_levels:
			for p in 0 to 2**N_BASE_LEVELS generate
			-- Standard radix update to memory
			    
			end generate last_levels;
		end generate level_bits;
		
		
	end generate GeneralFFCase;
	
	
    mem_arbiter: process(clk)
        variable next_turn : integer range 0 to N_FF_LEVELS-N_BASE_LEVELS-2;
        variable found     : boolean;
        variable qtail     : integer := fifo_qtail;
        variable qhead     : integer := fifo_qhead;
        variable level     : integer := fifo_q(qhead);
    begin
        if rising_edge(clk) then    
            if fifo_ready = '1' then
                fifo_dins(level) <= fifo_din;
                fifo_readys(level) <= fifo_ready;
                fifo_qhead <= (qhead + 1) mod (N_BKTS*LEVEL_SIZE);
            else
                fifo_wr_en <= '0';
                --req_ack    <= (others => '0');
                found      := false;
                -- Search for the next valid request starting from the CURRENT 'turn'
                -- This loop is combinational; it "jumps" to the next valid requester in 1 cycle.
                for i in 1 to N_FF_LEVELS-N_BASE_LEVELS-1 loop
                    next_turn := (turn + i) mod (N_FF_LEVELS-N_BASE_LEVELS);
                    if not found and (fifo_wr_ens(turn) = '1' or fifo_re_ens(turn) = '1') then --req_valid(next_turn) = '1' and not found then
                        -- Drive outputs
                        fifo_dout   <= fifo_douts(turn);
                        if fifo_wr_ens(turn) = '1' then
                            fifo_wr_en <= fifo_wr_ens(turn);
                        else
                            fifo_re_en <= fifo_re_ens(turn);
                        end if;
                        
                        -- Handshake
                        --req_ack(next_turn) <= '1';
                        turn <= next_turn; -- Update current position for next time
                        found := true;
                    end if;
                end loop;
            end if;
        end if;
    end process;
    
	entry_loader: process (clk, reset) 
        -- These variables stay "alive" between clock cycles
        variable seed1 : positive := 98765; 
        variable seed2 : positive := 43210; 
    begin
        if rising_edge(clk) then
            if reset = '1' then
                -- Optional: Re-seed on reset to make results repeatable
                seed1 := 98765;
                seed2 := 43210;
            else
                -- Every call to this function updates seed1 and seed2
                raw_numbers(0) <= generate_rand_set(LEVEL_SIZE, UNIFORM_DIST, seed1, seed2);
                
                -- Shifting logic...
                for i in 1 to RAW_PRECISION-1 loop
                    raw_numbers(i) <= raw_numbers(i-1);
                end loop;
            end if;
        end if;
    end process;
	

    	
		
end Behavioral;
