defmodule MingaEditor.Renderer.Caches do
  @moduledoc """
  Explicit render-pipeline cache state, replacing process-dictionary entries.

  Each field corresponds to a former `Process.put/get` key used across the
  render pipeline stages. The struct is carried on `EditorState` and on
  `RenderPipeline.Input`, survives across frames, and is written back via
  `EditorState.apply_render_output/2` after each pipeline run.

  ## Ownership by stage

  - **Chrome** (`chrome_prev_*`): `RenderPipeline` — stage 5 fingerprint cache.
  - **Content** (`search_decoration_cache`, `doc_highlight_cache`): consumed by
    `ContentHelpers.build_render_ctx/3`; cleared when the fingerprint changes.
    `block_render_cache` is a within-frame cache reset after each window render.
  - **Emit** (`emit_prev_*`, `last_title`, `last_window_bg`):
    consumed by `Frontend.Emit` stage 7.
  - **GUI chrome** (`last_gui_*`): fingerprint caches inside `Emit.GUI`.
  """

  defstruct [
    # ── Chrome stage ──────────────────────────────────────────────────────────
    chrome_prev_fingerprint: nil,
    chrome_prev_result: nil,

    # ── Content stage: inter-frame caches ─────────────────────────────────────
    search_decoration_cache: nil,
    doc_highlight_cache: nil,

    # ── Content stage: within-frame cache (reset after each window render) ────
    block_render_cache: %{},

    # ── Emit stage ────────────────────────────────────────────────────────────
    emit_prev_viewport_tops: %{},
    emit_prev_content_rects: %{},
    emit_prev_gutter_ws: %{},
    emit_prev_buf_versions: %{},
    last_title: nil,
    last_window_bg: nil,

    # ── GUI chrome fingerprints ───────────────────────────────────────────────
    last_gui_theme: nil,
    last_gui_tab_bar_fp: nil,
    last_gui_workspaces_fp: nil,
    last_gui_file_tree_fp: nil,
    last_gui_git_status_fp: nil,
    last_gui_which_key_fp: nil,
    last_gui_completion_fp: nil,
    last_gui_breadcrumb_fp: nil,
    last_gui_minibuffer: nil,
    last_gui_picker_fp: nil,
    last_gui_agent_chat_fp: nil,
    last_gui_hover_popup_fp: nil,
    last_gui_signature_help_fp: nil,
    last_gui_float_popup_fp: nil,
    last_gui_notifications_fp: nil,
    last_gui_bottom_panel_fp: nil,
    last_gui_board_fp: nil,
    last_gui_agent_context_fp: nil,
    last_gui_change_summary_fp: nil
  ]

  @type t :: %__MODULE__{
          chrome_prev_fingerprint: integer() | nil,
          chrome_prev_result: term(),
          search_decoration_cache: term(),
          doc_highlight_cache: term(),
          block_render_cache: %{term() => term()},
          emit_prev_viewport_tops: %{term() => non_neg_integer()},
          emit_prev_content_rects: %{term() => term()},
          emit_prev_gutter_ws: %{term() => non_neg_integer()},
          emit_prev_buf_versions: %{term() => non_neg_integer()},
          last_title: String.t() | nil,
          last_window_bg: non_neg_integer() | nil,
          last_gui_theme: integer() | nil,
          last_gui_tab_bar_fp: integer() | nil,
          last_gui_workspaces_fp: integer() | nil,
          last_gui_file_tree_fp:
            integer()
            | {:ready, non_neg_integer(), non_neg_integer()}
            | {:file_tree_state, String.t(), non_neg_integer(), term()}
            | {:no_tree, String.t()}
            | nil,
          last_gui_git_status_fp: integer() | {:no_git, boolean()} | nil,
          last_gui_which_key_fp: integer() | nil,
          last_gui_completion_fp: integer() | nil,
          last_gui_breadcrumb_fp: integer() | nil,
          last_gui_minibuffer: term(),
          last_gui_picker_fp: integer() | :closed | nil,
          last_gui_agent_chat_fp: integer() | :not_visible | nil,
          last_gui_hover_popup_fp: integer() | nil,
          last_gui_signature_help_fp: integer() | nil,
          last_gui_float_popup_fp: integer() | nil,
          last_gui_notifications_fp: integer() | nil,
          last_gui_bottom_panel_fp: integer() | nil,
          last_gui_board_fp: integer() | :dismissed | nil,
          last_gui_agent_context_fp: term(),
          last_gui_change_summary_fp: integer() | :hidden | nil
        }

  @doc "Creates a fresh Caches struct with first-frame defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}
end
