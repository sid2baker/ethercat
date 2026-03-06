defmodule EtherCAT.Domain.Layout.CyclePlan do
  @moduledoc false

  @type output_patch :: {non_neg_integer(), pos_integer(), {atom(), term()}}
  @type input_slice :: {non_neg_integer(), pos_integer(), {atom(), term()}, pid()}

  @type t :: %__MODULE__{
          image_size: non_neg_integer(),
          output_patches: [output_patch()],
          input_slices: [input_slice()],
          expected_wkc: non_neg_integer()
        }

  @enforce_keys [:image_size, :output_patches, :input_slices, :expected_wkc]
  defstruct [:image_size, :output_patches, :input_slices, :expected_wkc]
end

defmodule EtherCAT.Domain.Layout do
  @moduledoc false

  alias EtherCAT.Domain.Layout.CyclePlan

  @type pdo_key :: {atom(), term()}
  @type output_patch :: CyclePlan.output_patch()
  @type input_slice :: CyclePlan.input_slice()

  @type t :: %__MODULE__{
          image_size: non_neg_integer(),
          output_patches_rev: [output_patch()],
          input_slices_rev: [input_slice()],
          output_slave_names: MapSet.t(atom()),
          input_slave_names: MapSet.t(atom())
        }

  # One LRW datagram must fit within the 2047-byte EtherCAT payload limit.
  # LRW data consumes 10 bytes of datagram header and 2 bytes of WKC.
  @max_lrw_image_bytes 2035

  defstruct image_size: 0,
            output_patches_rev: [],
            input_slices_rev: [],
            output_slave_names: MapSet.new(),
            input_slave_names: MapSet.new()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec register(t(), pdo_key(), pos_integer(), :input | :output, pid() | nil) ::
          {non_neg_integer(), t()}
  def register(%__MODULE__{} = layout, {slave_name, _pdo_name} = key, size, :output, _slave_pid) do
    offset = layout.image_size

    {offset,
     %{
       layout
       | image_size: offset + size,
         output_patches_rev: [{offset, size, key} | layout.output_patches_rev],
         output_slave_names: MapSet.put(layout.output_slave_names, slave_name)
     }}
  end

  def register(%__MODULE__{} = layout, {slave_name, _pdo_name} = key, size, :input, slave_pid)
      when is_pid(slave_pid) do
    offset = layout.image_size

    {offset,
     %{
       layout
       | image_size: offset + size,
         input_slices_rev: [{offset, size, key, slave_pid} | layout.input_slices_rev],
         input_slave_names: MapSet.put(layout.input_slave_names, slave_name)
     }}
  end

  @spec image_size(t()) :: non_neg_integer()
  def image_size(%__MODULE__{image_size: image_size}), do: image_size

  @spec expected_wkc(t()) :: non_neg_integer()
  def expected_wkc(%__MODULE__{} = layout) do
    MapSet.size(layout.output_slave_names) * 2 + MapSet.size(layout.input_slave_names)
  end

  @spec prepare(t()) ::
          {:ok, CyclePlan.t()}
          | {:error, :nothing_registered | {:image_too_large, integer(), integer()}}
  def prepare(%__MODULE__{image_size: 0}), do: {:error, :nothing_registered}

  def prepare(%__MODULE__{image_size: image_size}) when image_size > @max_lrw_image_bytes do
    {:error, {:image_too_large, image_size, @max_lrw_image_bytes}}
  end

  def prepare(%__MODULE__{} = layout) do
    {:ok,
     %CyclePlan{
       image_size: layout.image_size,
       output_patches: Enum.reverse(layout.output_patches_rev),
       input_slices: Enum.reverse(layout.input_slices_rev),
       expected_wkc: expected_wkc(layout)
     }}
  end
end
