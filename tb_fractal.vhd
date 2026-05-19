
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

    -- Test tracking
    signal cycle      : integer := 0;
    signal done       : boolean := false;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2 when not done else '0';

    -- DUT instantiation using default generics (INPUT_SIZE=8, N=8, PRECISIONS=49, etc.)
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
            fifo_ready => fifo_ready
        );

    -- Stimulus process
    stimulus: process
        variable seed1 : positive := 12345;
        variable seed2 : positive := 67890;
        variable rand  : real;
        variable l     : line;
    begin
        -- Hold reset for 5 cycles
        reset <= '1';
        for i in 0 to 4 loop
            wait until rising_edge(clk);
        end loop;
        reset <= '0';

        write(l, string'("=== FractalSort Simulation Start ==="));
        writeline(output, l);
        write(l, string'("INPUT_SIZE=" & integer'image(INPUT_SIZE) &
                          "  N=" & integer'image(N) &
                          "  PRECISIONS=" & integer'image(PRECISIONS) &
                          "  N_FF_LEVELS=" & integer'image(log2ceil(INPUT_SIZE))));
        writeline(output, l);

        -- Feed 500 cycles of random input data
        for i in 1 to 500 loop
            -- Advance seeds so each cycle gets a different random batch
            for b in 0 to INPUT_SIZE-1 loop
                uniform(seed1, seed2, rand);
            end loop;
            -- Generate random raw_numbers_in using generate_rand_set
            raw_numbers_in <= generate_rand_set(INPUT_SIZE, UNIFORM_DIST, seed1, seed2);

            -- Acknowledge any FIFO write request next cycle
            if fifo_wr_en = '1' or fifo_re_en = '1' then
                fifo_ready <= '1';
                fifo_din   <= fifo_dout;
                if fifo_wr_en = '1' then
                    write(l, string'("  ** RAM WRITE cycle=" & integer'image(i) &
                        "  addr=" & integer'image(to_integer(unsigned(fifo_dout(63 downto 32)))) &
                        "  data=" & integer'image(to_integer(unsigned(fifo_dout(31 downto 0))))));
                else
                    write(l, string'("  ** RAM READ  cycle=" & integer'image(i) &
                        "  addr=" & integer'image(to_integer(unsigned(fifo_dout(63 downto 32))))));
                end if;
                writeline(output, l);
            else
                fifo_ready <= '0';
                fifo_din   <= (others => '0');
            end if;

            wait until rising_edge(clk);

            -- Print every 50 cycles
            if i mod 50 = 0 then
                write(l, string'("cycle=" & integer'image(i) &
                                  "  fifo_wr=" & std_logic'image(fifo_wr_en) &
                                  "  fifo_re=" & std_logic'image(fifo_re_en) &
                                  "  count=" & integer'image(count_out)));
                writeline(output, l);
            end if;
        end loop;

        write(l, string'("=== Simulation complete after 500 cycles ==="));
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

end Behavioral;
