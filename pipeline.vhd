
library IEEE;
use IEEE.Numeric_Std.ALL;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.MATH_REAL.ALL;
--use IEEE.std_logic_textio.all;
use STD.textio.all;
USE work.reg24gen_package.ALL;


entity pipeline is
    Port ( input_ready : in STD_LOGIC := '0';
	       pipeline_clk : in std_logic := '0';
	       --numbers : inout STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	       --row : inout STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE-1 downto 0) := (N_SHARDS*INPUT_SIZE-1 downto 0 => '0');
          --path : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-1 downto 1 => '0');
          --path_mask : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-1 downto 1 => '0');
	       --bkey : inout std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	       --bmask : inout std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	       --nxt_mask : inout std_logic_vector(PRECISIONS-1 downto 0) := '1' & (PRECISIONS-1 downto 1 => '0');
	       --nxt_i : inout std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0'); --(not MyMask) and ('1' & MyMask(PRECISIONS-1 downto 1));
          -- test_results : inout std_logic_vector(N_BATCH*N_SHARDS*INPUT_SIZE-1 downto 0) := (N_BATCH*N_SHARDS*INPUT_SIZE-1 downto 0 => '0');
	       --numout : inout STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	       --ready : inout integer := 0;
	       --   match_0: inout std_logic_vector(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => '0');
	       --   match_i_1: inout std_logic_vector(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => '0');
	       --   match_i_2: inout std_logic_vector(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => '0');
	          --key: inout std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(0, 32));
	          --key0: inout integer := 0;
             -- key1: inout integer := 0;
             -- key2: inout integer := 0;
             -- key3: inout integer := 0;
             -- key4: inout integer := 0;
              --batch_cc : inout integer := 0;
	       --level : inout integer := 0;
			 --numout : out std_logic_vector(INPUT_SIZE*PRECISIONS-1 downto 0);
			 numout_p : out std_logic_vector(99 downto 0);
			 dout_p: inout std_logic_vector(99 downto 0);
	       output_ready : out STD_LOGIC := '0');
end pipeline;

architecture Behavioral of pipeline is
	component sub_pipeline is
		 Port ( Input_p: in STD_LOGIC;
	            pipeline_clk : out std_logic := '0';
				  Output_p: out STD_LOGIC);
	end component sub_pipeline;
	
    constant clock_frequency : integer := 10e6; -- 10 GHz
    constant clock_period    : time    := 1000 ms / clock_frequency;
    constant dir : string := "/home/ec2-user/project_1/";
	 --constant LARGE_SIZE : integer := 1000*1000*1000*1000; --2**52;
	 
	 --type t_bits is array(2**PRECISION-1 downto 0) of bit_vector(INPUT_SIZE-1 downto 0);
	 --type t_stds is array(2**PRECISION-1 downto 0) of std_logic_vector(INPUT_SIZE-1 downto 0);
	 --type t_trans is array(INPUT_SIZE-1 downto 0) of std_logic_vector(2**PRECISION*FULL_PRECISION-1 downto 0);
	 --type t_nums is array(2**PRECISION-1 downto 0) of std_logic_vector(INPUT_SIZE*FULL_PRECISION-1 downto 0);
	 type t_rows is array(N_SHARDS*INPUT_SIZE-1 downto 0) of std_logic_vector(PRECISIONS-1 downto 0);
	
	 
	 impure function randv(len : integer; seed : positive) return std_logic_vector is
		  variable r : real;
		  variable slv : std_logic_vector(len - 1 downto 0);
		  variable seed1, seed2 : positive := seed;
	 begin
		  for i in slv'range loop
			 uniform(seed1, seed2, r);
			 if r > 0.1 then
			     slv(i) := '1';
			 else
			     slv(i) := '0';
			 end if;
		  end loop;
		  return slv;
	 end function; 
	 
	 
    impure function load_file(index : integer) return std_logic_vector is
        constant file_name : string := dir & integer'image(index) & ".txt";
        file file_pointer : text;
        variable line_data : line;
        variable line_value : bit_vector(PRECISION-1 downto 0);
        variable ram_data : std_logic_vector(INPUT_SIZE*PRECISION-1 downto 0);
    begin
        file_open(file_pointer, file_name, read_mode);
        for line_index in 0 to INPUT_SIZE-1 loop
            readline(file_pointer, line_data);
            read(line_data, line_value);
            ram_data((line_index+1)*PRECISION-1 downto line_index*PRECISION) := to_stdlogicvector(line_value);
        end loop;
        file_close(file_pointer);
        return ram_data;
    end function;
	 
	 
    impure function write_file(index : integer;
	     ram_data : std_logic_vector(INPUT_SIZE*(SIZE_PRECISION+PRECISION)-1 downto 0)) return std_logic is
        constant file_name : string := dir & integer'image(index) & ".txt";
        file file_pointer : text;
        variable line_data : line;
        variable line_value : bit_vector((SIZE_PRECISION+PRECISION)-1 downto 0);
    begin
        file_open(file_pointer, file_name, write_mode);
        for line_index in 0 to INPUT_SIZE-1 loop
            write(line_data, to_bitvector(ram_data((line_index+1)*(SIZE_PRECISION+PRECISION)-1 downto line_index*(SIZE_PRECISION+PRECISION))));
            writeline(file_pointer, line_data);
        end loop;
        file_close(file_pointer);
		  return '1';
    end function;
	 
	 --signal numout : std_logic_vector(INPUT_SIZE*PRECISIONS-1 downto 0);
    signal dout: std_logic_vector(INPUT_SIZE-1 downto 0);
	 
	 signal numbers : STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	 signal row : STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE-1 downto 0) := (N_SHARDS*INPUT_SIZE-1 downto 0 => '0');
     signal numout : level_logics(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => (PRECISIONS-1 downto 0 => '0')); --STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	 signal level : integer := 0;
	 signal batch_cc : integer := 0;
	 signal zero : std_logic_vector(PRECISIONS-1 downto 0) := (PRECISIONS-1 downto 0 => '0');
	 signal zero_input_size : std_logic_vector(INPUT_SIZE-1 downto 0) := (INPUT_SIZE-1 downto 0 => '0');
	 signal path : std_logic_vector(PRECISIONS-1 downto 0) := zero;
	 signal path_mask : std_logic_vector(PRECISIONS-1 downto 0) := zero;
	 signal reset_hist : std_logic := '0';
	 
	 --signal histo : std_logic_vector(LARGE_SIZE-1 downto 0) := (LARGE_SIZE-1 downto 0 => '0');
	 --signal sorted_bits : STD_LOGIC_VECTOR(INPUT_SIZE-1 downto 0);
	 --signal filterout : Bit_Vector(INPUT_SIZE-1 downto 0);
    --signal fpdata : STD_LOGIC_VECTOR(INPUT_SIZE*FULL_PRECISION-1 downto 0) := (INPUT_SIZE*FULL_PRECISION-1 downto 0 => '0');
	 signal rowin : STD_LOGIC_VECTOR(N_SHARDS*INPUT_SIZE-1 downto 0) := (N_SHARDS*INPUT_SIZE-1 downto 0 => '0');
	 signal rows : t_rows := (N_SHARDS*INPUT_SIZE-1 downto 0 => (PRECISIONS-1 downto 0 => '0'));
	 --signal indices : STD_LOGIC_VECTOR(INPUT_SIZE*PRECISION-1 downto 0);
	 
	 signal all_in : std_logic_vector(N_BATCH*N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_BATCH*N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	 signal all_out : std_logic_vector(N_BATCH*N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0) := (N_BATCH*N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	 --type t_ints is array(2**PRECISION-1 downto 0) of integer;
	
	 signal interval : integer := 0;
	 signal batch : integer := 0;
	 signal n_cc_per_batch : integer := 1000;
	 signal output_ready_s : std_logic := '0';
	
	 
	 --signal histo2d : t_stds; -- := (2**PRECISION-1 downto 0 => (INPUT_SIZE-1 downto 0 => '0')); --t_nums;
	 --signal sorted2d : t_bits;
	 --signal counts : t_ints := (2**PRECISION-1 downto 0 => 0);
	 --signal keys: std_logic_vector(INPUT_SIZE*PRECISIONS-1 downto 0) := (INPUT_SIZE*PRECISIONS-1 downto 0 => '0');
	
	
begin

   --pipeline_clk <= not pipeline_clk after clock_period / 2;
	
	test_data:
	for i in N_BATCH*N_SHARDS*INPUT_SIZE-2 downto 0 generate
	     --all_in((i+1)*PRECISIONS-1 DOWNTO i*PRECISIONS) <= (PRECISIONS-1 downto 0 => '1') ;
	           --when (i*4/(N_BATCH*N_SHARDS*INPUT_SIZE) mod 2) = 0 else (PRECISIONS-1 downto 0 => '0'); --randv(PRECISIONS, i+1);
		 --test_results(i) <= '1' when to_integer(unsigned(numout((i+2)*PRECISIONS-1 DOWNTO (i+1)*PRECISIONS))) >= to_integer(unsigned(numout((i+1)*PRECISIONS-1 DOWNTO i*PRECISIONS))) else '0';
	end generate test_data;
		
	
    --histogram: 
        --entity work.fractal
          --  generic map( LEVEL_SIZE => INPUT_SIZE, PRECISIONS => PRECISIONS, PADDING => 0 )
        --port map (pipeline_clk, reset => reset_hist, d => row((0+1)*INPUT_SIZE-1 downto 0*INPUT_SIZE), 
             --numbers => numbers((0+1)*INPUT_SIZE*PRECISIONS-1 downto 0*INPUT_SIZE*PRECISIONS), 
             ----numbers1 => numbers(((s+1)*INPUT_SIZE-1)*PRECISIONS-1 downto s*INPUT_SIZE*PRECISIONS) & (PRECISIONS-1 downto 0 => '0'), 
             ----path => path, path_mask => path_mask,
             ----bkey => bkey, bmask => bmask, ready => ready, nxt_mask => nxt_mask, nxt_i => nxt_i, 
             ----match_0 => match_0, match_i_1 => match_i_1, match_i_2 => match_i_2, 
             ----key_v0 => key, key0 => key0, key1 => key1, key2 => key2, key3 => key3, key4 => key4, 
             --start => 0, stop => INPUT_SIZE, active_level => level);
		
	sort_batch:
	for s in N_SHARDS-1 downto 0 generate
		histogram: 
			entity work.fractal
				generic map( LEVEL_SIZE => INPUT_SIZE, PRECISIONS => PRECISIONS, PADDING => 0 )
			port map (pipeline_clk, reset => input_ready, 
			     --d => row((s+1)*INPUT_SIZE-1 downto s*INPUT_SIZE), 
			     --numbers => numbers((s+1)*INPUT_SIZE*PRECISIONS-1 downto s*INPUT_SIZE*PRECISIONS),
			     d_p => row((s+1)*PWIDTH-1 downto s*PWIDTH), 
			     numbers_p => numbers((s+1)*PWIDTH-1 downto s*PWIDTH), 
			     --numbers1 => numbers(((s+1)*INPUT_SIZE-1)*PRECISIONS-1 downto s*INPUT_SIZE*PRECISIONS) & (PRECISIONS-1 downto 0 => '0'), 
			     --path => path, path_mask => path_mask,
			     --bkey => bkey, bmask => bmask, ready => ready, nxt_mask => nxt_mask, nxt_i => nxt_i, 
			     --match_0 => match_0, match_i_1 => match_i_1, match_i_2 => match_i_2, 
			     --key_v0 => key, key0 => key0, key1 => key1, key2 => key2, key3 => key3, --key4 => key4, 
			     start => 0, stop => INPUT_SIZE, active_level => level,
				  dout_p => dout(PWIDTH-1 downto 0), numout_p => numout(PWIDTH-1 downto 0));
				  --dout => dout, numout => numout);
		
		
	sort_batch:
	for s in N_SHARDS-1 downto 0 generate
		selectrow:
		for i in INPUT_SIZE-1 downto 0 generate
		--	selectlevel:
		--	for l in PRECISIONS-1 downto 0 generate
		--		 rows(s*INPUT_SIZE+i)(l) <= all_in((batch*N_SHARDS + s)*INPUT_SIZE+i*PRECISIONS + l) when l = level else '0';
		--	end generate selectlevel;
		--	rowin(s*INPUT_SIZE+i) <= '0' when rows(s*INPUT_SIZE+i) = (PRECISIONS-1 downto 0 => '0') else '1';
			rowin(s*INPUT_SIZE+i) <= all_in((batch*N_SHARDS + s)*INPUT_SIZE+i*PRECISIONS + level);
		end generate selectrow;
			
		
		counter: 
		entity work.counter
			generic map( LEVEL_SIZE => INPUT_SIZE, PRECISIONS => PRECISIONS, PADDING => 0 )
		port map (pipeline_clk, reset => input_ready, d_p => rowin((s+1)*PWIDTH-1 downto s*PWIDTH), 
				  numbers_p => numbers((s+1)*PWIDTH-1 downto s*PWIDTH), 
				  start => 0, stop => INPUT_SIZE, --, sorted => row((s+1)*INPUT_SIZE-1 downto s*INPUT_SIZE), 
				  sorted_p => dout((s+1)*PWIDTH-1 downto s*PWIDTH));
				  --numout => numout((s+1)*INPUT_SIZE*PRECISIONS-1 downto s*INPUT_SIZE*PRECISIONS));
		
	end generate sort_batch;
	
   output_ready <= numout(0) or numout(1) or numout(2) or numout(3) or numout(4) or numout(5) or numout(6) or numout(7) or numout(8) or numout(9); --'0' when (dout = zero) else '1';
	--numout_p <= numout(999 downto 900) or numout(899 downto 800) or numout(799 downto 700) or numout(699 downto 600) or numout(599 downto 500) or
	--numout_p <=	numout(419 downto 400) or numout(399 downto 300) or numout(299 downto 200) or numout(199 downto 100) or numout(99 downto 0);
	
	
	SET_LEVEL: process (pipeline_clk, level) begin
		if rising_edge(pipeline_clk) then
		    if interval mod 2 = 0 then
			     interval <= 0;
				  if 2**LEVEL < N then
				      level <= level + 1;
				  end if;
			 else
			     interval <= interval + 1;
			 end if;
			 if input_ready = '1' and batch_cc mod n_cc_per_batch = 0 then
			     batch <= batch + 1;
				  numbers <= all_in((batch+1)*N_SHARDS*INPUT_SIZE*PRECISIONS-1 downto batch*N_SHARDS*INPUT_SIZE*PRECISIONS);
				  path <= '1' & (PRECISIONS-2 downto 0 => '0');
				  path_mask <= '1' & (PRECISIONS-2 downto 0 => '0');
				  reset_hist <= '1';
				  --batch_cc <= 0;
		     else 
		         reset_hist <= '0';
			 end if;
			 batch_cc <= batch_cc + 1;
	   end if;
	end process;
		
		
	--MD: temp code
	
	--histpopulate:
	--for b in INPUT_SIZE-1 downto 0 generate
	--  entryupdate:
	--  for c in 2**PRECISION-1 downto 0 generate
	--    process(numbers((b+1)*PRECISION-1 downto b*PRECISION))
	--    begin
	--      if c = to_integer(unsigned(numbers((b+1)*PRECISION-1 downto b*PRECISION))) then
	--        sorted2d(c)(b) <= '1';
	--      end if;
	--    end process;
	--  end generate entryupdate;		 
	--end generate histpopulate;
	
	
	
end Behavioral;
