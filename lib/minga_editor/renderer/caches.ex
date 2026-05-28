defmodule MingaEditor.Renderer.Caches do
  @moduledoc """
  Explicit render-pipeline cache state, replacing process-dictionary entries.

  Each field corresponds to a former `Process.put/get` key used across the
  render pipeline stages. The struct is carried on `EditorState` and on
  `RenderPipeline.Input`, survives across frames, and is written back via
  `EditorState.apply_render_output/2` after each pipeline run.

  ## Ownership by stage

  - **Chrome** (`chrome_prev_*`): `RenderPipeline`, stage 5 fingerprint cache.
  - **Content** (`search_decoration_cache`, `doc_highlight_cache`): consumed by
    `ContentHelpers.build_render_ctx/3`; cleared when the fingerprint changes.
    `block_render_cache` is a within-frame cache reset after each window render.
  - **Emit** (`emit_prev_*`, `last_title`, `last_window_bg`):
    consumed by `Frontend.Emit` stage 7.
  - **Adapter** (`adapter_gui_caches`): core GUI adapter fingerprint state.
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
    emit_prev_editing_mode: nil,
    last_title: nil,
    last_window_bg: nil,

    # ── Core adapter caches (render-model migration) ─────────────────────────
    adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new()
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
          emit_prev_editing_mode: atom() | nil,
          last_title: String.t() | nil,
          last_window_bg: non_neg_integer() | nil,
          adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.t()
        }

  @doc "Creates a fresh Caches struct with first-frame defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}
end
