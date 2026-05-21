
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;
use STD.TEXTIO.ALL;
USE work.reg24gen_package.ALL;

entity tb_fractal is
end tb_fractal;

architecture Behavioral of tb_fractal is

    -- Clock period: 10 ns = 100 MHz
    constant CLK_PERIOD : time := 10 ns;
    constant N_INPUT_CYCLES : integer := 500;

    -- DUT signals
    signal clk        : std_logic := '0';
    signal reset      : std_logic := '1';
    signal raw_numbers_in : std_logic_vector(INPUT_SIZE*RAW_PRECISION-1 downto 0) := (others => '0');
    signal count_out  : integer;
    signal fifo_wr_en : std_logic;
    signal fifo_re_en : std_logic;
    signal fifo_dout  : std_logic_vector(4*W_ADDR-1 downto 0);
    signal fifo_din   : std_logic_vector(4*W_ADDR-1 downto 0) := (others => '0');
    signal fifo_ready : std_logic := '0';

    -- Memory controller interface signals
    signal hbm_wr_en  : std_logic;
    signal hbm_dout   : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    signal hbm_ready  : std_logic := '1';
    signal hbm_wr_addr : std_logic_vector(31 downto 0);
    signal dram_wr_en : std_logic;
    signal dram_dout  : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    signal dram_ready : std_logic := '0';
    signal ssd_wr_en  : std_logic;
    signal ssd_dout   : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    signal ssd_ready  : std_logic := '0';

    -- Phase control
    signal phase1_complete : std_logic := '0';
    signal sort_complete   : std_logic;

    -- HBM read interface
    signal hbm_rd_req   : std_logic;
    signal hbm_rd_addr  : std_logic_vector(31 downto 0);
    signal hbm_rd_data  : std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0) := (others => '0');
    signal hbm_rd_valid : std_logic := '0';

    -- Test tracking
    signal cycle      : integer := 0;
    signal done       : boolean := false;
    signal hbm_wr_count : integer := 0;
    signal hbm_total_bits : integer := 0;
    signal p2_wr_count : integer := 0;

    -- Simulated HBM memory (stores Phase 1 drain, serves Phase 2 reads)
    -- Uses modular addressing (addr mod HBM_SIM_SIZE) to handle large address strides
    constant HBM_SIM_SIZE : integer := 65536;  -- large enough for testing
    type hbm_mem_t is array (0 to HBM_SIM_SIZE-1) of std_logic_vector(BIN_ENTRY_WIDTH-1 downto 0);
    signal hbm_mem : hbm_mem_t := (others => (others => '0'));

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2 when not done else '0';

    -- DUT instantiation
    DUT: entity work.fractal
        generic map(
            LEVEL_SIZE     => INPUT_SIZE,
            LEVEL          => 0,
            LEVEL_POS      => 0,
            LEVEL_WIDTH    => PWIDTH,
            PRECISIONS     => PRECISIONS,
            PADDING        => PADDING,
            BASE_LEVEL_SIZE => 1,
            N              => N,
            N_FF_LEVELS    => log2ceil(INPUT_SIZE),
            N_BASE_LEVELS  => 1,
            LOGN           => LOGN
        )
        port map(
            clk        => clk,
            reset      => reset,
            raw_numbers_in => raw_numbers_in,
            count          => count_out,
            fifo_wr_en => fifo_wr_en,
            fifo_re_en => fifo_re_en,
            fifo_dout  => fifo_dout,
            fifo_din   => fifo_din,
            fifo_ready => fifo_ready,
            hbm_wr_en  => hbm_wr_en,
            hbm_dout   => hbm_dout,
            hbm_ready  => hbm_ready,
            hbm_wr_addr => hbm_wr_addr,
            dram_wr_en => dram_wr_en,
            dram_dout  => dram_dout,
            dram_ready => dram_ready,
            ssd_wr_en  => ssd_wr_en,
            ssd_dout   => ssd_dout,
            ssd_ready  => ssd_ready,
            phase1_complete => phase1_complete,
            sort_complete   => sort_complete,
            hbm_rd_req  => hbm_rd_req,
            hbm_rd_addr => hbm_rd_addr,
            hbm_rd_data => hbm_rd_data,
            hbm_rd_valid => hbm_rd_valid
        );

    -- Stimulus process
    stimulus: process
        variable seed1 : positive := 12345;
        variable seed2 : positive := 67890;
        variable rand  : real;
        variable l     : line;
        variable p2_wait : integer := 0;
    begin
        -- Hold reset for 5 cycles
        reset <= '1';
        for i in 0 to 4 loop
            wait until rising_edge(clk);
        end loop;
        reset <= '0';

        write(l, string'("=== FractalSort Phase 1+2 Simulation Start ==="));
        writeline(output, l);
        write(l, string'("INPUT_SIZE=" & integer'image(INPUT_SIZE) &
                          "  N=" & integer'image(N) &
                          "  PRECISIONS=" & integer'image(PRECISIONS) &
                          "  N_BINS=" & integer'image(N_BINS) &
                          "  PIPELINE_LATENCY=" & integer'image(PIPELINE_LATENCY)));
        writeline(output, l);

        -- === PHASE 1: Feed input data ===
        for i in 1 to N_INPUT_CYCLES loop
            for b in 0 to INPUT_SIZE-1 loop
                uniform(seed1, seed2, rand);
            end loop;
            raw_numbers_in <= generate_rand_set(INPUT_SIZE, UNIFORM_DIST, seed1, seed2);

            if fifo_wr_en = '1' or fifo_re_en = '1' then
                fifo_ready <= '1';
                fifo_din   <= fifo_dout;
            else
                fifo_ready <= '0';
                fifo_din   <= (others => '0');
            end if;

            wait until rising_edge(clk);

            if i mod 1000 = 0 then
                write(l, string'("[P1] cycle=" & integer'image(i) &
                                  "  hbm_writes=" & integer'image(hbm_wr_count) &
                                  "  count=" & integer'image(count_out)));
                writeline(output, l);
            end if;
        end loop;

        -- Signal Phase 1 complete
        write(l, string'("=== Phase 1 input complete. Starting flush... ==="));
        writeline(output, l);
        write(l, string'("Phase 1 HBM writes: " & integer'image(hbm_wr_count)));
        writeline(output, l);
        phase1_complete <= '1';

        -- Wait for flush + Phase 2 to complete (or timeout)
        p2_wait := 0;
        while sort_complete /= '1' and p2_wait < 50000 loop
            wait until rising_edge(clk);
            p2_wait := p2_wait + 1;
            if p2_wait mod 5000 = 0 then
                write(l, string'("[WAIT] cycle=" & integer'image(p2_wait) &
                                  "  sort_complete=" & std_logic'image(sort_complete) &
                                  "  total_hbm_wr=" & integer'image(hbm_wr_count) &
                                  "  p2_wr=" & integer'image(p2_wr_count)));
                writeline(output, l);
            end if;
        end loop;

        write(l, string'("=== Simulation Complete ==="));
        writeline(output, l);
        write(l, string'("Total cycles: " & integer'image(N_INPUT_CYCLES + p2_wait)));
        writeline(output, l);
        write(l, string'("Phase 1 + flush HBM writes: " & integer'image(hbm_wr_count - p2_wr_count)));
        writeline(output, l);
        write(l, string'("Phase 2 sorted writes: " & integer'image(p2_wr_count)));
        writeline(output, l);
        write(l, string'("Total HBM writes: " & integer'image(hbm_wr_count)));
        writeline(output, l);
        if hbm_wr_count > 0 then
            write(l, string'("Total HBM bits: " & integer'image(hbm_total_bits)));
            writeline(output, l);
        end if;
        if sort_complete = '1' then
            write(l, string'("Phase 2 COMPLETED successfully"));
        else
            write(l, string'("Phase 2 TIMEOUT after " & integer'image(p2_wait) & " cycles"));
        end if;
        writeline(output, l);

        done <= true;
        wait;
    end process;

    -- Cycle counter
    cycle_cnt: process(clk)
    begin
        if rising_edge(clk) then
            cycle <= cycle + 1;
        end if;
    end process;

    -- HBM write monitor + simulated memory store
    hbm_monitor: process(clk)
        variable l : line;
        variable addr : integer;
    begin
        if rising_edge(clk) then
            if hbm_wr_en = '1' then
                hbm_wr_count <= hbm_wr_count + 1;
                hbm_total_bits <= hbm_total_bits + BIN_ENTRY_WIDTH;
                -- Store in simulated HBM memory (modular addressing)
                addr := to_integer(unsigned(hbm_wr_addr)) mod HBM_SIM_SIZE;
                hbm_mem(addr) <= hbm_dout;
                -- Track Phase 2 writes (addresses >= N_BINS * MAX_BIN_ENTRIES)
                if to_integer(unsigned(hbm_wr_addr)) >= N_BINS * MAX_BIN_ENTRIES then
                    p2_wr_count <= p2_wr_count + 1;
                end if;
                -- Log first 20 and then every 200th
                if hbm_wr_count < 20 or hbm_wr_count mod 200 = 0 then
                    write(l, string'("  [HBM] cycle=" & integer'image(cycle) &
                        "  wr#=" & integer'image(hbm_wr_count + 1) &
                        "  addr=" & integer'image(addr) &
                        "  data=" & integer'image(to_integer(unsigned(hbm_dout)))));
                    writeline(output, l);
                end if;
            end if;
        end if;
    end process;

    -- HBM read responder: 1-cycle latency read from simulated memory
    hbm_read_resp: process(clk)
        variable addr : integer;
        variable l : line;
    begin
        if rising_edge(clk) then
            hbm_rd_valid <= '0';
            if hbm_rd_req = '1' then
                addr := to_integer(unsigned(hbm_rd_addr)) mod HBM_SIM_SIZE;
                hbm_rd_data <= hbm_mem(addr);
                hbm_rd_valid <= '1';
            end if;
        end if;
    end process;

end Behavioral;
