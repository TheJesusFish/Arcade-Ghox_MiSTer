--------------------------------------------------------------------------------
-- Ghox-owned HD647180X subset wrapper.
--
-- This combines the local BSD T80 derivative with the exact HD647180X reset
-- image, Z180 16-to-20-bit MMU, the internal registers exercised by Ghox, and
-- the MCU's remappable 512-byte RAM.  Semantics are pinned to MAME 0.288; see
-- docs/HD647180_PROOF.md.  The upstream JTFrame T80 files remain unmodified.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ghox_hd647180 is
	port(
		clk_i       : in  std_logic;
		cen_i       : in  std_logic := '1';
		reset_n_i   : in  std_logic;
		wait_n_i    : in  std_logic := '1';
		int_n_i     : in  std_logic := '1';
		nmi_n_i     : in  std_logic := '1';
		busrq_n_i   : in  std_logic := '1';

		physical_a_o: out std_logic_vector(19 downto 0);
		logical_a_o : out std_logic_vector(15 downto 0);
		data_i      : in  std_logic_vector(7 downto 0);
		data_o      : out std_logic_vector(7 downto 0);
		mreq_n_o    : out std_logic;
		iorq_n_o    : out std_logic;
		rd_n_o      : out std_logic;
		wr_n_o      : out std_logic;
		m1_n_o      : out std_logic;
		rfsh_n_o    : out std_logic;
		halt_n_o    : out std_logic;
		busak_n_o   : out std_logic;

		-- Parallel-port pins. A-F occupy bytes 0-5; G is input-only byte 6.
		port_i_i    : in  std_logic_vector(55 downto 0) := (others => '1');
		port_o_o    : out std_logic_vector(47 downto 0);
		port_oe_o   : out std_logic_vector(47 downto 0);

		-- Save-state scan. The CPU image is T80's documented 212-bit layout.
		state_load_i: in  std_logic := '0';
		cpu_state_i : in  std_logic_vector(211 downto 0) := (others => '0');
		cpu_state_o : out std_logic_vector(211 downto 0);
		periph_state_i : in  std_logic_vector(319 downto 0) := (others => '0');
		periph_state_o : out std_logic_vector(319 downto 0);
		ram_scan_a_i   : in  std_logic_vector(8 downto 0) := (others => '0');
		ram_scan_data_o: out std_logic_vector(7 downto 0);
		ram_scan_we_i  : in  std_logic := '0';
		ram_scan_data_i: in  std_logic_vector(7 downto 0) := (others => '0');

		-- Deterministic proof/debug landmarks; not part of the arcade bus.
		otim_o          : out std_logic;
		io_write_pulse_o: out std_logic;
		io_port_o       : out std_logic_vector(7 downto 0);
		cbr_o           : out std_logic_vector(7 downto 0);
		bbr_o           : out std_logic_vector(7 downto 0);
		cbar_o          : out std_logic_vector(7 downto 0)
	);
end entity;

architecture rtl of ghox_hd647180 is
	type ram_t is array (0 to 511) of std_logic_vector(7 downto 0);
	type bytes6_t is array (0 to 5) of std_logic_vector(7 downto 0);

	function reset_cpu_image return std_logic_vector is
		variable result : std_logic_vector(211 downto 0) := (others => '0');
	begin
		result(15 downto 8) := x"40";       -- F: Z set
		result(143 downto 128) := x"FFFF";  -- IX
		result(207 downto 192) := x"FFFF";  -- IY
		return result;
	end function;

	function translate_address(
		logical : std_logic_vector(15 downto 0);
		cbr     : std_logic_vector(7 downto 0);
		bbr     : std_logic_vector(7 downto 0);
		cbar    : std_logic_vector(7 downto 0)
	) return std_logic_vector is
		variable result      : unsigned(19 downto 0);
		variable page        : unsigned(3 downto 0);
		variable bank_base   : unsigned(3 downto 0);
		variable common_base : unsigned(3 downto 0);
	begin
		result := resize(unsigned(logical), result'length);
		page := unsigned(logical(15 downto 12));
		bank_base := unsigned(cbar(3 downto 0));
		common_base := unsigned(cbar(7 downto 4));
		if page >= bank_base then
			if page >= common_base then
				result := result + shift_left(resize(unsigned(cbr), 20), 12);
			else
				result := result + shift_left(resize(unsigned(bbr), 20), 12);
			end if;
		end if;
		return std_logic_vector(result);
	end function;

	constant RESET_CPU : std_logic_vector(211 downto 0) := reset_cpu_image;

	signal cpu_a          : std_logic_vector(15 downto 0);
	signal cpu_dout       : std_logic_vector(7 downto 0);
	signal cpu_regs       : std_logic_vector(211 downto 0);
	signal cpu_di_reg     : std_logic_vector(7 downto 0) := x"00";
	signal cpu_read_mux   : std_logic_vector(7 downto 0);
	signal cpu_m1_n       : std_logic;
	signal cpu_iorq       : std_logic;
	signal cpu_noread     : std_logic;
	signal cpu_write      : std_logic;
	signal cpu_rfsh_n     : std_logic;
	signal cpu_halt_n     : std_logic;
	signal cpu_busak_n    : std_logic;
	signal cpu_mc         : std_logic_vector(2 downto 0);
	signal cpu_ts         : std_logic_vector(2 downto 0);
	signal cpu_intcycle_n : std_logic;
	signal cpu_inte       : std_logic;
	signal cpu_stop       : std_logic;
	signal cpu_otim       : std_logic;
	signal cpu_dir_set    : std_logic;
	signal cpu_dir        : std_logic_vector(211 downto 0);
	signal cpu_cen        : std_logic;
	signal cpu_wait_n     : std_logic;
	signal boot_load      : std_logic := '1';

	signal physical_a     : std_logic_vector(19 downto 0);
	signal internal_io    : std_logic;
	signal internal_ram   : std_logic;
	signal internal_read  : std_logic_vector(7 downto 0);
	signal ram            : ram_t := (others => (others => '0'));
	signal write_qual     : std_logic;
	signal write_seen     : std_logic := '0';

	signal cbr            : std_logic_vector(7 downto 0) := x"00";
	signal bbr            : std_logic_vector(7 downto 0) := x"00";
	signal cbar           : std_logic_vector(7 downto 0) := x"F0";
	signal iocr           : std_logic_vector(7 downto 0) := x"00";
	signal dcntl          : std_logic_vector(7 downto 0) := x"F0";
	signal rcr            : std_logic_vector(7 downto 0) := x"C0";
	signal rmcr           : std_logic_vector(7 downto 0) := x"00";
	signal dera           : std_logic_vector(7 downto 0) := x"00";
	signal ccsr           : std_logic_vector(7 downto 0) := x"2C";
	signal t2csr1         : std_logic_vector(7 downto 0) := x"00";
	signal t2csr2         : std_logic_vector(7 downto 0) := x"00";
	signal t2frc          : std_logic_vector(15 downto 0) := x"0000";
	signal t2ocr1         : std_logic_vector(15 downto 0) := x"FFFF";
	signal t2ocr2         : std_logic_vector(15 downto 0) := x"FFFF";
	signal t2icr          : std_logic_vector(15 downto 0) := x"0000";
	signal ddr            : bytes6_t := (others => x"00");
	signal odr            : bytes6_t := (others => x"00");
	signal itc            : std_logic_vector(7 downto 0) := x"01";
	signal omcr           : std_logic_vector(7 downto 0) := x"E0";
	signal il             : std_logic_vector(7 downto 0) := x"00";
	signal tcr            : std_logic_vector(7 downto 0) := x"00";
	signal frc            : std_logic_vector(7 downto 0) := x"FF";
	signal dstat          : std_logic_vector(7 downto 0) := x"30";
	signal dmode          : std_logic_vector(7 downto 0) := x"00";
	signal frc_prescale   : unsigned(3 downto 0) := (others => '0');
begin
	physical_a <= translate_address(cpu_a, cbr, bbr, cbar);
	physical_a_o <= physical_a;
	logical_a_o <= cpu_a;
	data_o <= cpu_dout;
	m1_n_o <= cpu_m1_n;
	rfsh_n_o <= cpu_rfsh_n;
	halt_n_o <= cpu_halt_n;
	busak_n_o <= cpu_busak_n;
	cpu_state_o <= cpu_regs;
	otim_o <= cpu_otim;
	cbr_o <= cbr;
	bbr_o <= bbr;
	cbar_o <= cbar;
	ram_scan_data_o <= ram(to_integer(unsigned(ram_scan_a_i)));

	-- HD647180X uses the extended 128-byte internal I/O window.
	internal_io <= '1' when cpu_a(7) = iocr(7) and cpu_iorq = '1' and
		(cpu_a(15 downto 8) = x"00" or cpu_otim = '1') else '0';
	internal_ram <= '1' when physical_a(19 downto 16) = rmcr(7 downto 4) and
		unsigned(physical_a(15 downto 0)) >= x"FE00" and cpu_iorq = '0'
		else '0';
	cpu_wait_n <= '1' when internal_io = '1' or internal_ram = '1'
		else wait_n_i;
	cpu_cen <= cen_i and not boot_load and not state_load_i;
	cpu_dir_set <= boot_load or state_load_i;
	cpu_dir <= cpu_state_i when state_load_i = '1' else RESET_CPU;
	write_qual <= '1' when cpu_mc /= "001" and cpu_write = '1' and
		cpu_ts = "010" and cpu_wait_n = '1' else '0';

	cpu_read_mux <= internal_read when internal_io = '1' else
		ram(to_integer(unsigned(physical_a(8 downto 0))))
			when internal_ram = '1' else
		data_i;

	cpu : entity work.T80
		generic map(
			Mode => 0,
			IOWait => 1
		)
		port map(
			RESET_n => reset_n_i,
			CLK_n => clk_i,
			CEN => cpu_cen,
			WAIT_n => cpu_wait_n,
			INT_n => int_n_i,
			NMI_n => nmi_n_i,
			BUSRQ_n => busrq_n_i,
			M1_n => cpu_m1_n,
			IORQ => cpu_iorq,
			NoRead => cpu_noread,
			Write => cpu_write,
			RFSH_n => cpu_rfsh_n,
			HALT_n => cpu_halt_n,
			BUSAK_n => cpu_busak_n,
			A => cpu_a,
			DInst => cpu_read_mux,
			DI => cpu_di_reg,
			DOUT => cpu_dout,
			MC => cpu_mc,
			TS => cpu_ts,
			IntCycle_n => cpu_intcycle_n,
			IntE => cpu_inte,
			Stop => cpu_stop,
			Z180OTIM_o => cpu_otim,
			out0 => '0',
			REGS => cpu_regs,
			DIRSet => cpu_dir_set,
			DIR => cpu_dir
		);

	-- MAME-pinned internal I/O read values needed by the MCU subset.
	io_read : process(all)
		variable value : std_logic_vector(7 downto 0);
		variable index : integer range 0 to 6;
	begin
		value := x"FF";
		case cpu_a(6 downto 0) is
			when "0010000" => value := tcr;
			when "0011000" => value := frc;
			when "0110000" => value := dstat or x"02";
			when "0110001" => value := dmode or x"C1";
			when "0110010" => value := dcntl;
			when "0110011" => value := il and x"E0";
			when "0110100" => value := itc or x"38";
			when "0110110" => value := rcr or x"3C";
			when "0111000" => value := cbr;
			when "0111001" => value := bbr;
			when "0111010" => value := cbar;
			when "0111110" => value := omcr or x"3F";
			when "0111111" => value := iocr or x"5F";
			when "1000000" => value := t2frc(7 downto 0);
			when "1000001" => value := t2frc(15 downto 8);
			when "1000010" => value := t2ocr1(7 downto 0);
			when "1000011" => value := t2ocr1(15 downto 8);
			when "1000100" => value := t2ocr2(7 downto 0);
			when "1000101" => value := t2ocr2(15 downto 8);
			when "1000110" => value := t2icr(7 downto 0);
			when "1000111" => value := t2icr(15 downto 8);
			when "1001000" => value := t2csr1;
			when "1001001" => value := t2csr2 or x"10";
			when "1010000" => value := ccsr or x"40";
			when "1010001" => value := rmcr or x"0F";
			when "1010011" => value := dera;
			when "1100000" | "1100001" | "1100010" | "1100101" =>
				index := to_integer(unsigned(cpu_a(2 downto 0)));
				value := (odr(index) and ddr(index)) or
					(port_i_i(index * 8 + 7 downto index * 8) and not ddr(index));
			when "1100011" =>
				value := ddr(3) or (port_i_i(31 downto 24) and not ddr(3));
			when "1100100" =>
				value := ((odr(4) or x"0F") and ddr(4)) or
					(port_i_i(39 downto 32) and not ddr(4));
			when "1100110" =>
				value := x"C0";
				value(5 downto 0) := port_i_i(53 downto 48);
			when others => null;
		end case;
		internal_read <= value;
	end process;

	port_pins : process(all)
	begin
		for index in 0 to 5 loop
			port_o_o(index * 8 + 7 downto index * 8) <= odr(index);
			port_oe_o(index * 8 + 7 downto index * 8) <= ddr(index);
		end loop;
	end process;

	state_pack : process(all)
		variable value : std_logic_vector(319 downto 0);
	begin
		value := (others => '0');
		value(7 downto 0) := cbr;
		value(15 downto 8) := bbr;
		value(23 downto 16) := cbar;
		value(31 downto 24) := iocr;
		value(39 downto 32) := dcntl;
		value(47 downto 40) := rcr;
		value(55 downto 48) := rmcr;
		value(63 downto 56) := dera;
		value(71 downto 64) := ccsr;
		value(79 downto 72) := t2csr1;
		value(87 downto 80) := t2csr2;
		value(103 downto 88) := t2frc;
		value(119 downto 104) := t2ocr1;
		value(135 downto 120) := t2ocr2;
		value(151 downto 136) := t2icr;
		for index in 0 to 5 loop
			value(159 + index * 8 downto 152 + index * 8) := ddr(index);
			value(207 + index * 8 downto 200 + index * 8) := odr(index);
		end loop;
		value(255 downto 248) := itc;
		value(263 downto 256) := omcr;
		value(271 downto 264) := il;
		value(279 downto 272) := tcr;
		value(287 downto 280) := frc;
		value(295 downto 288) := dstat;
		value(303 downto 296) := dmode;
		value(307 downto 304) := std_logic_vector(frc_prescale);
		periph_state_o <= value;
	end process;

	registers : process(reset_n_i, clk_i)
		variable port_index : integer range 0 to 5;
	begin
		if reset_n_i = '0' then
			boot_load <= '1';
			write_seen <= '0';
			io_write_pulse_o <= '0';
			io_port_o <= x"00";
			cbr <= x"00";
			bbr <= x"00";
			cbar <= x"F0";
			iocr <= x"00";
			dcntl <= x"F0";
			rcr <= x"C0";
			rmcr <= x"00";
			dera <= x"00";
			ccsr <= x"2C";
			t2csr1 <= x"00";
			t2csr2 <= x"00";
			t2frc <= x"0000";
			t2ocr1 <= x"FFFF";
			t2ocr2 <= x"FFFF";
			t2icr <= x"0000";
			ddr <= (others => x"00");
			odr <= (others => x"00");
			itc <= x"01";
			omcr <= x"E0";
			il <= x"00";
			tcr <= x"00";
			frc <= x"FF";
			dstat <= x"30";
			dmode <= x"00";
			frc_prescale <= (others => '0');
		elsif rising_edge(clk_i) then
			io_write_pulse_o <= '0';
			if boot_load = '1' then
				boot_load <= '0';
			end if;

			if state_load_i = '1' then
				cbr <= periph_state_i(7 downto 0);
				bbr <= periph_state_i(15 downto 8);
				cbar <= periph_state_i(23 downto 16);
				iocr <= periph_state_i(31 downto 24);
				dcntl <= periph_state_i(39 downto 32);
				rcr <= periph_state_i(47 downto 40);
				rmcr <= periph_state_i(55 downto 48);
				dera <= periph_state_i(63 downto 56);
				ccsr <= periph_state_i(71 downto 64);
				t2csr1 <= periph_state_i(79 downto 72);
				t2csr2 <= periph_state_i(87 downto 80);
				t2frc <= periph_state_i(103 downto 88);
				t2ocr1 <= periph_state_i(119 downto 104);
				t2ocr2 <= periph_state_i(135 downto 120);
				t2icr <= periph_state_i(151 downto 136);
				for index in 0 to 5 loop
					ddr(index) <= periph_state_i(
						159 + index * 8 downto 152 + index * 8);
					odr(index) <= periph_state_i(
						207 + index * 8 downto 200 + index * 8);
				end loop;
				itc <= periph_state_i(255 downto 248);
				omcr <= periph_state_i(263 downto 256);
				il <= periph_state_i(271 downto 264);
				tcr <= periph_state_i(279 downto 272);
				frc <= periph_state_i(287 downto 280);
				dstat <= periph_state_i(295 downto 288);
				dmode <= periph_state_i(303 downto 296);
				frc_prescale <= unsigned(periph_state_i(307 downto 304));
				write_seen <= '0';
			elsif cpu_cen = '1' then
				if frc_prescale = 9 then
					frc_prescale <= (others => '0');
					frc <= std_logic_vector(unsigned(frc) - 1);
				else
					frc_prescale <= frc_prescale + 1;
				end if;

				if write_qual = '0' then
					write_seen <= '0';
				elsif write_seen = '0' then
					write_seen <= '1';
					if internal_io = '1' then
						io_write_pulse_o <= '1';
						io_port_o <= cpu_a(7 downto 0);
						case cpu_a(6 downto 0) is
							when "0010000" =>
								tcr <= (tcr and x"C0") or (cpu_dout and x"3F");
							when "0110000" =>
								dstat <= (dstat and x"80") or
									(cpu_dout and x"7D");
							when "0110001" => dmode <= cpu_dout and x"3E";
							when "0110010" => dcntl <= cpu_dout;
							when "0110011" => il <= cpu_dout and x"E0";
							when "0110100" =>
								itc <= (itc and x"40") or (cpu_dout and x"87");
							when "0110110" => rcr <= cpu_dout and x"C3";
							when "0111000" => cbr <= cpu_dout;
							when "0111001" => bbr <= cpu_dout;
							when "0111010" => cbar <= cpu_dout;
							when "0111110" => omcr <= cpu_dout and x"E0";
							when "0111111" => iocr <= cpu_dout and x"A0";
							when "1000000" => t2frc(7 downto 0) <= cpu_dout;
							when "1000001" => t2frc(15 downto 8) <= cpu_dout;
							when "1000010" => t2ocr1(7 downto 0) <= cpu_dout;
							when "1000011" => t2ocr1(15 downto 8) <= cpu_dout;
							when "1000100" => t2ocr2(7 downto 0) <= cpu_dout;
							when "1000101" => t2ocr2(15 downto 8) <= cpu_dout;
							when "1001000" => t2csr1 <= cpu_dout;
							when "1001001" => t2csr2 <= cpu_dout and x"EF";
							when "1010000" =>
								ccsr <= (ccsr and x"80") or (cpu_dout and x"3F");
							when "1010001" => rmcr <= cpu_dout and x"F0";
							when "1010011" => dera <= cpu_dout;
							when "1100000" | "1100001" | "1100010" |
								"1100011" | "1100100" | "1100101" =>
								port_index := to_integer(unsigned(cpu_a(2 downto 0)));
								odr(port_index) <= cpu_dout;
							when "1110000" | "1110001" | "1110010" |
								"1110011" | "1110100" | "1110101" =>
								port_index := to_integer(unsigned(cpu_a(2 downto 0)));
								ddr(port_index) <= cpu_dout;
							when others => null;
						end case;
					elsif internal_ram = '1' then
						ram(to_integer(unsigned(physical_a(8 downto 0)))) <= cpu_dout;
					end if;
				end if;
			end if;

			if ram_scan_we_i = '1' then
				ram(to_integer(unsigned(ram_scan_a_i))) <= ram_scan_data_i;
			end if;
		end if;
	end process;

	bus_control : process(reset_n_i, clk_i)
	begin
		if reset_n_i = '0' then
			rd_n_o <= '1';
			wr_n_o <= '1';
			iorq_n_o <= '1';
			mreq_n_o <= '1';
			cpu_di_reg <= x"00";
		elsif rising_edge(clk_i) then
			if cpu_cen = '1' then
				rd_n_o <= '1';
				wr_n_o <= '1';
				iorq_n_o <= '1';
				mreq_n_o <= '1';
				if cpu_mc = "001" then
					if cpu_ts = "001" or
						(cpu_ts = "010" and cpu_wait_n = '0') then
						if internal_io = '0' and internal_ram = '0' then
							rd_n_o <= not cpu_intcycle_n;
							mreq_n_o <= not cpu_intcycle_n;
							iorq_n_o <= cpu_intcycle_n;
						end if;
					end if;
					if cpu_ts = "011" and internal_ram = '0' then
						mreq_n_o <= '0';
					end if;
				else
					if (cpu_ts = "001" or
						(cpu_ts = "010" and cpu_wait_n = '0')) and
						cpu_noread = '0' and cpu_write = '0' and
						internal_io = '0' and internal_ram = '0' then
						rd_n_o <= '0';
						iorq_n_o <= not cpu_iorq;
						mreq_n_o <= cpu_iorq;
					end if;
					if (cpu_ts = "001" or
						(cpu_ts = "010" and cpu_wait_n = '0')) and
						cpu_write = '1' and internal_io = '0' and
						internal_ram = '0' then
						wr_n_o <= '0';
						iorq_n_o <= not cpu_iorq;
						mreq_n_o <= cpu_iorq;
					end if;
				end if;
				if cpu_ts = "010" and cpu_wait_n = '1' then
					cpu_di_reg <= cpu_read_mux;
				end if;
			end if;
		end if;
	end process;
end architecture;
