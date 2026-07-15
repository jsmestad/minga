defmodule Minga.Extension.Artifact do
  @moduledoc """
  Validated BEAM artifact emitted by isolated extension compilation.

  Module identity is read from BEAM metadata only after the atom table has
  passed the inventory resource limits. The path always points at a private
  staging or admitted cache directory.
  """

  @enforce_keys [
    :module,
    :module_name,
    :filename,
    :path,
    :bytecode,
    :digest,
    :byte_size,
    :atom_count
  ]
  defstruct [:module, :module_name, :filename, :path, :bytecode, :digest, :byte_size, :atom_count]

  @type t :: %__MODULE__{
          module: module(),
          module_name: String.t(),
          filename: String.t(),
          path: String.t(),
          bytecode: binary(),
          digest: binary(),
          byte_size: non_neg_integer(),
          atom_count: non_neg_integer()
        }
end
