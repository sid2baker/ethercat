defmodule EtherCAT.Simulator.Slave.Definition do
  @moduledoc """
  Public authored definition for a simulated EtherCAT slave.

  A definition describes the high-level device identity, process-data layout,
  mailbox/object-dictionary capabilities, and behavior module. Derived low-level
  ESC state such as EEPROM contents and register memory is hydrated internally
  by the simulator runtime and is not part of this public type.
  """

  alias EtherCAT.Simulator.Slave.Object
  alias EtherCAT.Simulator.Slave.Profile
  alias EtherCAT.Driver.Runtime, as: DriverRuntime
  alias EtherCAT.Simulator.Driver, as: SimulatorDriver

  @typedoc "Mailbox SM layout declared by the simulated device."
  @type mailbox_config :: %{
          recv_offset: non_neg_integer(),
          recv_size: non_neg_integer(),
          send_offset: non_neg_integer(),
          send_size: non_neg_integer()
        }

  @typedoc "High-level, authored simulator device definition."
  @opaque t :: %__MODULE__{
            name: atom(),
            profile: atom(),
            behavior: module(),
            vendor_id: non_neg_integer(),
            product_code: non_neg_integer(),
            revision: non_neg_integer(),
            serial_number: non_neg_integer(),
            esc_type: byte(),
            fmmu_count: pos_integer(),
            sm_count: pos_integer(),
            output_phys: non_neg_integer(),
            output_size: non_neg_integer(),
            input_phys: non_neg_integer(),
            input_size: non_neg_integer(),
            mirror_output_to_input?: boolean(),
            pdo_entries: [map()],
            signals: %{optional(atom()) => map()},
            mailbox_config: mailbox_config(),
            objects: %{optional({non_neg_integer(), non_neg_integer()}) => Object.t()},
            dc_capable?: boolean()
          }

  @enforce_keys [
    :name,
    :profile,
    :behavior,
    :vendor_id,
    :product_code,
    :revision,
    :serial_number,
    :esc_type,
    :fmmu_count,
    :sm_count,
    :output_phys,
    :output_size,
    :input_phys,
    :input_size,
    :mirror_output_to_input?,
    :pdo_entries,
    :signals,
    :mailbox_config,
    :objects,
    :dc_capable?
  ]
  defstruct @enforce_keys

  @spec build(atom(), keyword()) :: t()
  def build(profile, opts \\ []) do
    profile_spec = Profile.spec(profile, opts)
    name = Keyword.get(opts, :name, :sim)
    vendor_id = Keyword.get(opts, :vendor_id, profile_spec.vendor_id)
    product_code = Keyword.get(opts, :product_code, profile_spec.product_code)
    revision = Keyword.get(opts, :revision, profile_spec.revision)
    serial_number = Keyword.get(opts, :serial_number, profile_spec.serial_number)
    esc_type = Keyword.get(opts, :esc_type, profile_spec.esc_type)
    fmmu_count = Keyword.get(opts, :fmmu_count, profile_spec.fmmu_count)
    sm_count = Keyword.get(opts, :sm_count, profile_spec.sm_count)
    output_phys = Keyword.get(opts, :output_phys, profile_spec.output_phys)
    output_size = Keyword.get(opts, :output_size, profile_spec.output_size)
    input_phys = Keyword.get(opts, :input_phys, profile_spec.input_phys)
    input_size = Keyword.get(opts, :input_size, profile_spec.input_size)

    mirror_output_to_input? =
      Keyword.get(opts, :mirror_output_to_input?, profile_spec.mirror_output_to_input?)

    mailbox_config = Keyword.get(opts, :mailbox_config, profile_spec.mailbox_config)
    objects = Keyword.get(opts, :objects, profile_spec.objects)
    pdo_entries = Keyword.get(opts, :pdo_entries, profile_spec.pdo_entries)
    signals = Keyword.get(opts, :signals, profile_spec.signals)
    dc_capable? = Keyword.get(opts, :dc_capable?, profile_spec.dc_capable?)
    behavior = Keyword.get(opts, :behavior, profile_spec.behavior)

    %__MODULE__{
      name: name,
      profile: profile_spec.profile,
      behavior: behavior,
      vendor_id: vendor_id,
      product_code: product_code,
      revision: revision,
      serial_number: serial_number,
      esc_type: esc_type,
      fmmu_count: fmmu_count,
      sm_count: sm_count,
      output_phys: output_phys,
      output_size: output_size,
      input_phys: input_phys,
      input_size: input_size,
      mirror_output_to_input?: mirror_output_to_input?,
      pdo_entries: pdo_entries,
      signals: signals,
      mailbox_config: mailbox_config,
      objects: objects,
      dc_capable?: dc_capable?
    }
  end

  @spec from_driver(module(), map(), module()) :: t()
  def from_driver(driver, config, adapter)
      when is_atom(driver) and is_map(config) and is_atom(adapter) do
    opts =
      adapter
      |> EtherCAT.Simulator.DriverAdapter.definition_options(config)
      |> normalize_definition_options!(adapter)
      |> merge_driver_identity(driver)
      |> maybe_strip_process_data(driver, config)

    profile = Keyword.fetch!(opts, :profile)
    opts = Keyword.delete(opts, :profile)
    build(profile, opts)
  end

  defp normalize_definition_options!(opts, _adapter) when is_list(opts), do: opts

  defp normalize_definition_options!(other, adapter) do
    raise ArgumentError,
          "simulator adapter #{inspect(adapter)} must return keyword definition options, got: #{inspect(other)}"
  end

  defp merge_driver_identity(opts, driver) do
    case SimulatorDriver.identity(driver) do
      %{vendor_id: vendor_id, product_code: product_code, revision: revision} ->
        opts
        |> Keyword.put_new(:vendor_id, vendor_id)
        |> Keyword.put_new(:product_code, product_code)
        |> maybe_put_identity_revision(revision)

      nil ->
        opts
    end
  end

  defp maybe_put_identity_revision(opts, revision)
       when is_integer(revision) and revision >= 0 do
    Keyword.put_new(opts, :revision, revision)
  end

  defp maybe_put_identity_revision(opts, _revision), do: opts

  defp maybe_strip_process_data(opts, driver, config) do
    case DriverRuntime.signal_model(driver, config) do
      [] ->
        opts
        |> Keyword.put(:signals, %{})
        |> Keyword.put(:pdo_entries, [])
        |> Keyword.put(:output_size, 0)
        |> Keyword.put(:input_size, 0)
        |> Keyword.put(:mirror_output_to_input?, false)

      _signals ->
        opts
    end
  end
end
