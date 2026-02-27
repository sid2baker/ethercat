defmodule EtherCAT.Slave.Registers do
  @moduledoc """
  EtherCAT Slave Controller (ESC) register map.

  All fixed-size registers are returned as `{address, size}` tuples so call
  sites never need to hard-code a size separately:

      {addr, size} = Registers.al_status()
      Link.transaction(link, &Transaction.fprd(&1, station, addr, size))

  Registers whose size is determined at runtime return a bare address integer.
  Array-indexed registers (SyncManager, FMMU) provide a base-offset function
  plus named subfield accessors for individual fields within each channel.

  References: Beckhoff ETG slave controller datasheet, section II (register description).
  """

  @type reg :: {non_neg_integer(), pos_integer()}

  # -- ESC Information (§2.1) -----------------------------------------------

  @spec esc_type() :: reg()
  def esc_type, do: {0x0000, 1}

  @spec esc_revision() :: reg()
  def esc_revision, do: {0x0001, 1}

  @spec esc_build() :: reg()
  def esc_build, do: {0x0002, 2}

  @spec fmmu_count() :: reg()
  def fmmu_count, do: {0x0004, 1}

  @spec sm_count() :: reg()
  def sm_count, do: {0x0005, 1}

  @spec ram_size() :: reg()
  def ram_size, do: {0x0006, 1}

  @spec port_descriptor() :: reg()
  def port_descriptor, do: {0x0007, 1}

  # -- Station address (§2.2) -----------------------------------------------

  @spec station_address() :: reg()
  def station_address, do: {0x0010, 2}

  @spec station_alias() :: reg()
  def station_alias, do: {0x0012, 2}

  # -- Data link layer (§2.4) -----------------------------------------------

  @spec dl_control() :: reg()
  def dl_control, do: {0x0100, 4}

  @spec dl_status() :: reg()
  def dl_status, do: {0x0110, 2}

  # -- Application layer / AL control+status (§2.5) -------------------------

  @spec al_control() :: reg()
  def al_control, do: {0x0120, 2}

  @spec al_status() :: reg()
  def al_status, do: {0x0130, 2}

  @spec al_status_code() :: reg()
  def al_status_code, do: {0x0134, 2}

  # -- Interrupts / AL event (§2.8) -----------------------------------------

  @spec al_event_mask() :: reg()
  def al_event_mask, do: {0x0204, 4}

  @spec al_event_req() :: reg()
  def al_event_req, do: {0x0220, 4}

  # -- Error counters (§2.9) ------------------------------------------------

  @spec rx_error_counter() :: reg()
  def rx_error_counter, do: {0x0300, 8}

  @spec fwd_rx_error_counter() :: reg()
  def fwd_rx_error_counter, do: {0x0308, 4}

  @spec epu_error_counter() :: reg()
  def epu_error_counter, do: {0x030C, 1}

  @spec pdi_error_counter() :: reg()
  def pdi_error_counter, do: {0x030D, 1}

  @spec lost_link_counter() :: reg()
  def lost_link_counter, do: {0x0310, 4}

  # -- Watchdog (§2.10) -----------------------------------------------------

  @spec wdt_divider() :: reg()
  def wdt_divider, do: {0x0400, 2}

  @spec wdt_pdi() :: reg()
  def wdt_pdi, do: {0x0410, 2}

  @spec wdt_sm() :: reg()
  def wdt_sm, do: {0x0420, 2}

  @spec wdt_status() :: reg()
  def wdt_status, do: {0x0440, 2}

  # -- SII EEPROM interface (§2.11) -----------------------------------------

  @spec eeprom_ecat_access() :: reg()
  def eeprom_ecat_access, do: {0x0500, 1}

  @spec eeprom_pdi_access() :: reg()
  def eeprom_pdi_access, do: {0x0501, 1}

  @spec eeprom_control() :: reg()
  def eeprom_control, do: {0x0502, 2}

  @spec eeprom_address() :: reg()
  def eeprom_address, do: {0x0504, 4}

  # Size is runtime-determined: 4 bytes (bit 6 = 0) or 8 bytes (bit 6 = 1)
  # in the EEPROM control/status register. Returns a bare address.
  @spec eeprom_data() :: non_neg_integer()
  def eeprom_data, do: 0x0508

  # -- Process data RAM (§2.19) ---------------------------------------------

  # Bare address — size equals the full process image, known only at runtime.
  @spec pd_ram() :: non_neg_integer()
  def pd_ram, do: 0x1000

  # -- SyncManager array (§2.14) — 8 bytes per channel, base 0x0800 ---------

  @doc "Base byte offset for SyncManager channel `index` (0-based)."
  @spec sm(non_neg_integer()) :: non_neg_integer()
  def sm(index), do: 0x0800 + index * 8

  @doc "Physical start address field of SM `index`. Write the RAM address where the SM buffer begins."
  @spec sm_start(non_neg_integer()) :: reg()
  def sm_start(i), do: {sm(i) + 0, 2}

  @doc "Length field of SM `index` (buffer size in bytes)."
  @spec sm_length(non_neg_integer()) :: reg()
  def sm_length(i), do: {sm(i) + 2, 2}

  @doc """
  Control register of SM `index`.

  Bit layout:
    [1:0] mode      — 0b00=buffered (3-buffer), 0b10=mailbox
    [3:2] direction — 0b00=ECAT reads/PDI writes, 0b01=ECAT writes/PDI reads
    [4]   ECAT interrupt enable
    [5]   AL event interrupt enable
    [6]   watchdog trigger enable
    [7]   sequential mode
  """
  @spec sm_control(non_neg_integer()) :: reg()
  def sm_control(i), do: {sm(i) + 4, 1}

  @doc "Status register of SM `index` (read-only). Bit [3]=mailbox full, [5:4]=last buffer."
  @spec sm_status(non_neg_integer()) :: reg()
  def sm_status(i), do: {sm(i) + 5, 1}

  @doc "Activate register of SM `index`. Bit [0]=1 enables the SyncManager."
  @spec sm_activate(non_neg_integer()) :: reg()
  def sm_activate(i), do: {sm(i) + 6, 1}

  @doc "PDI control register of SM `index`. Bit [0]=1 requests deactivation from PDI."
  @spec sm_pdi_control(non_neg_integer()) :: reg()
  def sm_pdi_control(i), do: {sm(i) + 7, 1}

  # -- FMMU array (§2.13) — 16 bytes per channel, base 0x0600 ---------------

  @doc "Base byte offset for FMMU channel `index` (0-based)."
  @spec fmmu(non_neg_integer()) :: non_neg_integer()
  def fmmu(index), do: 0x0600 + index * 16

  @doc "Logical start address of FMMU `index` (32-bit offset in master logical address space)."
  @spec fmmu_log_start(non_neg_integer()) :: reg()
  def fmmu_log_start(i), do: {fmmu(i) + 0, 4}

  @doc "Length of FMMU `index` mapping in bytes."
  @spec fmmu_length(non_neg_integer()) :: reg()
  def fmmu_length(i), do: {fmmu(i) + 4, 2}

  @doc "Logical start bit of FMMU `index` (0–7). Use 0 for byte-aligned mapping."
  @spec fmmu_log_start_bit(non_neg_integer()) :: reg()
  def fmmu_log_start_bit(i), do: {fmmu(i) + 6, 1}

  @doc "Logical stop bit of FMMU `index` (0–7). Use 7 for byte-aligned mapping."
  @spec fmmu_log_stop_bit(non_neg_integer()) :: reg()
  def fmmu_log_stop_bit(i), do: {fmmu(i) + 7, 1}

  @doc "Physical start address of FMMU `index`. Must match the paired SM's start address."
  @spec fmmu_phys_start(non_neg_integer()) :: reg()
  def fmmu_phys_start(i), do: {fmmu(i) + 8, 2}

  @doc "Physical start bit of FMMU `index` (0–7). Use 0 for byte-aligned mapping."
  @spec fmmu_phys_start_bit(non_neg_integer()) :: reg()
  def fmmu_phys_start_bit(i), do: {fmmu(i) + 10, 1}

  @doc "Type of FMMU `index`: 0x01=read (master reads from slave), 0x02=write (master writes to slave)."
  @spec fmmu_type(non_neg_integer()) :: reg()
  def fmmu_type(i), do: {fmmu(i) + 11, 1}

  @doc "Activate field of FMMU `index`. Write 0x01 to enable."
  @spec fmmu_activate(non_neg_integer()) :: reg()
  def fmmu_activate(i), do: {fmmu(i) + 12, 1}

  # -- Distributed Clocks (§9) — base 0x0900 ---------------------------------

  @doc "Receive time of port `n` (0–3). Latched on BWR to 0x0900. 32-bit local clock value."
  @spec dc_recv_time(non_neg_integer()) :: reg()
  def dc_recv_time(port), do: {0x0900 + port * 4, 4}

  @doc "Receive time at ECAT processing unit (64-bit local time). Used for offset calculation."
  @spec dc_recv_time_ecat() :: reg()
  def dc_recv_time_ecat, do: {0x0918, 8}

  @doc "System time — local copy of DC system time (ns since 2000-01-01). ARMW target for drift."
  @spec dc_system_time() :: reg()
  def dc_system_time, do: {0x0910, 8}

  @doc "System time offset — difference between local time and system time. Written by master."
  @spec dc_system_time_offset() :: reg()
  def dc_system_time_offset, do: {0x0920, 8}

  @doc "System time delay — propagation delay from reference clock to this slave. Written by master."
  @spec dc_system_time_delay() :: reg()
  def dc_system_time_delay, do: {0x0928, 4}

  @doc "System time difference — mean deviation between local copy and received system time. Converges to 0."
  @spec dc_system_time_diff() :: reg()
  def dc_system_time_diff, do: {0x092C, 4}

  @doc "Speed counter start — PLL bandwidth. Writing any value resets the drift filter."
  @spec dc_speed_counter_start() :: reg()
  def dc_speed_counter_start, do: {0x0930, 2}

  @doc "DC Activation register. Write 0x03 to enable SYNC0+SYNC1 output."
  @spec dc_activation() :: reg()
  def dc_activation, do: {0x0981, 1}

  @doc "Pulse length of SYNC signals in ns. 0 = acknowledged mode."
  @spec dc_pulse_length() :: reg()
  def dc_pulse_length, do: {0x0982, 2}

  @doc "SYNC0 start time — system time of first SYNC0 pulse (64-bit, ns since 2000-01-01)."
  @spec dc_sync0_start_time() :: reg()
  def dc_sync0_start_time, do: {0x0990, 8}

  @doc "SYNC0 cycle time in ns. 0 = single shot mode."
  @spec dc_sync0_cycle_time() :: reg()
  def dc_sync0_cycle_time, do: {0x09A0, 4}
end
