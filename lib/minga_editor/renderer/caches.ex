defmodule MingaEditor.Renderer.Caches do
  @moduledoc """
  Explicit render-pipeline cache state, replacing process-dictionary entries.

  Each field corresponds to a former `Process.put/get` key used across the
  render pipeline stages. `Renderer.Server` retains the struct across frames and injects it into `RenderPipeline.Input`; it never crosses back into Editor state.

  ## Ownership by stage

  - **Chrome** (`chrome_prev_*`): `RenderPipeline`, stage 5 fingerprint cache.
  - **Content** (`search_decoration_cache`, `doc_highlight_cache`): consumed by
    `ContentHelpers.build_render_ctx/3`; cleared when the fingerprint changes.
  - **Emit** (`last_title`, `last_window_bg`, `last_link_cursor`): consumed by
    `Frontend.Emit` stage 7.
  - **Adapter** (`adapter_gui_caches`): core GUI adapter fingerprint state.
  """

  defstruct [
    # ── Chrome stage ──────────────────────────────────────────────────────────
    chrome_prev_fingerprint: nil,
    chrome_prev_result: nil,

    # ── Content stage: inter-frame caches ─────────────────────────────────────
    search_decoration_cache: nil,
    doc_highlight_cache: nil,
    cmd_hover_link_cache: nil,

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
    last_title: nil,
    last_window_bg: nil,
    last_link_cursor: nil,

    # ── Frame transaction (#2219) ────────────────────────────────────────────
    # The last frame written and the last frame explicitly acknowledged by the
    # current frontend generation. Only the acknowledged value may be a delta base.
    last_emitted_frame_seq: 0,
    last_acknowledged_frame_seq: 0,
    recovery_generation: 1,

    # Whether the most recently emitted frame was a keyframe (base_frame_seq 0,
    # full window snapshots). Renderer receipts carry this correlation fact so the
    # Editor can fulfill a pending keyframe request only after actual emission.
    last_frame_keyframe?: false,

    # ── Core adapter caches (render-model migration) ─────────────────────────
    adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new()
  ]

  @type t :: %__MODULE__{
          chrome_prev_fingerprint: integer() | nil,
          chrome_prev_result: term(),
          search_decoration_cache: term(),
          doc_highlight_cache: term(),
          cmd_hover_link_cache: term(),
          frame_rows_rasterized: non_neg_integer(),
          frame_render_path: :patch | :full,
          last_title: String.t() | nil,
          last_window_bg: non_neg_integer() | nil,
          last_link_cursor: boolean() | nil,
          last_emitted_frame_seq: non_neg_integer(),
          last_acknowledged_frame_seq: non_neg_integer(),
          recovery_generation: non_neg_integer(),
          last_frame_keyframe?: boolean(),
          adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.t()
        }

  @doc "Creates a fresh Caches struct with first-frame defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records the frame explicitly applied by the current frontend generation."
  @spec acknowledge_frame(t(), non_neg_integer(), non_neg_integer()) :: t()
  def acknowledge_frame(%__MODULE__{} = caches, frame_seq, generation)
      when is_integer(frame_seq) and frame_seq >= 0 and is_integer(generation) and generation >= 0 do
    %{caches | last_acknowledged_frame_seq: frame_seq, recovery_generation: generation}
  end

  @doc "Clears frontend-retained state tracking after the frontend reports ready again."
  @spec reset_frontend_state(t()) :: t()
  def reset_frontend_state(%__MODULE__{} = caches) do
    %{
      caches
      | adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new(),
        last_title: nil,
        last_window_bg: nil,
        last_link_cursor: nil,
        # A reconnecting frontend has no acknowledged base in the fresh generation.
        last_emitted_frame_seq: 0,
        last_acknowledged_frame_seq: 0,
        recovery_generation: caches.recovery_generation + 1
    }
  end
end
