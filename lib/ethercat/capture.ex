defmodule EtherCAT.Capture do
  @moduledoc """
  Helpers for interactive slave-capture sessions.

  Use this module from `iex -S mix ethercat.capture --interface eth0` to:

  - inspect the discovered ring while it is held in PREOP
  - capture static slave identity and SII layout from a live device
  - optionally snapshot specific SDO entries
  - write a portable data-only capture file
  - generate a self-contained best-effort driver scaffold for integration tests
  - generate a simulator companion scaffold from that capture

  The generated scaffold preserves static structure only. It does not infer
  dynamic behavior, timing, or a complete object dictionary.

  ## Examples

      {:ok, slaves} = EtherCAT.Capture.list_slaves()

      {:ok, capture} =
        EtherCAT.Capture.capture(:slave_1, sdos: [{0x1008, 0x00}, {0x1009, 0x00}])

      {:ok, capture_path} =
        EtherCAT.Capture.write_capture(:slave_1, sdos: [{0x1008, 0x00}])

      {:ok, %{driver_path: driver_path}} =
        EtherCAT.Capture.gen_driver(:slave_1, module: MyApp.EL1809)

      {:ok, %{module_path: module_path}} =
        EtherCAT.Capture.gen_simulator(
          :slave_1,
          module: MyApp.EL1809.Simulator,
          sdos: [{0x1008, 0x00}]
        )
  """

  alias EtherCAT.Bus
  alias EtherCAT.Simulator.Slave.Object
  alias EtherCAT.Driver.Default, as: DefaultDriver
  alias EtherCAT.Slave.ESC.SII

  @capture_format 1
  @capture_file_extension ".capture"
  @default_capture_dir Path.join(["priv", "ethercat", "captures"])
  @default_output_phys 0x1100
  @default_input_phys 0x1180
  @phys_alignment 0x20
  @module_pattern ~r/^(Elixir\.)?[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/

  @type sdo_ref :: {non_neg_integer(), non_neg_integer()}
  @type capture :: map()

  @doc """
  Print a short interactive command summary.
  """
  @spec help() :: :ok
  def help do
    IO.puts("""
    EtherCAT.Capture recommended command:

      EtherCAT.Capture.gen_driver(:slave_1, module: MyApp.EL1809)
    """)

    :ok
  end

  @doc """
  Return a compact snapshot of the currently discovered slaves.
  """
  @spec list_slaves() :: {:ok, [map()]} | {:error, term()}
  def list_slaves do
    with {:ok, slaves} <- fetch_slaves() do
      {:ok, Enum.map(slaves, &summarize_slave/1)}
    end
  end

  @doc """
  Capture a live slave into a structural snapshot.

  Supported options:

  - `:sdos` — list of `{index, subindex}` tuples to upload and include
  """
  @spec capture(atom(), keyword()) :: {:ok, capture()} | {:error, term()}
  def capture(slave_name, opts \\ []) when is_atom(slave_name) and is_list(opts) do
    with {:ok, bus} <- fetch_bus(),
         {:ok, info} <- EtherCAT.Diagnostics.slave_info(slave_name),
         {:ok, sdos} <- normalize_sdo_refs(opts),
         {:ok, sii_identity} <- SII.read_identity(bus, info.station),
         {:ok, mailbox_config} <- SII.read_mailbox_config(bus, info.station),
         {:ok, sm_configs} <- SII.read_sm_configs(bus, info.station),
         {:ok, pdo_configs} <- SII.read_pdo_configs(bus, info.station),
         {:ok, sdo_snapshots} <- read_sdo_snapshots(slave_name, sdos) do
      bus_info =
        case Bus.info(bus) do
          {:ok, snapshot} -> snapshot
          {:error, reason} -> %{error: reason}
        end

      normalized_mailbox = normalize_mailbox_config(mailbox_config)
      normalized_pdos = normalize_pdo_configs(pdo_configs)

      {:ok,
       %{
         format: @capture_format,
         captured_at: captured_at(),
         source: %{
           master_state: fetch_master_state(),
           bus: bus_info,
           slave_name: slave_name,
           station: info.station
         },
         slave: %{
           name: info.name,
           station: info.station,
           al_state: info.al_state,
           identity: sii_identity,
           esc: info.esc,
           driver: info.driver,
           coe: info.coe,
           configuration_error: info.configuration_error
         },
         sii: %{
           identity: sii_identity,
           mailbox_config: normalized_mailbox,
           sm_configs: normalize_sm_configs(sm_configs),
           pdo_configs: normalized_pdos
         },
         sdos: sdo_snapshots,
         warnings: capture_warnings(normalized_mailbox, normalized_pdos, sdo_snapshots)
       }}
    end
  end

  @doc """
  Write a data-only capture file for `slave_name`.

  Supported options:

  - `:path` — output path; defaults to `priv/ethercat/captures/...`
  - `:force` — overwrite an existing file when `true`
  - `:sdos` — list of `{index, subindex}` tuples to upload and include
  """
  @spec write_capture(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_capture(slave_name, opts \\ []) when is_atom(slave_name) and is_list(opts) do
    with {:ok, capture} <- capture(slave_name, opts),
         path <- capture_path(capture, opts),
         :ok <-
           write_generated_file(path, render_capture(capture), Keyword.get(opts, :force, false)) do
      {:ok, path}
    end
  end

  @doc """
  Render the best-effort driver scaffold for `slave_name` or a previously loaded
  capture map.

  This returns the final module source directly instead of writing files.

  Supported options:

  - `:module` (required) — driver module name
  - `:simulator_module` — simulator companion module name; defaults to
    `Module.concat(module, Simulator)`
  - `:signal_names` — map or keyword list of `{{direction, pdo_index}, name}`
    overrides used for the rendered signal names
  - `:sdos` — list of `{index, subindex}` tuples to upload and include when
    `slave_name` is a live slave
  """
  @spec render_driver(atom() | capture(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render_driver(slave_name, opts) when is_atom(slave_name) and is_list(opts) do
    with {:ok, capture} <- capture(slave_name, opts) do
      render_driver(capture, opts)
    end
  end

  def render_driver(%{} = capture, opts) when is_list(opts) do
    normalized_capture = normalize_capture!(capture)

    with {:ok, module} <- fetch_module_option(opts),
         {:ok, simulator_module} <- fetch_simulator_module_option(opts, module),
         {:ok, signal_name_overrides} <- fetch_signal_name_overrides(opts) do
      {:ok,
       render_driver_module(
         module,
         simulator_module,
         normalized_capture,
         signal_name_overrides
       )}
    end
  end

  @doc """
  Render a capture-backed simulator scaffold for `slave_name` or a previously
  loaded capture map.

  This returns the final module source directly instead of writing files.

  Supported options:

  - `:module` (required) — simulator companion module name
  - `:capture_path` — output path for the generated capture file; used to
    compute the relative load path embedded in the module
  - `:module_path` — output path of the generated module; used to compute the
    relative load path embedded in the module
  - `:sdos` — list of `{index, subindex}` tuples to upload and include when
    `slave_name` is a live slave
  """
  @spec render_simulator(atom() | capture(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render_simulator(slave_name, opts) when is_atom(slave_name) and is_list(opts) do
    with {:ok, capture} <- capture(slave_name, opts) do
      render_simulator(capture, opts)
    end
  end

  def render_simulator(%{} = capture, opts) when is_list(opts) do
    normalized_capture = normalize_capture!(capture)

    with {:ok, module} <- fetch_module_option(opts) do
      capture_path = capture_path(normalized_capture, path_option(opts, :capture_path))
      module_path = module_path(module, opts)

      {:ok, render_simulator_module(module, module_path, capture_path)}
    end
  end

  @doc """
  Generate a self-contained best-effort driver scaffold for `slave_name`
  or a previously loaded capture map.

  Supported options:

  - `:module` (required) — driver module name
  - `:driver_path` — output path for the generated driver file
  - `:force` — overwrite existing files when `true`
  - `:sdos` — list of `{index, subindex}` tuples to upload and include

  Use `write_capture/2` separately if you also want to persist the captured
  snapshot file alongside the generated driver.
  """
  @spec gen_driver(atom() | capture(), keyword()) ::
          {:ok, %{driver_path: String.t()}} | {:error, term()}
  def gen_driver(slave_name, opts) when is_atom(slave_name) and is_list(opts) do
    with {:ok, module} <- fetch_module_option(opts),
         {:ok, capture} <- capture(slave_name, opts) do
      gen_driver(capture, Keyword.put_new(opts, :module, module))
    end
  end

  def gen_driver(%{} = capture, opts) when is_list(opts) do
    overwrite? = Keyword.get(opts, :force, false)

    with {:ok, module} <- fetch_module_option(opts),
         driver_path = driver_path(module, opts),
         {:ok, source} <- render_driver(capture, opts),
         :ok <- write_generated_file(driver_path, source, overwrite?) do
      {:ok, %{driver_path: driver_path}}
    end
  end

  @doc """
  Generate a simulator companion scaffold for `slave_name`.

  Supported options:

  - `:module` (required) — simulator companion module name
  - `:module_path` — output path for the generated module
  - `:capture_path` — output path for the generated capture file
  - `:force` — overwrite existing files when `true`
  - `:sdos` — list of `{index, subindex}` tuples to upload and include
  """
  @spec gen_simulator(atom(), keyword()) ::
          {:ok, %{capture_path: String.t(), module_path: String.t()}} | {:error, term()}
  def gen_simulator(slave_name, opts) when is_atom(slave_name) and is_list(opts) do
    with {:ok, module} <- fetch_module_option(opts),
         {:ok, capture} <- capture(slave_name, opts) do
      capture_path = capture_path(capture, path_option(opts, :capture_path))
      module_path = module_path(module, opts)
      overwrite? = Keyword.get(opts, :force, false)

      with :ok <- write_generated_file(capture_path, render_capture(capture), overwrite?),
           {:ok, source} <-
             render_simulator(
               capture,
               Keyword.merge(opts, capture_path: capture_path, module_path: module_path)
             ),
           :ok <- write_generated_file(module_path, source, overwrite?) do
        {:ok, %{capture_path: capture_path, module_path: module_path}}
      end
    end
  end

  @doc """
  Load a data-only capture file written by `write_capture/2`.
  """
  @spec load_capture(Path.t()) :: {:ok, capture()} | {:error, term()}
  def load_capture(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    case File.read(expanded_path) do
      {:ok, contents} ->
        case decode_capture(contents) do
          {:ok, capture} -> {:ok, capture}
          {:error, reason} -> {:error, {:invalid_capture, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load a data-only capture file and raise on failure.
  """
  @spec load_capture!(Path.t()) :: capture()
  def load_capture!(path) when is_binary(path) do
    case load_capture(path) do
      {:ok, capture} ->
        capture

      {:error, reason} ->
        raise ArgumentError, "failed to load capture #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Convert a capture map into simulator definition options.

  The generated options normalize PDO data onto the simulator's simpler
  process-data model: one output window and one input window with canonical
  physical offsets.
  """
  @spec definition_options(capture()) :: keyword()
  def definition_options(%{} = capture) do
    capture = normalize_capture!(capture)
    mailbox_config = get_in(capture, [:sii, :mailbox_config]) || zero_mailbox_config()
    pdo_configs = get_in(capture, [:sii, :pdo_configs]) || []
    identity = get_in(capture, [:sii, :identity]) || %{}
    esc = get_in(capture, [:slave, :esc]) || %{}
    sdos = Map.get(capture, :sdos, [])

    %{
      pdo_entries: pdo_entries,
      signals: signals,
      output_size: output_size,
      input_size: input_size
    } =
      normalize_pdo_layout(pdo_configs)

    {output_phys, input_phys} = canonical_process_phys(mailbox_config, output_size, input_size)

    [
      profile: scaffold_profile(mailbox_config),
      vendor_id: Map.get(identity, :vendor_id, 0),
      product_code: Map.get(identity, :product_code, 0),
      revision: Map.get(identity, :revision, 0),
      serial_number: Map.get(identity, :serial_number, 0),
      esc_type: 0x11,
      fmmu_count: max(Map.get(esc, :fmmu_count, 4), 4),
      sm_count: max(Map.get(esc, :sm_count, 4), 4),
      output_phys: output_phys,
      output_size: output_size,
      input_phys: input_phys,
      input_size: input_size,
      mirror_output_to_input?: false,
      mailbox_config: mailbox_config,
      pdo_entries: pdo_entries,
      signals: signals,
      objects: captured_objects(sdos),
      dc_capable?: false
    ]
  end

  defp summarize_slave(%{name: name, station: station, fault: fault}) do
    case EtherCAT.Diagnostics.slave_info(name) do
      {:ok, info} ->
        %{
          name: name,
          station: station,
          al_state: info.al_state,
          vendor_id: get_in(info, [:identity, :vendor_id]),
          product_code: get_in(info, [:identity, :product_code]),
          revision: get_in(info, [:identity, :revision]),
          coe: info.coe,
          fault: fault
        }

      {:error, reason} ->
        %{name: name, station: station, fault: fault, error: reason}
    end
  end

  defp fetch_slaves do
    case EtherCAT.Diagnostics.slaves() do
      {:ok, slaves} -> {:ok, slaves}
      {:error, _} = err -> err
    end
  end

  defp fetch_bus do
    case EtherCAT.Diagnostics.bus() do
      {:error, _} = err -> err
      {:ok, nil} -> {:error, :not_started}
      {:ok, bus} -> {:ok, bus}
    end
  end

  defp fetch_master_state do
    case EtherCAT.state() do
      {:ok, state} -> state
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_module_option(opts) do
    case Keyword.get(opts, :module) do
      module when is_atom(module) -> {:ok, module}
      module when is_binary(module) -> normalize_module_name(module)
      nil -> {:error, :missing_module}
      other -> {:error, {:invalid_module, other}}
    end
  end

  defp fetch_simulator_module_option(opts, module) do
    case Keyword.get(opts, :simulator_module, default_simulator_module(module)) do
      simulator_module when is_atom(simulator_module) -> {:ok, simulator_module}
      simulator_module when is_binary(simulator_module) -> normalize_module_name(simulator_module)
      other -> {:error, {:invalid_simulator_module, other}}
    end
  end

  defp normalize_module_name(module) when is_binary(module) do
    trimmed = String.trim(module)

    if Regex.match?(@module_pattern, trimmed) do
      {:ok, trimmed}
    else
      {:error, {:invalid_module, module}}
    end
  end

  defp default_simulator_module(module) when is_atom(module), do: Module.concat(module, Simulator)
  defp default_simulator_module(module) when is_binary(module), do: module <> ".Simulator"

  defp fetch_signal_name_overrides(opts) do
    opts
    |> Keyword.get(:signal_names, %{})
    |> normalize_signal_name_overrides()
  end

  defp normalize_signal_name_overrides(overrides) when is_map(overrides) do
    overrides
    |> Enum.into([])
    |> normalize_signal_name_overrides()
  end

  defp normalize_signal_name_overrides(overrides) when is_list(overrides) do
    Enum.reduce_while(overrides, {:ok, %{}}, fn
      {{direction, pdo_index}, name}, {:ok, acc} ->
        with {:ok, normalized_direction} <- normalize_signal_override_direction(direction),
             true <- is_integer(pdo_index) and pdo_index >= 0,
             {:ok, normalized_name} <- normalize_signal_override_name(name) do
          {:cont, {:ok, Map.put(acc, {normalized_direction, pdo_index}, normalized_name)}}
        else
          _ -> {:halt, {:error, {:invalid_signal_name_override, {{direction, pdo_index}, name}}}}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_signal_name_override, other}}}
    end)
  end

  defp normalize_signal_name_overrides(_other), do: {:error, :invalid_signal_name_overrides}

  defp normalize_signal_override_direction(direction) when direction in [:input, :output],
    do: {:ok, direction}

  defp normalize_signal_override_direction("input"), do: {:ok, :input}
  defp normalize_signal_override_direction("output"), do: {:ok, :output}
  defp normalize_signal_override_direction(_direction), do: :error

  defp normalize_signal_override_name(name) when is_atom(name), do: {:ok, name}

  defp normalize_signal_override_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" do
      :error
    else
      {:ok, trimmed}
    end
  end

  defp normalize_signal_override_name(_name), do: :error

  defp normalize_sdo_refs(opts) do
    sdos = Keyword.get(opts, :sdos, [])

    cond do
      is_list(sdos) and Enum.all?(sdos, &valid_sdo_ref?/1) ->
        {:ok, Enum.uniq(sdos)}

      true ->
        {:error, {:invalid_sdos, sdos}}
    end
  end

  defp valid_sdo_ref?({index, subindex})
       when is_integer(index) and index >= 0 and is_integer(subindex) and subindex >= 0,
       do: true

  defp valid_sdo_ref?(_other), do: false

  defp read_sdo_snapshots(_slave_name, []), do: {:ok, []}

  defp read_sdo_snapshots(slave_name, sdos) do
    Enum.reduce_while(sdos, {:ok, []}, fn {index, subindex}, {:ok, acc} ->
      case EtherCAT.Provisioning.upload_sdo(slave_name, index, subindex) do
        {:ok, data} ->
          {:cont, {:ok, acc ++ [%{index: index, subindex: subindex, data: data}]}}

        {:error, reason} ->
          {:halt, {:error, {:sdo_upload_failed, index, subindex, reason}}}
      end
    end)
  end

  defp normalize_sm_configs(sm_configs) do
    Enum.map(sm_configs, fn {index, phys_start, length, ctrl} ->
      %{index: index, phys_start: phys_start, length: length, ctrl: ctrl}
    end)
  end

  defp normalize_mailbox_config(mailbox_config) do
    %{
      recv_offset: mailbox_config.recv_offset,
      recv_size: mailbox_config.recv_size,
      send_offset: mailbox_config.send_offset,
      send_size: mailbox_config.send_size
    }
  end

  defp normalize_pdo_configs(pdo_configs) do
    Enum.map(pdo_configs, fn pdo ->
      %{
        index: pdo.index,
        direction: pdo.direction,
        sm_index: pdo.sm_index,
        bit_size: pdo.bit_size,
        bit_offset: pdo.bit_offset
      }
    end)
  end

  defp capture_warnings(mailbox_config, pdo_configs, sdo_snapshots) do
    []
    |> maybe_add_warning(
      pdo_configs != [],
      "Generated simulator scaffolds normalize process data onto simulator SM2/SM3 with canonical process-image offsets."
    )
    |> maybe_add_warning(
      multiple_direction_sms?(pdo_configs, :output),
      "Output PDOs span multiple SyncManagers on the captured device; generated simulator scaffolds collapse them onto one output window."
    )
    |> maybe_add_warning(
      multiple_direction_sms?(pdo_configs, :input),
      "Input PDOs span multiple SyncManagers on the captured device; generated simulator scaffolds collapse them onto one input window."
    )
    |> maybe_add_warning(
      Enum.any?(pdo_configs, &(rem(&1.bit_size, 8) != 0)),
      "Sub-byte PDO entries are scaffolded as raw booleans or integers; typed device semantics still need manual authoring."
    )
    |> maybe_add_warning(
      mailbox_enabled?(mailbox_config) and sdo_snapshots == [],
      "No SDOs were captured; generated mailbox-capable simulator scaffolds start with an empty object dictionary."
    )
    |> maybe_add_warning(
      true,
      "DC capability is not inferred from this capture; generated simulator scaffolds default to dc_capable?: false."
    )
  end

  defp multiple_direction_sms?(pdo_configs, direction) do
    pdo_configs
    |> Enum.filter(&(&1.direction == direction))
    |> Enum.map(& &1.sm_index)
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  defp normalize_capture!(%{format: @capture_format} = capture), do: capture

  defp normalize_capture!(other) do
    raise ArgumentError,
          "expected capture map with format #{@capture_format}, got: #{inspect(other)}"
  end

  defp normalize_pdo_layout(pdo_configs) do
    signal_names = DefaultDriver.signal_model(%{}, pdo_configs) |> Map.new()

    layout =
      Enum.reduce(
        pdo_configs,
        %{offsets: %{output: 0, input: 0}, pdo_entries: [], signals: %{}},
        fn pdo, acc ->
          direction = pdo.direction
          bit_offset = Map.fetch!(acc.offsets, direction)

          signal_name =
            Map.get(signal_names, pdo.index, generated_signal_name(pdo.index))

          signal =
            %{
              direction: direction,
              pdo_index: pdo.index,
              bit_offset: bit_offset,
              bit_size: pdo.bit_size,
              type: signal_type(pdo.bit_size),
              label: pdo_label(pdo.index),
              group: signal_group(direction)
            }

          %{
            acc
            | offsets: Map.put(acc.offsets, direction, bit_offset + pdo.bit_size),
              pdo_entries:
                acc.pdo_entries ++
                  [
                    %{
                      index: pdo.index,
                      direction: direction,
                      sm_index: simulator_sm_index(direction),
                      bit_size: pdo.bit_size
                    }
                  ],
              signals: Map.put(acc.signals, signal_name, signal)
          }
        end
      )

    %{
      pdo_entries: layout.pdo_entries,
      signals: layout.signals,
      output_size: bit_bytes(layout.offsets.output),
      input_size: bit_bytes(layout.offsets.input)
    }
  end

  defp captured_objects(sdos) do
    Enum.into(sdos, %{}, fn %{index: index, subindex: subindex, data: data} ->
      size = max(byte_size(data), 1)

      {{index, subindex},
       Object.new(
         index: index,
         subindex: subindex,
         type: {:binary, size},
         value: data,
         access: :rw,
         group: :captured
       )}
    end)
  end

  defp scaffold_profile(mailbox_config) do
    if mailbox_enabled?(mailbox_config), do: :mailbox_device, else: :coupler
  end

  defp mailbox_enabled?(%{recv_size: recv_size, send_size: send_size}) do
    recv_size > 0 or send_size > 0
  end

  defp canonical_process_phys(mailbox_config, output_size, _input_size) do
    mailbox_end =
      Enum.max([
        0,
        mailbox_config.recv_offset + mailbox_config.recv_size,
        mailbox_config.send_offset + mailbox_config.send_size
      ])

    output_phys = max(@default_output_phys, align_up(mailbox_end, @phys_alignment))
    input_floor = max(@default_input_phys, output_phys + output_size)
    input_phys = align_up(input_floor, @phys_alignment)

    {output_phys, input_phys}
  end

  defp align_up(value, alignment) when rem(value, alignment) == 0, do: value

  defp align_up(value, alignment) do
    value + alignment - rem(value, alignment)
  end

  defp bit_bytes(0), do: 0
  defp bit_bytes(bit_count), do: div(bit_count + 7, 8)

  defp simulator_sm_index(:output), do: 2
  defp simulator_sm_index(:input), do: 3

  defp signal_type(1), do: :bool
  defp signal_type(bits) when rem(bits, 8) == 0, do: {:binary, div(bits, 8)}
  defp signal_type(bits), do: {:uint, bits}

  defp signal_group(:output), do: :outputs
  defp signal_group(:input), do: :inputs

  defp pdo_label(index), do: "PDO " <> hex(index, 4)

  defp generated_signal_name(index), do: :"pdo_0x#{String.downcase(Integer.to_string(index, 16))}"

  defp zero_mailbox_config do
    %{recv_offset: 0, recv_size: 0, send_offset: 0, send_size: 0}
  end

  defp capture_path(capture, opts_or_path) when is_list(opts_or_path) do
    capture_path(capture, path_option(opts_or_path, :path))
  end

  defp capture_path(capture, nil) do
    filename =
      [
        hex(get_in(capture, [:slave, :identity, :vendor_id]) || 0, 8),
        hex(get_in(capture, [:slave, :identity, :product_code]) || 0, 8),
        hex(get_in(capture, [:slave, :identity, :revision]) || 0, 8),
        safe_slug(get_in(capture, [:slave, :name]) || :slave)
      ]
      |> Enum.join("_")
      |> Kernel.<>(@capture_file_extension)

    Path.expand(Path.join(@default_capture_dir, filename))
  end

  defp capture_path(_capture, path) when is_binary(path), do: Path.expand(path)

  defp module_path(module, opts) do
    case Keyword.get(opts, :module_path) do
      path when is_binary(path) ->
        Path.expand(path)

      nil ->
        module
        |> Module.split()
        |> Enum.map(&Macro.underscore/1)
        |> then(&Path.join(["lib" | &1]))
        |> Kernel.<>(".ex")
        |> Path.expand()
    end
  end

  defp path_option(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        nil

      path when is_binary(path) ->
        path

      other ->
        raise ArgumentError, "expected #{inspect(key)} to be a path, got: #{inspect(other)}"
    end
  end

  defp render_capture(capture) do
    payload =
      capture
      |> :erlang.term_to_binary(compressed: 6)
      |> Base.encode64(padding: false)
      |> chunk_text(96)

    identity = get_in(capture, [:slave, :identity]) || %{}

    [
      "# Generated by EtherCAT.Capture at #{capture.captured_at}",
      "# Format: #{@capture_format}",
      "# Encoding: erlang-term-base64",
      "# Slave: #{get_in(capture, [:slave, :name]) || :unknown}",
      "# Identity: vendor=#{hex(Map.get(identity, :vendor_id, 0), 8)} " <>
        "product=#{hex(Map.get(identity, :product_code, 0), 8)} " <>
        "revision=#{hex(Map.get(identity, :revision, 0), 8)}",
      "",
      payload,
      ""
    ]
    |> Enum.join("\n")
  end

  defp driver_path(module, opts) do
    case Keyword.get(opts, :driver_path) do
      path when is_binary(path) ->
        Path.expand(path)

      nil ->
        case integration_support_driver_path(module) do
          nil ->
            module
            |> Module.split()
            |> Enum.map(&Macro.underscore/1)
            |> then(&Path.join(["lib" | &1]))
            |> Kernel.<>(".ex")
            |> Path.expand()

          path ->
            Path.expand(path)
        end

      other ->
        raise ArgumentError, "expected :driver_path to be a path, got: #{inspect(other)}"
    end
  end

  defp integration_support_driver_path(module) do
    case Module.split(module) do
      ["EtherCAT", "IntegrationSupport", "Drivers" | rest] when rest != [] ->
        Path.join([
          "test",
          "integration",
          "support",
          "drivers" | Enum.map(rest, &Macro.underscore/1)
        ]) <>
          ".ex"

      _other ->
        nil
    end
  end

  defp render_driver_module(module, simulator_module, capture, signal_name_overrides) do
    scaffold = driver_scaffold(capture, signal_name_overrides)

    [
      "defmodule #{render_module_name(module)} do",
      "  @moduledoc false",
      "",
      render_driver_behaviour_block(scaffold),
      "",
      render_driver_identity_block(scaffold.identity),
      "",
      render_driver_signal_model_block(scaffold.signal_model),
      "",
      render_driver_mailbox_block(scaffold.mailbox_steps),
      "",
      render_driver_codec_block(scaffold),
      "",
      render_driver_runtime_block(),
      "end",
      "",
      "defmodule #{render_module_name(simulator_module)} do",
      "  @moduledoc false",
      "",
      "  @behaviour EtherCAT.Simulator.Adapter",
      "",
      render_driver_simulator_block(scaffold.simulator_definition_options),
      "end",
      ""
    ]
    |> Enum.join("\n")
    |> format_source()
  end

  defp render_driver_behaviour_block(scaffold) do
    [
      "  @behaviour EtherCAT.Driver"
      | if(scaffold.mailbox_steps == [],
          do: [],
          else: ["  @behaviour EtherCAT.Driver.Provisioning"]
        )
    ]
    |> Enum.join("\n")
  end

  defp render_driver_identity_block(identity) do
    """
      @impl true
      def identity do
    #{indent_block(render_identity_literal(identity), 4)}
      end
    """
    |> String.trim_trailing()
  end

  defp render_driver_signal_model_block(signal_model) do
    signal_model_literal = render_signal_model_literal(signal_model)

    [
      inline_literal("  @signals ", signal_model_literal),
      "",
      "  def signal_model(config), do: signal_model(config, [])",
      "",
      "  @impl true",
      "  def signal_model(_config, _sii_pdo_configs), do: @signals"
    ]
    |> Enum.join("\n")
  end

  defp render_driver_mailbox_block([]), do: ""

  defp render_driver_mailbox_block(mailbox_steps) do
    """
      @impl true
      def mailbox_steps(_config, %{phase: :preop}) do
    #{indent_block(format_literal(mailbox_steps, 88), 4)}
      end

      def mailbox_steps(_config, _context), do: []
    """
    |> String.trim_trailing()
  end

  defp render_driver_runtime_block do
    """
      @impl true
      def project_state(decoded_inputs, _prev_state, driver_state, _config) do
        {:ok, decoded_inputs, driver_state, [], []}
      end

      @impl true
      def command(command, _state, _driver_state, _config),
        do: EtherCAT.Driver.unsupported_command(command)
    """
    |> String.trim_trailing()
  end

  defp render_driver_codec_block(scaffold) do
    case scaffold.codec_template do
      :beckhoff_el3202 ->
        render_el3202_codec_block(scaffold)

      nil ->
        render_generic_driver_codec_block(scaffold)
    end
  end

  defp render_generic_driver_codec_block(scaffold) do
    input_signals = scaffold.input_signals
    output_signals = scaffold.output_signals
    input_entries = scaffold.input_entries
    output_entries = scaffold.output_entries

    cond do
      output_entries == [] and input_entries == [] ->
        """
          @impl true
          def encode_signal(_signal, _config, _value), do: <<>>

          @impl true
          def decode_signal(_signal, _config, _raw), do: nil
        """

      output_entries == [] and digital_group?(input_entries) ->
        """
          @impl true
          def encode_signal(_signal, _config, _value), do: <<>>

          @impl true
          def decode_signal(_signal, _config, <<_::7, bit::1>>), do: bit

          def decode_signal(_signal, _config, _raw), do: 0
        """

      input_entries == [] and digital_group?(output_entries) ->
        """
          @impl true
          def encode_signal(_signal, _config, true), do: <<1>>

          def encode_signal(_signal, _config, false), do: <<0>>

          def encode_signal(_signal, _config, value) when is_integer(value), do: <<value::8>>

          def encode_signal(_signal, _config, _value), do: <<>>

          @impl true
          def decode_signal(_signal, _config, _raw), do: nil
        """

      digital_group?(input_entries) and digital_group?(output_entries) ->
        [
          inline_literal("  @input_signals ", render_signal_name_list_literal(input_signals)),
          inline_literal("  @output_signals ", render_signal_name_list_literal(output_signals)),
          "",
          "  @impl true",
          "  def encode_signal(signal, _config, true) when signal in @output_signals, do: <<1>>",
          "",
          "  def encode_signal(signal, _config, false) when signal in @output_signals, do: <<0>>",
          "",
          "  def encode_signal(signal, _config, value) when signal in @output_signals and is_integer(value),",
          "    do: <<value::8>>",
          "",
          "  def encode_signal(_signal, _config, _value), do: <<>>",
          "",
          "  @impl true",
          "  def decode_signal(signal, _config, <<_::7, bit::1>>) when signal in @input_signals,",
          "    do: bit",
          "",
          "  def decode_signal(signal, _config, _raw) when signal in @input_signals, do: 0",
          "",
          "  def decode_signal(_signal, _config, _raw), do: nil"
        ]
        |> Enum.join("\n")

      output_entries == [] ->
        """
          @impl true
          def encode_signal(_signal, _config, _value), do: <<>>

          @impl true
          def decode_signal(_signal, _config, raw), do: raw
        """

      input_entries == [] ->
        """
          @impl true
          def encode_signal(_signal, _config, value) when is_binary(value), do: value

          def encode_signal(_signal, _config, _value), do: <<>>

          @impl true
          def decode_signal(_signal, _config, _raw), do: nil
        """

      true ->
        [
          inline_literal("  @input_signals ", render_signal_name_list_literal(input_signals)),
          inline_literal("  @output_signals ", render_signal_name_list_literal(output_signals)),
          "",
          "  @impl true",
          "  def encode_signal(signal, _config, value) when signal in @output_signals and is_binary(value),",
          "    do: value",
          "",
          "  def encode_signal(signal, _config, _value) when signal in @output_signals, do: <<>>",
          "",
          "  def encode_signal(_signal, _config, _value), do: <<>>",
          "",
          "  @impl true",
          "  def decode_signal(signal, _config, raw) when signal in @input_signals, do: raw",
          "",
          "  def decode_signal(_signal, _config, _raw), do: nil"
        ]
        |> Enum.join("\n")
    end
    |> String.trim_trailing()
  end

  defp render_el3202_codec_block(scaffold) do
    [channel1, channel2] =
      scaffold.input_entries
      |> Enum.sort_by(& &1.pdo_index)
      |> Enum.map(& &1.name)

    [
      "  @impl true",
      "  def encode_signal(_signal, _config, _value), do: <<>>",
      "",
      "  @impl true",
      "  def decode_signal(#{signal_name_literal(channel1)}, _config, <<",
      "        _::1,",
      "        error::1,",
      "        _::2,",
      "        _::2,",
      "        overrange::1,",
      "        underrange::1,",
      "        toggle::1,",
      "        state::1,",
      "        _::6,",
      "        value::16-little",
      "      >>) do",
      "    %{",
      "      ohms: value / 16.0,",
      "      overrange: overrange == 1,",
      "      underrange: underrange == 1,",
      "      error: error == 1,",
      "      invalid: state == 1,",
      "      toggle: toggle",
      "    }",
      "  end",
      "",
      "  def decode_signal(#{signal_name_literal(channel2)}, _config, <<",
      "        _::1,",
      "        error::1,",
      "        _::2,",
      "        _::2,",
      "        overrange::1,",
      "        underrange::1,",
      "        toggle::1,",
      "        state::1,",
      "        _::6,",
      "        value::16-little",
      "      >>) do",
      "    %{",
      "      ohms: value / 16.0,",
      "      overrange: overrange == 1,",
      "      underrange: underrange == 1,",
      "      error: error == 1,",
      "      invalid: state == 1,",
      "      toggle: toggle",
      "    }",
      "  end",
      "",
      "  def decode_signal(_signal, _config, _raw), do: nil"
    ]
    |> Enum.join("\n")
  end

  defp render_driver_simulator_block(definition_options) do
    """
      @impl true
      def definition_options(_config) do
    #{indent_block(render_simulator_definition_options_literal(definition_options), 4)}
      end
    """
    |> String.trim_trailing()
  end

  defp driver_scaffold(capture, signal_name_overrides) do
    pdo_configs = get_in(capture, [:sii, :pdo_configs]) || []
    template = driver_template(capture)
    identity = driver_identity(get_in(capture, [:sii, :identity]) || %{})
    signal_entries = build_driver_signal_entries(pdo_configs, template, signal_name_overrides)

    %{
      identity: identity,
      signal_model: Enum.map(signal_entries, &{&1.name, &1.pdo_index}),
      input_entries: Enum.filter(signal_entries, &(&1.direction == :input)),
      output_entries: Enum.filter(signal_entries, &(&1.direction == :output)),
      input_signals:
        signal_entries
        |> Enum.filter(&(&1.direction == :input))
        |> Enum.map(& &1.name),
      output_signals:
        signal_entries
        |> Enum.filter(&(&1.direction == :output))
        |> Enum.map(& &1.name),
      mailbox_steps: driver_mailbox_steps(capture),
      codec_template: template_codec(template),
      simulator_definition_options:
        driver_simulator_definition_options(capture, signal_entries, template)
    }
  end

  defp driver_identity(identity) do
    %{
      vendor_id: Map.get(identity, :vendor_id, 0),
      product_code: Map.get(identity, :product_code, 0)
    }
    |> maybe_put_driver_revision(Map.get(identity, :revision))
  end

  defp maybe_put_driver_revision(identity, revision)
       when is_integer(revision) and revision >= 0 do
    Map.put(identity, :revision, revision)
  end

  defp maybe_put_driver_revision(identity, _revision), do: identity

  defp build_driver_signal_entries([], _template, _signal_name_overrides), do: []

  defp build_driver_signal_entries(pdo_configs, template, signal_name_overrides) do
    input_pdos = Enum.filter(pdo_configs, &(&1.direction == :input))
    output_pdos = Enum.filter(pdo_configs, &(&1.direction == :output))
    mixed? = input_pdos != [] and output_pdos != []

    name_lookup =
      name_direction_pdos(input_pdos, :input, mixed?, template, signal_name_overrides)
      |> Map.merge(
        name_direction_pdos(output_pdos, :output, mixed?, template, signal_name_overrides)
      )

    Enum.map(pdo_configs, fn pdo ->
      %{
        name: Map.fetch!(name_lookup, pdo_signature(pdo)),
        direction: pdo.direction,
        pdo_index: pdo.index,
        bit_size: pdo.bit_size
      }
    end)
  end

  defp name_direction_pdos([], _direction, _mixed?, _template, _signal_name_overrides), do: %{}

  defp name_direction_pdos(pdos, direction, mixed?, template, signal_name_overrides) do
    naming_mode =
      cond do
        digital_group?(Enum.map(pdos, &signal_entry_from_pdo/1)) ->
          if mixed?, do: {:numbered, direction_prefix(direction)}, else: {:numbered, "ch"}

        contiguous_indexes?(pdos) ->
          if mixed?, do: {:numbered, Atom.to_string(direction)}, else: {:numbered, "channel"}

        true ->
          :pdo
      end

    pdos
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {pdo, index} ->
      {
        pdo_signature(pdo),
        Map.get(signal_name_overrides, {pdo.direction, pdo.index}) ||
          template_signal_name(template, pdo) ||
          case naming_mode do
            {:numbered, prefix} -> String.to_atom("#{prefix}#{index}")
            :pdo -> generated_driver_signal_name(direction, pdo.index, mixed?)
          end
      }
    end)
  end

  defp signal_entry_from_pdo(pdo) do
    %{direction: pdo.direction, pdo_index: pdo.index, bit_size: pdo.bit_size}
  end

  defp driver_simulator_definition_options(capture, signal_entries, template) do
    mailbox_config = get_in(capture, [:sii, :mailbox_config]) || zero_mailbox_config()
    identity = get_in(capture, [:sii, :identity]) || %{}
    input_entries = Enum.filter(signal_entries, &(&1.direction == :input))
    output_entries = Enum.filter(signal_entries, &(&1.direction == :output))

    cond do
      signal_entries == [] and not mailbox_enabled?(mailbox_config) ->
        [
          profile: :coupler,
          vendor_id: Map.get(identity, :vendor_id, 0),
          product_code: Map.get(identity, :product_code, 0),
          revision: Map.get(identity, :revision, 0),
          serial_number: Map.get(identity, :serial_number, 0)
        ]

      not mailbox_enabled?(mailbox_config) and digital_direction?(input_entries, output_entries) ->
        digital_simulator_options(identity, input_entries, output_entries)

      true ->
        capture
        |> definition_options()
        |> maybe_apply_template_signal_specs(signal_entries, template)
    end
  end

  defp driver_mailbox_steps(capture) do
    capture
    |> Map.get(:sdos, [])
    |> Enum.map(fn %{index: index, subindex: subindex, data: data} ->
      {:sdo_download, index, subindex, data}
    end)
  end

  defp driver_template(capture) do
    case get_in(capture, [:sii, :identity]) do
      %{vendor_id: 0x0000_0002, product_code: 0x0C82_3052} ->
        %{
          id: :beckhoff_el3202,
          signal_names: %{
            {:input, 0x1A00} => :channel1,
            {:input, 0x1A01} => :channel2
          }
        }

      _other ->
        nil
    end
  end

  defp template_signal_name(nil, _pdo), do: nil

  defp template_signal_name(template, pdo) do
    get_in(template, [:signal_names, {pdo.direction, pdo.index}])
  end

  defp template_codec(%{id: :beckhoff_el3202}), do: :beckhoff_el3202
  defp template_codec(_template), do: nil

  defp maybe_apply_template_signal_specs(definition_options, signal_entries, template) do
    definition_options
    |> maybe_rename_signal_specs(signal_entries)
    |> maybe_template_profile_override(template)
  end

  defp maybe_rename_signal_specs(definition_options, []) do
    definition_options
  end

  defp maybe_rename_signal_specs(definition_options, signal_entries) do
    signals = Keyword.get(definition_options, :signals, %{})
    signals_by_pdo = Map.new(signals, fn {_name, spec} -> {spec.pdo_index, spec} end)

    renamed_signals =
      Enum.into(signal_entries, %{}, fn entry ->
        {entry.name, Map.fetch!(signals_by_pdo, entry.pdo_index)}
      end)

    Keyword.put(definition_options, :signals, renamed_signals)
  end

  defp maybe_template_profile_override(definition_options, %{id: :beckhoff_el3202}) do
    definition_options
    |> Keyword.put(:profile, :mailbox_device)
  end

  defp maybe_template_profile_override(definition_options, _template), do: definition_options

  defp digital_direction?(input_entries, output_entries) do
    (input_entries != [] or output_entries != []) and
      (input_entries == [] or digital_group?(input_entries)) and
      (output_entries == [] or digital_group?(output_entries))
  end

  defp digital_simulator_options(identity, input_entries, output_entries) do
    direction =
      cond do
        input_entries != [] and output_entries != [] -> :io
        input_entries != [] -> :input
        true -> :output
      end

    [
      profile: :digital_io,
      mode: :channels,
      direction: direction,
      channels: max(length(input_entries), length(output_entries)),
      vendor_id: Map.get(identity, :vendor_id, 0),
      product_code: Map.get(identity, :product_code, 0),
      revision: Map.get(identity, :revision, 0),
      serial_number: Map.get(identity, :serial_number, 0)
    ]
    |> maybe_put_direction_names(:input_names, input_entries)
    |> maybe_put_direction_names(:output_names, output_entries)
    |> maybe_put_pdo_base(:input_pdo_base, input_entries)
    |> maybe_put_pdo_base(:output_pdo_base, output_entries)
  end

  defp maybe_put_direction_names(opts, _key, []), do: opts

  defp maybe_put_direction_names(opts, key, entries) do
    Keyword.put(opts, key, Enum.map(entries, & &1.name))
  end

  defp maybe_put_pdo_base(opts, _key, []), do: opts

  defp maybe_put_pdo_base(opts, key, [entry | _rest]) do
    Keyword.put(opts, key, entry.pdo_index)
  end

  defp digital_group?([]), do: false

  defp digital_group?(entries) do
    Enum.all?(entries, &(&1.bit_size == 1)) and contiguous_signal_indexes?(entries)
  end

  defp contiguous_signal_indexes?(entries) do
    entries
    |> Enum.map(& &1.pdo_index)
    |> contiguous_values?()
  end

  defp contiguous_indexes?(pdos) do
    pdos
    |> Enum.map(& &1.index)
    |> contiguous_values?()
  end

  defp contiguous_values?([]), do: false

  defp contiguous_values?(values) do
    sorted = Enum.sort(values)
    sorted == Enum.to_list(hd(sorted)..List.last(sorted))
  end

  defp pdo_signature(pdo), do: {pdo.direction, pdo.index, pdo.sm_index, pdo.bit_offset}

  defp direction_prefix(:input), do: "in"
  defp direction_prefix(:output), do: "out"

  defp generated_driver_signal_name(direction, index, true),
    do: :"#{direction}_pdo_0x#{String.downcase(Integer.to_string(index, 16))}"

  defp generated_driver_signal_name(_direction, index, false),
    do: generated_signal_name(index)

  defp render_identity_literal(identity) do
    fields =
      [
        {:vendor_id, Map.fetch!(identity, :vendor_id), 8},
        {:product_code, Map.fetch!(identity, :product_code), 8}
      ]
      |> maybe_append_identity_revision(identity)

    "%{\n" <>
      (fields
       |> Enum.map(fn {key, value, width} -> "  #{key}: #{hex_literal(value, width)}" end)
       |> Enum.join(",\n")) <>
      "\n}"
  end

  defp maybe_append_identity_revision(fields, %{revision: revision})
       when is_integer(revision) and revision >= 0 do
    fields ++ [{:revision, revision, 8}]
  end

  defp maybe_append_identity_revision(fields, _identity), do: fields

  defp render_signal_model_literal([]), do: "[]"

  defp render_signal_model_literal(signal_model) do
    "[\n" <>
      (signal_model
       |> Enum.map(fn {name, index} ->
         "  #{signal_name_key_literal(name)}: #{hex_literal(index, 4)}"
       end)
       |> Enum.join(",\n")) <>
      "\n]"
  end

  defp render_signal_name_list_literal(list) do
    "[" <> Enum.map_join(list, ", ", &signal_name_literal/1) <> "]"
  end

  defp inline_literal(prefix, literal) do
    case String.split(literal, "\n", parts: 2) do
      [single_line] ->
        prefix <> single_line

      [first_line, rest] ->
        prefix <> first_line <> "\n" <> indent_block(rest, String.length(prefix))
    end
  end

  defp indent_block(text, spaces) do
    padding = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> padding <> line
    end)
  end

  defp format_literal(value, width) do
    inspect(
      value,
      pretty: true,
      limit: :infinity,
      printable_limit: :infinity,
      width: width
    )
  end

  defp hex_literal(value, width) when is_integer(value) and value >= 0 do
    "0x" <> grouped_hex(value, width)
  end

  defp grouped_hex(value, width) do
    value
    |> hex(width)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("_", &Enum.join/1)
  end

  defp render_simulator_module(module, module_path, capture_path) do
    relative_capture_path = relative_path_from(Path.dirname(module_path), capture_path)

    """
    defmodule #{render_module_name(module)} do
      @moduledoc \"\"\"
      Simulator scaffold generated from a captured EtherCAT slave.

      This preserves static identity, mailbox layout, and PDO shape from the
      capture data file. Dynamic behavior, timing, and richer mailbox semantics
      still need manual authoring.
      \"\"\"

      @behaviour EtherCAT.Simulator.Adapter

      @capture_path Path.expand(#{inspect(relative_capture_path)}, __DIR__)

      @impl true
      def definition_options(config) when is_map(config) do
        _ = config

        @capture_path
        |> EtherCAT.Capture.load_capture!()
        |> EtherCAT.Capture.definition_options()
      end
    end
    """
    |> format_source()
  end

  defp render_simulator_definition_options_literal(definition_options) do
    definition_options
    |> wrap_simulator_signal_name_literals()
    |> render_literal()
  end

  defp wrap_simulator_signal_name_literals(definition_options) do
    definition_options
    |> maybe_wrap_direction_names(:input_names)
    |> maybe_wrap_direction_names(:output_names)
    |> maybe_wrap_signal_specs()
  end

  defp maybe_wrap_direction_names(definition_options, key) do
    case Keyword.fetch(definition_options, key) do
      {:ok, names} when is_list(names) ->
        Keyword.put(
          definition_options,
          key,
          Enum.map(names, &{:__signal_name__, :literal, &1})
        )

      _ ->
        definition_options
    end
  end

  defp maybe_wrap_signal_specs(definition_options) do
    case Keyword.fetch(definition_options, :signals) do
      {:ok, signals} when is_map(signals) ->
        wrapped_signals =
          Enum.into(signals, %{}, fn {name, spec} ->
            {{:__signal_name__, :literal, name}, spec}
          end)

        Keyword.put(definition_options, :signals, wrapped_signals)

      _ ->
        definition_options
    end
  end

  defp render_literal({:__signal_name__, :literal, name}), do: signal_name_literal(name)

  defp render_literal(%module{} = struct) do
    "%" <>
      inspect(module) <>
      render_struct_body(Map.from_struct(struct))
  end

  defp render_literal(map) when is_map(map) do
    "%{" <>
      (map
       |> Enum.map(fn {key, value} -> "#{render_literal(key)} => #{render_literal(value)}" end)
       |> Enum.join(", ")) <> "}"
  end

  defp render_literal(list) when is_list(list) do
    if Keyword.keyword?(list) do
      "[" <>
        (list
         |> Enum.map(fn {key, value} ->
           "#{render_keyword_key(key)}: #{render_literal(value)}"
         end)
         |> Enum.join(", ")) <> "]"
    else
      "[" <> Enum.map_join(list, ", ", &render_literal/1) <> "]"
    end
  end

  defp render_literal(tuple) when is_tuple(tuple) do
    "{" <>
      (tuple
       |> Tuple.to_list()
       |> Enum.map_join(", ", &render_literal/1)) <> "}"
  end

  defp render_literal(value) when is_atom(value), do: inspect(value)
  defp render_literal(value) when is_binary(value), do: inspect(value)
  defp render_literal(value) when is_integer(value), do: inspect(value)
  defp render_literal(value) when is_float(value), do: inspect(value)
  defp render_literal(value) when is_boolean(value), do: inspect(value)
  defp render_literal(nil), do: "nil"

  defp render_struct_body(map) do
    "{" <>
      (map
       |> Enum.map(fn {key, value} -> "#{render_map_key(key)}: #{render_literal(value)}" end)
       |> Enum.join(", ")) <> "}"
  end

  defp render_map_key(key) when is_atom(key), do: render_keyword_key(key)
  defp render_map_key(key), do: render_literal(key)

  defp render_keyword_key(key) when is_atom(key) do
    key
    |> atom_key_literal()
  end

  defp atom_key_literal(atom) do
    value = Atom.to_string(atom)

    if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*[!?]?$/, value) do
      value
    else
      inspect(atom)
    end
  end

  defp signal_name_literal(name) when is_atom(name), do: inspect(name)

  defp signal_name_literal(name) when is_binary(name) do
    trimmed = String.trim(name)

    if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*[!?]?$/, trimmed) do
      ":" <> trimmed
    else
      ":" <> inspect(trimmed)
    end
  end

  defp signal_name_key_literal(name) when is_atom(name), do: atom_key_literal(name)

  defp signal_name_key_literal(name) when is_binary(name) do
    trimmed = String.trim(name)

    if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*[!?]?$/, trimmed) do
      trimmed
    else
      ":" <> inspect(trimmed)
    end
  end

  defp format_source(source) do
    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  rescue
    _ -> source
  end

  defp render_module_name(module) when is_atom(module), do: inspect(module)
  defp render_module_name(module) when is_binary(module), do: module

  defp relative_path_from(from_dir, to_path) do
    from_segments = split_path_segments(Path.expand(from_dir))
    to_segments = split_path_segments(Path.expand(to_path))
    common_length = common_prefix_length(from_segments, to_segments)

    up_segments =
      from_segments
      |> Enum.drop(common_length)
      |> Enum.map(fn _segment -> ".." end)

    down_segments = Enum.drop(to_segments, common_length)

    case up_segments ++ down_segments do
      [] -> "."
      segments -> Path.join(segments)
    end
  end

  defp split_path_segments(path) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 == "/"))
  end

  defp common_prefix_length(left, right), do: common_prefix_length(left, right, 0)

  defp common_prefix_length([segment | left_rest], [segment | right_rest], length) do
    common_prefix_length(left_rest, right_rest, length + 1)
  end

  defp common_prefix_length(_left, _right, length), do: length

  defp decode_capture(contents) do
    with {:ok, payload} <- capture_payload(contents),
         {:ok, binary} <- decode_capture_payload(payload),
         {:ok, capture} <- binary_to_capture(binary) do
      {:ok, capture}
    end
  end

  defp capture_payload(contents) do
    payload =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.join("")

    if payload == "", do: {:error, :missing_payload}, else: {:ok, payload}
  end

  defp decode_capture_payload(payload) do
    case Base.decode64(payload, padding: false) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp binary_to_capture(binary) do
    try do
      case :erlang.binary_to_term(binary, [:safe]) do
        %{format: @capture_format} = capture ->
          {:ok, capture}

        other ->
          {:error, {:unexpected_term, other}}
      end
    rescue
      ArgumentError ->
        {:error, :invalid_term_encoding}
    catch
      :error, :badarg ->
        {:error, :invalid_term_encoding}
    end
  end

  defp write_generated_file(path, contents, overwrite?) do
    cond do
      File.exists?(path) and not overwrite? ->
        {:error, {:already_exists, path}}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, contents) do
          :ok
        end
    end
  end

  defp maybe_add_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_add_warning(warnings, false, _warning), do: warnings

  defp safe_slug(name) when is_atom(name), do: safe_slug(Atom.to_string(name))

  defp safe_slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "slave"
      slug -> slug
    end
  end

  defp chunk_text(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    text
    |> String.to_charlist()
    |> Enum.chunk_every(width)
    |> Enum.map_join("\n", &to_string/1)
  end

  defp captured_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp hex(value, width) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
