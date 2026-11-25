defmodule Minga.Session.Snapshot do
  @moduledoc """
  A session snapshot capturing the editor's restorable window state.

  Built from editor state when saving a session (`MingaEditor.Session.Capture`), and decoded when restoring. It holds what the window held and nothing else: the open files with their cursors, the window splits with each window's file, cursor and scroll (`layout`), which window had focus (`active_pane`, an index into the layout's panes in leaf order) and the active file. Minga's tasks are not part of it: they outlive windows.

  Version 2 adds `project_root`, `layout` and `active_pane`. A version 1 file decodes with no layout, and a restore then opens its files in one window.
  """

  alias Minga.Session.BufferEntry
  alias Minga.Session.Layout

  @current_version 2

  @typedoc "A session snapshot."
  @type t :: %__MODULE__{
          version: pos_integer(),
          project_root: String.t() | nil,
          buffers: [BufferEntry.t()],
          active_file: String.t() | nil,
          layout: Layout.t() | nil,
          active_pane: non_neg_integer(),
          clean_shutdown: boolean()
        }

  @enforce_keys [:version]
  defstruct version: @current_version,
            project_root: nil,
            buffers: [],
            active_file: nil,
            layout: nil,
            active_pane: 0,
            clean_shutdown: false

  @doc "The version new snapshots are written with."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The number of files a restore reopens."
  @spec file_count(t()) :: non_neg_integer()
  def file_count(%__MODULE__{buffers: buffers}), do: length(buffers)

  @doc "Encodes the snapshot as a JSON-ready map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "version" => snapshot.version,
      "project_root" => snapshot.project_root,
      "buffers" => Enum.map(snapshot.buffers, &buffer_to_map/1),
      "active_file" => snapshot.active_file,
      "layout" => layout_to_map(snapshot.layout),
      "active_pane" => snapshot.active_pane,
      "clean_shutdown" => snapshot.clean_shutdown
    }
  end

  @doc """
  Decodes a snapshot from its JSON map.

  Missing optional fields get defaults, so older files load. A malformed layout is dropped rather than failing the whole snapshot: the files still reopen, in one window.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, :invalid_format}
  def from_map(%{"buffers" => buffers} = raw) when is_list(buffers) do
    {:ok,
     %__MODULE__{
       version: positive(raw["version"], 1),
       project_root: string_or_nil(raw["project_root"]),
       buffers: Enum.flat_map(buffers, &buffer_from_map/1),
       active_file: string_or_nil(raw["active_file"]),
       layout: layout_from_map(raw["layout"]),
       active_pane: non_neg(raw["active_pane"]),
       clean_shutdown: raw["clean_shutdown"] == true
     }}
  end

  def from_map(_raw), do: {:error, :invalid_format}

  @spec buffer_to_map(BufferEntry.t()) :: map()
  defp buffer_to_map(%BufferEntry{} = entry) do
    %{"file" => entry.file, "cursor_line" => entry.cursor_line, "cursor_col" => entry.cursor_col}
  end

  @spec buffer_from_map(term()) :: [BufferEntry.t()]
  defp buffer_from_map(%{"file" => file} = map) when is_binary(file) and file != "" do
    [
      %BufferEntry{
        file: file,
        cursor_line: non_neg(map["cursor_line"]),
        cursor_col: non_neg(map["cursor_col"])
      }
    ]
  end

  defp buffer_from_map(_other), do: []

  @spec layout_to_map(Layout.t() | nil) :: map() | nil
  defp layout_to_map(nil), do: nil
  defp layout_to_map(layout), do: Layout.to_map(layout)

  @spec layout_from_map(term()) :: Layout.t() | nil
  defp layout_from_map(nil), do: nil

  defp layout_from_map(map) do
    case Layout.from_map(map) do
      {:ok, layout} -> layout
      :error -> nil
    end
  end

  @spec string_or_nil(term()) :: String.t() | nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  @spec positive(term(), pos_integer()) :: pos_integer()
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  @spec non_neg(term()) :: non_neg_integer()
  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: 0
end
