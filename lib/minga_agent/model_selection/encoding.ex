defmodule MingaAgent.ModelSelection.Encoding do
  @moduledoc false

  @doc false
  @spec stringify(term()) :: term()
  def stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  def stringify(value) when is_nil(value) or is_boolean(value), do: value
  def stringify(value) when is_atom(value), do: Atom.to_string(value)
  def stringify(value), do: value
end
