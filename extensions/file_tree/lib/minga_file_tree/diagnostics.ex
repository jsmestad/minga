defmodule MingaFileTree.Diagnostics do
  @moduledoc """
  Diagnostic status carried by a semantic file-tree row.

  Rows keep diagnostic counts separate from dirty and git state so renderers can show each status independently without re-querying LSP or diagnostics state.
  """

  @type severity :: :error | :warning | :info | :hint
  @type counts :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          error_count: non_neg_integer(),
          warning_count: non_neg_integer(),
          info_count: non_neg_integer(),
          hint_count: non_neg_integer()
        }

  @map_keys [
    :error_count,
    :warning_count,
    :info_count,
    :hint_count,
    :error,
    :warning,
    :info,
    :hint,
    :errors,
    :warnings,
    :hints
  ]

  defstruct error_count: 0,
            warning_count: 0,
            info_count: 0,
            hint_count: 0

  @doc "Returns an empty diagnostic status."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Builds diagnostic status from a count tuple, map, keyword list, or existing struct."
  @spec new(t() | counts() | map() | keyword() | nil) :: t()
  def new(%__MODULE__{} = diagnostics), do: diagnostics

  def new({errors, warnings, info, hints}) do
    %__MODULE__{
      error_count: max(errors, 0),
      warning_count: max(warnings, 0),
      info_count: max(info, 0),
      hint_count: max(hints, 0)
    }
  end

  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    validate_map_keys!(attrs)

    %__MODULE__{
      error_count:
        max(Map.get(attrs, :error_count, Map.get(attrs, :errors, Map.get(attrs, :error, 0))), 0),
      warning_count:
        max(
          Map.get(attrs, :warning_count, Map.get(attrs, :warnings, Map.get(attrs, :warning, 0))),
          0
        ),
      info_count: max(Map.get(attrs, :info_count, Map.get(attrs, :info, 0)), 0),
      hint_count:
        max(Map.get(attrs, :hint_count, Map.get(attrs, :hints, Map.get(attrs, :hint, 0))), 0)
    }
  end

  def new(nil), do: empty()

  @spec validate_map_keys!(map()) :: :ok
  defp validate_map_keys!(attrs) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in @map_keys))
    |> raise_on_unknown_keys()
  end

  @spec raise_on_unknown_keys([term()]) :: :ok
  defp raise_on_unknown_keys([]), do: :ok

  defp raise_on_unknown_keys(keys) do
    raise ArgumentError, "unknown file-tree diagnostic keys: #{inspect(keys)}"
  end

  @doc "Returns the total number of diagnostics."
  @spec total_count(t()) :: non_neg_integer()
  def total_count(%__MODULE__{} = diagnostics) do
    diagnostics.error_count + diagnostics.warning_count + diagnostics.info_count +
      diagnostics.hint_count
  end

  @doc "Returns the highest severity represented by the counts."
  @spec highest_severity(t()) :: severity() | nil
  def highest_severity(%__MODULE__{error_count: count}) when count > 0, do: :error
  def highest_severity(%__MODULE__{warning_count: count}) when count > 0, do: :warning
  def highest_severity(%__MODULE__{info_count: count}) when count > 0, do: :info
  def highest_severity(%__MODULE__{hint_count: count}) when count > 0, do: :hint
  def highest_severity(%__MODULE__{}), do: nil

  @doc "Returns the count for a severity."
  @spec count_for(t(), severity()) :: non_neg_integer()
  def count_for(%__MODULE__{} = diagnostics, :error), do: diagnostics.error_count
  def count_for(%__MODULE__{} = diagnostics, :warning), do: diagnostics.warning_count
  def count_for(%__MODULE__{} = diagnostics, :info), do: diagnostics.info_count
  def count_for(%__MODULE__{} = diagnostics, :hint), do: diagnostics.hint_count

  @doc "Merges two diagnostic count sets."
  @spec merge(t() | counts() | map() | keyword() | nil, t() | counts() | map() | keyword() | nil) ::
          t()
  def merge(left, right) do
    left = new(left)
    right = new(right)

    %__MODULE__{
      error_count: left.error_count + right.error_count,
      warning_count: left.warning_count + right.warning_count,
      info_count: left.info_count + right.info_count,
      hint_count: left.hint_count + right.hint_count
    }
  end

  @doc "Returns counts as the file-tree wire tuple."
  @spec to_tuple(t()) :: counts()
  def to_tuple(%__MODULE__{} = diagnostics) do
    {diagnostics.error_count, diagnostics.warning_count, diagnostics.info_count,
     diagnostics.hint_count}
  end
end
