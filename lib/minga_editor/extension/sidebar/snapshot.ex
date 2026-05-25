defmodule MingaEditor.Extension.Sidebar.Snapshot do
  @moduledoc """
  Cached semantic sidebar content published by an extension.

  Extensions update snapshots when their own state changes. Layout, TUI rendering, and GUI emit code read these values directly from the sidebar registry, so frame rendering never calls arbitrary extension callbacks.
  """

  @typedoc "Semantic row rendered by generic sidebar surfaces."
  @type row :: %{
          optional(:id) => String.t(),
          optional(:text) => String.t(),
          optional(:icon) => String.t() | nil,
          optional(:indent) => non_neg_integer(),
          optional(:selected?) => boolean(),
          optional(:active?) => boolean(),
          optional(:badge) => String.t() | nil,
          optional(:git_status) => atom() | String.t() | nil,
          optional(:diagnostic_count) => non_neg_integer()
        }

  @typedoc "Sidebar loading/error state."
  @type status :: :ready | :loading | :error | :empty

  @typedoc "Cached snapshot state."
  @type t :: %__MODULE__{
          rows: [row()],
          status: status(),
          message: String.t() | nil,
          structural_fingerprint: non_neg_integer(),
          selection_fingerprint: non_neg_integer(),
          selected_id: String.t() | nil,
          active_id: String.t() | nil
        }

  @enforce_keys [:rows, :structural_fingerprint, :selection_fingerprint]
  defstruct rows: [],
            status: :ready,
            message: nil,
            structural_fingerprint: 0,
            selection_fingerprint: 0,
            selected_id: nil,
            active_id: nil

  @doc "Builds a snapshot and derives fingerprints when they are not provided."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = Map.new(attrs)
    rows = Map.get(attrs, :rows, [])
    selected_id = Map.get(attrs, :selected_id) || selected_row_id(rows)
    active_id = Map.get(attrs, :active_id)
    status = Map.get(attrs, :status, :ready)
    message = Map.get(attrs, :message)

    structural_fp =
      Map.get_lazy(attrs, :structural_fingerprint, fn ->
        structural_fingerprint(rows, status, message)
      end)

    selection_fp =
      Map.get_lazy(attrs, :selection_fingerprint, fn ->
        selection_fingerprint(rows, selected_id, active_id)
      end)

    %__MODULE__{
      rows: rows,
      status: status,
      message: message,
      structural_fingerprint: structural_fp,
      selection_fingerprint: selection_fp,
      selected_id: selected_id,
      active_id: active_id
    }
  end

  @doc "Returns true when two snapshots differ only by selection/focus state."
  @spec selection_only_change?(t(), t()) :: boolean()
  def selection_only_change?(%__MODULE__{} = old, %__MODULE__{} = new) do
    old.structural_fingerprint == new.structural_fingerprint and
      old.selection_fingerprint != new.selection_fingerprint
  end

  @spec structural_fingerprint([row()], status(), String.t() | nil) :: non_neg_integer()
  defp structural_fingerprint(rows, status, message) do
    rows
    |> Enum.map(&structural_row/1)
    |> then(&:erlang.phash2({status, message, &1}))
  end

  @spec selection_fingerprint([row()], String.t() | nil, String.t() | nil) :: non_neg_integer()
  defp selection_fingerprint(rows, selected_id, active_id) do
    selected_rows =
      Enum.map(rows, fn row -> {Map.get(row, :id), Map.get(row, :selected?, false)} end)

    active_rows = Enum.map(rows, fn row -> {Map.get(row, :id), Map.get(row, :active?, false)} end)
    :erlang.phash2({selected_id, active_id, selected_rows, active_rows})
  end

  @spec structural_row(row()) :: tuple()
  defp structural_row(row) do
    {
      Map.get(row, :id),
      Map.get(row, :text, ""),
      Map.get(row, :icon),
      Map.get(row, :indent, 0),
      Map.get(row, :badge),
      Map.get(row, :git_status),
      Map.get(row, :diagnostic_count, 0)
    }
  end

  @spec selected_row_id([row()]) :: String.t() | nil
  defp selected_row_id(rows) do
    rows
    |> Enum.find(&Map.get(&1, :selected?, false))
    |> case do
      nil -> nil
      row -> Map.get(row, :id)
    end
  end
end
