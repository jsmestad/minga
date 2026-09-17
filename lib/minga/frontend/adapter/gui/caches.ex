defmodule Minga.Frontend.Adapter.GUI.Caches do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.AgentTranscriptSentState

  @type fingerprint :: term()

  @type t :: %__MODULE__{
          last_theme_fp: integer() | nil,
          last_breadcrumb_fp: integer() | nil,
          last_which_key_fp: integer() | nil,
          last_notifications_fp: integer() | nil,
          last_search_state_fp: integer() | nil,
          last_git_status_fp: integer() | nil,
          last_agent_context_fp: integer() | nil,
          last_observatory_fp: fingerprint() | nil,
          last_tab_bar_fp: integer() | :suppressed | nil,
          last_workspaces_fp: integer() | :suppressed | nil,
          last_sidebars_fp: integer() | nil,
          last_file_tree_fp: term(),
          last_picker_fp: integer() | :closed | nil,
          last_minibuffer_fp: term(),
          last_completion_fp: fingerprint() | nil,
          last_signature_help_fp: fingerprint() | nil,
          last_agent_chat_fp: integer() | nil,
          last_empty_state_fp: integer() | nil,
          last_agent_transcript: AgentTranscriptSentState.t(),
          last_bottom_panel_fp: integer() | nil,
          last_edit_timeline_fp: integer() | nil,
          last_extension_overlay_fp: fingerprint() | nil,
          last_extension_panel_fp: fingerprint() | nil,
          last_hover_popup_fp: fingerprint() | nil,
          last_float_popup_fp: fingerprint() | nil,
          last_gutter_separator_fp: integer() | nil,
          last_split_separators_fp: integer() | nil,
          last_line_spacing_fp: non_neg_integer() | nil,
          last_cursor_animation_fp: boolean() | nil,
          last_config_state_fp: integer() | nil,
          last_window_content_fps: %{non_neg_integer() => integer()},
          last_window_overlay_fps: %{non_neg_integer() => integer()},
          last_window_gutter_fps: %{non_neg_integer() => term()},
          pending_gutter_ids: MapSet.t(non_neg_integer()),
          last_window_content_epochs: %{non_neg_integer() => non_neg_integer()},
          last_window_row_keys: %{non_neg_integer() => [{non_neg_integer(), non_neg_integer()}]},
          last_resident_row_keys: %{non_neg_integer() => [{non_neg_integer(), non_neg_integer()}]},
          last_window_rows: %{non_neg_integer() => [Minga.RenderModel.Window.Row.t()]},
          pending_window_delta_ids: MapSet.t(non_neg_integer())
        }

  defstruct last_theme_fp: nil,
            last_breadcrumb_fp: nil,
            last_which_key_fp: nil,
            last_notifications_fp: nil,
            last_search_state_fp: nil,
            last_git_status_fp: nil,
            last_agent_context_fp: nil,
            last_observatory_fp: nil,
            last_tab_bar_fp: nil,
            last_workspaces_fp: nil,
            last_sidebars_fp: nil,
            last_file_tree_fp: nil,
            last_picker_fp: nil,
            last_minibuffer_fp: nil,
            last_completion_fp: nil,
            last_signature_help_fp: nil,
            last_agent_chat_fp: nil,
            last_empty_state_fp: nil,
            last_agent_transcript: %AgentTranscriptSentState{},
            last_bottom_panel_fp: nil,
            last_edit_timeline_fp: nil,
            last_extension_overlay_fp: nil,
            last_extension_panel_fp: nil,
            last_hover_popup_fp: nil,
            last_float_popup_fp: nil,
            last_gutter_separator_fp: nil,
            last_split_separators_fp: nil,
            last_line_spacing_fp: nil,
            last_cursor_animation_fp: nil,
            last_config_state_fp: nil,
            last_window_content_fps: %{},
            last_window_overlay_fps: %{},
            last_window_content_epochs: %{},
            last_window_gutter_fps: %{},
            pending_gutter_ids: MapSet.new(),
            last_window_row_keys: %{},
            last_window_rows: %{},
            last_resident_row_keys: %{},
            pending_window_delta_ids: MapSet.new()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records reference candidates while keeping partial resident payloads out of dense snapshot caches."
  @spec record_window_rows(t(), Minga.RenderModel.Window.t()) :: t()
  def record_window_rows(caches, %{row_store_mode: {:resident, _count}} = window) do
    id = window.window_id

    %{
      caches
      | last_window_content_epochs:
          Map.put(caches.last_window_content_epochs, id, window.content_epoch),
        last_resident_row_keys:
          Map.put(
            caches.last_resident_row_keys,
            id,
            Enum.map(window.rows, &{&1.row_id, &1.content_hash})
          ),
        last_window_row_keys: Map.delete(caches.last_window_row_keys, id),
        last_window_rows: Map.delete(caches.last_window_rows, id)
    }
  end

  def record_window_rows(caches, window) do
    id = window.window_id

    %{
      caches
      | last_window_content_epochs:
          Map.put(caches.last_window_content_epochs, id, window.content_epoch),
        last_resident_row_keys: Map.delete(caches.last_resident_row_keys, id),
        last_window_row_keys:
          Map.put(
            caches.last_window_row_keys,
            id,
            Enum.map(window.rows, &{&1.row_id, &1.content_hash})
          ),
        last_window_rows: Map.put(caches.last_window_rows, id, window.rows)
    }
  end

  @doc "Prepares a gutter snapshot or retention instruction against acknowledged content."
  @spec prepare_gutter(
          t(),
          non_neg_integer(),
          Minga.RenderModel.Window.Gutter.t() | nil,
          boolean()
        ) :: {boolean(), t()}
  def prepare_gutter(
        caches,
        id,
        %{entries: %Minga.RenderModel.Window.Gutter.ResidentRows{} = rows},
        full_refresh?
      ) do
    retain? =
      not full_refresh? and Map.get(caches.last_window_gutter_fps, id) == rows and
        not MapSet.member?(caches.pending_gutter_ids, id)

    pending =
      if retain?, do: caches.pending_gutter_ids, else: MapSet.put(caches.pending_gutter_ids, id)

    {retain?,
     %{
       caches
       | last_window_gutter_fps: Map.put(caches.last_window_gutter_fps, id, rows),
         pending_gutter_ids: pending
     }}
  end

  def prepare_gutter(caches, id, _gutter, _full_refresh?) do
    {false,
     %{
       caches
       | last_window_gutter_fps: Map.delete(caches.last_window_gutter_fps, id),
         pending_gutter_ids: MapSet.delete(caches.pending_gutter_ids, id)
     }}
  end

  @doc "Acknowledges pending row and gutter updates in one successfully applied frame."
  @spec acknowledge_pending_window_deltas(t()) :: t()
  def acknowledge_pending_window_deltas(%__MODULE__{} = caches),
    do: %{caches | pending_window_delta_ids: MapSet.new(), pending_gutter_ids: MapSet.new()}
end
