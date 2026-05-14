defmodule MingaEditor.Shell.Traditional.GitStatus.TuiState do
  @moduledoc """
  TUI-only view state for the traditional git status sidebar.

  The shared git status panel data stays frontend-neutral. This struct tracks
  terminal presentation concerns such as cursor position, collapsed sections,
  and pending TUI confirmations.
  """

  alias Minga.Git.StatusEntry

  @enforce_keys [:cursor_index, :collapsed]
  defstruct [
    :cursor_index,
    :collapsed,
    discard_confirmation: nil,
    amend_mode: false
  ]

  @type flat_entry ::
          {:section_header, atom(), non_neg_integer()}
          | {:file, atom(), StatusEntry.t()}

  @type discard_confirmation ::
          {StatusEntry.t(), String.t()} | nil

  @type t :: %__MODULE__{
          cursor_index: non_neg_integer(),
          collapsed: %{atom() => true},
          discard_confirmation: discard_confirmation(),
          amend_mode: boolean()
        }

  @sections [:conflicts, :staged, :changes, :untracked]

  @doc "Builds initial TUI view state."
  @spec new() :: t()
  def new do
    %__MODULE__{cursor_index: 0, collapsed: %{}}
  end

  @doc "Moves the cursor to the next visible row."
  @spec next(t(), [StatusEntry.t()]) :: t()
  def next(%__MODULE__{} = tui, entries) when is_list(entries) do
    next_idx = min(tui.cursor_index + 1, length(flat_entries(tui, entries)) - 1)
    %{tui | cursor_index: max(next_idx, 0)}
  end

  @doc "Moves the cursor to the previous visible row."
  @spec prev(t()) :: t()
  def prev(%__MODULE__{} = tui) do
    %{tui | cursor_index: max(tui.cursor_index - 1, 0)}
  end

  @doc "Moves the cursor to the next section header."
  @spec next_section(t(), [StatusEntry.t()]) :: t()
  def next_section(%__MODULE__{} = tui, entries) when is_list(entries) do
    next = find_next_section(flat_entries(tui, entries), tui.cursor_index)
    %{tui | cursor_index: next}
  end

  @doc "Moves the cursor to the previous section header."
  @spec prev_section(t(), [StatusEntry.t()]) :: t()
  def prev_section(%__MODULE__{} = tui, entries) when is_list(entries) do
    prev = find_prev_section(flat_entries(tui, entries), tui.cursor_index)
    %{tui | cursor_index: prev}
  end

  @doc "Toggles the currently selected section when the cursor is on a section header."
  @spec toggle_current_section(t(), [StatusEntry.t()]) :: t()
  def toggle_current_section(%__MODULE__{} = tui, entries) when is_list(entries) do
    case current_entry(tui, entries) do
      {:section_header, section, _count} ->
        %{tui | collapsed: toggle_collapsed(tui.collapsed, section)}

      _ ->
        tui
    end
  end

  @doc "Stores the pending destructive discard confirmation."
  @spec request_discard(t(), StatusEntry.t(), String.t()) :: t()
  def request_discard(%__MODULE__{} = tui, %StatusEntry{} = entry, git_root)
      when is_binary(git_root) do
    %{tui | discard_confirmation: {entry, git_root}}
  end

  @doc "Clears pending discard confirmation state."
  @spec clear_discard_confirmation(t()) :: t()
  def clear_discard_confirmation(%__MODULE__{} = tui), do: %{tui | discard_confirmation: nil}

  @doc "Toggles amend mode for the TUI panel."
  @spec toggle_amend(t()) :: t()
  def toggle_amend(%__MODULE__{} = tui), do: %{tui | amend_mode: not tui.amend_mode}

  @doc "Returns the selected file entry, if the cursor is on a file row."
  @spec selected_file(t(), [StatusEntry.t()]) :: StatusEntry.t() | nil
  def selected_file(%__MODULE__{} = tui, entries) when is_list(entries) do
    case current_entry(tui, entries) do
      {:file, _section, entry} -> entry
      _ -> nil
    end
  end

  @doc "Clamps cursor position after the shared git entry list changes."
  @spec refresh(t(), [StatusEntry.t()]) :: t()
  def refresh(%__MODULE__{} = tui, entries) when is_list(entries) do
    tui
    |> clear_discard_confirmation()
    |> clamp_cursor(entries)
  end

  @doc "Returns the flattened rows rendered by the TUI sidebar."
  @spec flat_entries(t(), [StatusEntry.t()]) :: [flat_entry()]
  def flat_entries(%__MODULE__{} = tui, entries) when is_list(entries) do
    Enum.flat_map(@sections, fn section_name ->
      is_collapsed = Map.has_key?(tui.collapsed, section_name)
      build_section_entries(entries, section_name, is_collapsed)
    end)
  end

  @doc "Returns the flattened row at the current cursor."
  @spec current_entry(t(), [StatusEntry.t()]) :: flat_entry() | nil
  def current_entry(%__MODULE__{} = tui, entries) when is_list(entries) do
    tui
    |> flat_entries(entries)
    |> Enum.at(tui.cursor_index)
  end

  @doc "Clamps cursor position to the current flattened entry list."
  @spec clamp_cursor(t(), [StatusEntry.t()]) :: t()
  def clamp_cursor(%__MODULE__{} = tui, entries) when is_list(entries) do
    max_index = max(length(flat_entries(tui, entries)) - 1, 0)
    %{tui | cursor_index: min(tui.cursor_index, max_index)}
  end

  @spec toggle_collapsed(%{atom() => true}, atom()) :: %{atom() => true}
  defp toggle_collapsed(collapsed, section) do
    if Map.has_key?(collapsed, section) do
      Map.delete(collapsed, section)
    else
      Map.put(collapsed, section, true)
    end
  end

  @spec find_next_section([flat_entry()], non_neg_integer()) :: non_neg_integer()
  defp find_next_section(flat_entries, current_idx) do
    result =
      flat_entries
      |> Enum.with_index()
      |> Enum.find(fn
        {{:section_header, _, _}, idx} -> idx > current_idx
        _ -> false
      end)

    case result do
      {_, idx} -> idx
      nil -> current_idx
    end
  end

  @spec find_prev_section([flat_entry()], non_neg_integer()) :: non_neg_integer()
  defp find_prev_section(flat_entries, current_idx) do
    result =
      flat_entries
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn
        {{:section_header, _, _}, idx} -> idx < current_idx
        _ -> false
      end)

    case result do
      {_, idx} -> idx
      nil -> 0
    end
  end

  @spec build_section_entries([StatusEntry.t()], atom(), boolean()) :: [flat_entry()]
  defp build_section_entries(entries, section_name, is_collapsed) do
    section_entries = section_entries(entries, section_name)

    case section_entries do
      [] ->
        []

      _ ->
        header = [{:section_header, section_name, length(section_entries)}]

        if is_collapsed do
          header
        else
          file_entries = Enum.map(section_entries, &{:file, section_name, &1})
          header ++ file_entries
        end
    end
  end

  @spec section_entries([StatusEntry.t()], atom()) :: [StatusEntry.t()]
  defp section_entries(entries, :conflicts), do: Enum.filter(entries, &(&1.status == :conflict))

  defp section_entries(entries, :staged) do
    Enum.filter(entries, &(&1.staged and &1.status != :conflict and &1.status != :untracked))
  end

  defp section_entries(entries, :changes) do
    Enum.filter(entries, &(not &1.staged and &1.status != :conflict and &1.status != :untracked))
  end

  defp section_entries(entries, :untracked), do: Enum.filter(entries, &(&1.status == :untracked))
  defp section_entries(_entries, _section), do: []
end
