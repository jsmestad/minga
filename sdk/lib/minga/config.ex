defmodule Minga.Config do
  @moduledoc "Reads editor configuration from extension callbacks. The SDK declaration is compile-time only."

  @type type_descriptor ::
          :pos_integer
          | :non_neg_integer
          | :integer
          | :boolean
          | :atom
          | {:enum, [atom()]}
          | :theme_atom
          | :string
          | :string_or_nil
          | :string_list
          | :atom_list
          | :map_or_nil
          | :map_list
          | :float_or_nil
          | :any

  @doc "Returns the configured value for the named extension option."
  @spec get_extension_option(atom(), atom()) :: term()
  def get_extension_option(_extension, _option), do: raise("minga_sdk is compile-time only")
end
