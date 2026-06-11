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

    # Number of buffer rows freshly rasterized (composed) this frame, summed
    # across windows. Reset at the start of the Content stage and read by the
    # pipeline telemetry span as `rows_rasterized` (#2287). A transient
    # per-frame counter, not retained across frames.
    frame_rows_rasterized: 0,

    # Classification of this frame's render path, `:patch` or `:full` (#2287).
    # Set after buffer prefetch resolves per-window invalidation and read by the
    # pipeline telemetry span as the `path` tag. Transient per-frame state.
    frame_render_path: :full,

    # ── Emit stage ────────────────────────────────────────────────────────────
    emit_prev_viewport_tops: %{},
    emit_prev_content_rects: %{},
    emit_prev_gutter_ws: %{},
    emit_prev_buf_versions: %{},
    emit_prev_cursor_lines: %{},
    emit_prev_editing_mode: nil,
    last_title: nil,
    last_window_bg: nil,

    # ── Frame transaction (#2219) ────────────────────────────────────────────
    # The frame_seq of the last successfully-emitted frame. A delta frame names
    # it as its begin_frame base_frame_seq; a keyframe forces base 0. Starts at 0
    # so the very first frame is a keyframe by construction.
    last_emitted_frame_seq: 0,

    # Whether the most recently emitted frame was a keyframe (base_frame_seq 0,
    # full window snapshots). The Editor reads this to clear `keyframe_pending?`
    # only when a frame that actually honored the request reaches emit, so a
    # concurrent delta writeback can't silently swallow a pending keyframe (#2219).
    last_frame_keyframe?: false,

    # ── Core adapter caches (render-model migration) ─────────────────────────
    adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new()
  ]

  @type t :: %__MODULE__{
          chrome_prev_fingerprint: integer() | nil,
          chrome_prev_result: term(),
          search_decoration_cache: term(),
          doc_highlight_cache: term(),
          block_render_cache: %{term() => term()},
          frame_rows_rasterized: non_neg_integer(),
          frame_render_path: :patch | :full,
          emit_prev_viewport_tops: %{term() => non_neg_integer()},
          emit_prev_content_rects: %{term() => term()},
          emit_prev_gutter_ws: %{term() => non_neg_integer()},
          emit_prev_buf_versions: %{term() => non_neg_integer()},
          emit_prev_cursor_lines: %{term() => non_neg_integer()},
          emit_prev_editing_mode: atom() | nil,
          last_title: String.t() | nil,
          last_window_bg: non_neg_integer() | nil,
          last_emitted_frame_seq: non_neg_integer(),
          last_frame_keyframe?: boolean(),
          adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.t()
        }

  @doc "Creates a fresh Caches struct with first-frame defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Clears frontend-retained state tracking after the frontend reports ready again."
  @spec reset_frontend_state(t()) :: t()
  def reset_frontend_state(%__MODULE__{} = caches) do
    %{
      caches
      | adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new(),
        last_title: nil,
        last_window_bg: nil,
        # A reconnecting frontend has no committed base, so force the next frame to
        # a keyframe (base_frame_seq 0) by clearing the last-emitted frame_seq.
        last_emitted_frame_seq: 0
    }
  end
end
