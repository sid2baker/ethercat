defmodule EtherCAT.Slave.ProcessDataSignal do
  @moduledoc """
  Declarative mapping of one logical process-data signal to a PDO or slice of a PDO.

  A signal always belongs to exactly one PDO object (`0x1600+` or `0x1A00+`), as
  described by the slave's SII/ESI mapping. By default the signal spans the whole
  PDO. `bit_offset` and `bit_size` may be used to expose a smaller field inside
  that PDO when the driver knows the entry layout.
  """

  @type t :: %__MODULE__{
          pdo_index: non_neg_integer(),
          bit_offset: non_neg_integer(),
          bit_size: pos_integer() | nil
        }

  @enforce_keys [:pdo_index]
  defstruct [:pdo_index, bit_offset: 0, bit_size: nil]

  @spec whole_pdo(non_neg_integer()) :: t()
  def whole_pdo(pdo_index) when is_integer(pdo_index) and pdo_index >= 0 do
    %__MODULE__{pdo_index: pdo_index}
  end

  @spec slice(non_neg_integer(), non_neg_integer(), pos_integer()) :: t()
  def slice(pdo_index, bit_offset, bit_size)
      when is_integer(pdo_index) and pdo_index >= 0 and is_integer(bit_offset) and bit_offset >= 0 and
             is_integer(bit_size) and bit_size > 0 do
    %__MODULE__{pdo_index: pdo_index, bit_offset: bit_offset, bit_size: bit_size}
  end
end
