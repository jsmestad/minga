defmodule MingaEditor.RenderPipeline.Invalidation do
  @moduledoc """
  Output of Stage 1 (Invalidation) — first-class dirty information that
  downstream stages consult to skip work for clean windows and chrome
  regions.

  ## Fields

  - `full_redraw` — when true, downstream stages ignore the per-window
    and per-region detail and rebuild everything. This is the today
    behavior and the safe default while Phase 1 dirty tracking is
    being wired in.
  - `windows` — per-window dirty info (`Window.id() => WindowDirty.t()`).
    A window's mode is one of `:clean` (no work needed), `:rows`
    (only the listed `dirty_rows` need redrawing), or `:all` (the
    whole window must rebuild).
  - `chrome_regions` — set of dirty chrome region tags
    (`:tab_bar`, `:status_bar`, `:file_tree`, `:agent_panel`,
    `:minibuffer`, `:modeline`). When a region isn't in the set,
    the chrome stage reuses its cached drawing.
  - `global_reasons` — root causes that triggered global
    invalidation (`:theme_changed`, `:font_changed`, `:resize`,
    `:focus_change`, etc.). Carried for telemetry; no behavioral
    effect today.

  ## Phase 1 status

  This struct is the contract Stage 1 will produce when the dirty
  tracking arrives. Today the producer always returns a struct with
  `full_redraw: true` and empty maps, so behavior is unchanged.
  Stage 2 (#1431 Phase 2) implements the per-row dirty algebra and
  Stage 3 lifts it into the pipeline consumers.
  """

  alias MingaEditor.RenderPipeline.WindowDirty

  @typedoc "Chrome region tags."
  @type region_tag ::
          :tab_bar
          | :status_bar
          | :file_tree
          | :agent_panel
          | :minibuffer
          | :modeline

  @typedoc "Output of Stage 1."
  @type t :: %__MODULE__{
          full_redraw: boolean(),
          windows: %{integer() => WindowDirty.t()},
          chrome_regions: MapSet.t(region_tag()),
          global_reasons: [atom()]
        }

  defstruct full_redraw: true,
            windows: %{},
            chrome_regions: MapSet.new(),
            global_reasons: []

  @doc """
  Returns a fresh Invalidation requesting a full redraw — the safe
  default while incremental tracking is staged in.
  """
  # `:no_opaque` because `chrome_regions: MapSet.new()` in the literal struct
  # makes Dialyzer's inferred success type expose MapSet's opaque internal
  # record (`%MapSet{:map => MapSet.internal(_)}`), which it then flags as a
  # mismatch against the contract's `MapSet.t(region_tag())`. The contract is
  # what callers should rely on; the inferred shape is an implementation
  # detail of `MapSet.new/0`.
  @dialyzer {:no_opaque, full_redraw: 1}
  @spec full_redraw([atom()]) :: t()
  def full_redraw(reasons \\ []) do
    %__MODULE__{
      full_redraw: true,
      windows: %{},
      chrome_regions: MapSet.new(),
      global_reasons: reasons
    }
  end

  @doc """
  Sanity-mode env flag. When `MINGA_RENDER_SANITY=1`, a follow-up
  Phase 1 implementation will run the pipeline twice (incremental +
  full) and assert byte-equal output, emitting a
  `[:minga, :render, :sanity_violation]` telemetry event on
  divergence. The flag exists today so the env-var contract is
  documented; the comparison itself is wired in the Phase 1 follow-up.
  """
  @spec sanity_mode?() :: boolean()
  def sanity_mode? do
    System.get_env("MINGA_RENDER_SANITY") == "1"
  end
end
