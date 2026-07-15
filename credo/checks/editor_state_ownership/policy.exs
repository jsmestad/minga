defmodule Minga.Credo.EditorStateOwnership.Policy do
  @moduledoc """
  Fully validated ownership and purity policy used by EX9012.

  Rules receive this value rather than raw keyword configuration, so malformed
  policy can never partially weaken a source scan.
  """

  alias Minga.Credo.EditorStateOwnership.Ownership

  @enforce_keys [
    :ownerships,
    :pure_modules,
    :process_modules,
    :boundary_prefixes,
    :boundary_segments,
    :value_modules
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ownerships: [Ownership.t()],
          pure_modules: MapSet.t(String.t()),
          process_modules: MapSet.t(String.t()),
          boundary_prefixes: [String.t()],
          boundary_segments: MapSet.t(String.t()),
          value_modules: MapSet.t(String.t())
        }

  @doc "Returns the declaration for an exact protected struct."
  @spec ownership_by_struct(t(), String.t() | nil) :: Ownership.t() | nil
  def ownership_by_struct(%__MODULE__{}, nil), do: nil

  def ownership_by_struct(%__MODULE__{ownerships: ownerships}, struct) do
    Enum.find(ownerships, &(&1.struct == struct))
  end

  @doc "Returns the declaration owned by a module."
  @spec ownership_for_owner(t(), String.t() | nil) :: Ownership.t() | nil
  def ownership_for_owner(%__MODULE__{}, nil), do: nil

  def ownership_for_owner(%__MODULE__{ownerships: ownerships}, module) do
    Enum.find(ownerships, &(module in &1.owners))
  end

  @doc "Returns the most-specific declaration matching the end of a receiver path."
  @spec ownership_for_path(t(), [atom()] | nil) :: Ownership.t() | nil
  def ownership_for_path(%__MODULE__{}, nil), do: nil

  def ownership_for_path(%__MODULE__{ownerships: ownerships}, path) do
    ownerships
    |> Enum.flat_map(fn ownership ->
      Enum.map(ownership.paths, fn owned_path -> {ownership, path_rank(path, owned_path)} end)
    end)
    |> Enum.reject(fn {_ownership, rank} -> is_nil(rank) end)
    |> Enum.max_by(fn {_ownership, rank} -> rank end, fn -> {nil, nil} end)
    |> elem(0)
  end

  @doc "Returns the most-specific declaration occurring anywhere in a nested access path."
  @spec ownership_for_nested_path(t(), [atom()] | nil) :: Ownership.t() | nil
  def ownership_for_nested_path(%__MODULE__{}, nil), do: nil

  def ownership_for_nested_path(%__MODULE__{ownerships: ownerships}, path) do
    ownerships
    |> Enum.flat_map(fn ownership ->
      Enum.map(ownership.paths, fn owned_path ->
        {ownership, nested_path_rank(path, owned_path)}
      end)
    end)
    |> Enum.reject(fn {_ownership, rank} -> is_nil(rank) end)
    |> Enum.max_by(fn {_ownership, rank} -> rank end, fn -> {nil, nil} end)
    |> elem(0)
  end

  @doc "Returns whether a module is an explicitly declared value boundary."
  @spec value_module?(t(), String.t()) :: boolean()
  def value_module?(%__MODULE__{} = policy, module) do
    MapSet.member?(policy.value_modules, module) or
      Enum.any?(policy.ownerships, &(module in &1.owners))
  end

  @doc "Returns whether a module owns a value that must remain pure."
  @spec pure_owner?(t(), String.t() | nil) :: boolean()
  def pure_owner?(%__MODULE__{}, nil), do: false
  def pure_owner?(%__MODULE__{pure_modules: modules}, module), do: MapSet.member?(modules, module)

  @spec path_rank([atom()], [atom()]) :: {non_neg_integer(), non_neg_integer()} | nil
  defp path_rank(path, owned_path) do
    if List.ends_with?(path, owned_path), do: {length(path), length(owned_path)}
  end

  @spec nested_path_rank([atom()], [atom()]) :: {non_neg_integer(), non_neg_integer()} | nil
  defp nested_path_rank(_path, []), do: nil

  defp nested_path_rank(path, owned_path) do
    owned_length = length(owned_path)

    path
    |> Enum.chunk_every(owned_length, 1, :discard)
    |> Enum.with_index(owned_length)
    |> Enum.filter(fn {candidate, _end_index} -> candidate == owned_path end)
    |> Enum.map(fn {_candidate, end_index} -> {owned_length, end_index} end)
    |> Enum.max(fn -> nil end)
  end
end
