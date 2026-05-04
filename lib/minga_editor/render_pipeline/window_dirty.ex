defmodule MingaEditor.RenderPipeline.WindowDirty do
  @moduledoc """
  Per-window dirty info produced by Stage 1 (Invalidation).

  ## Modes

  - `:clean` — nothing changed since last frame; downstream stages
    can reuse the cached `WindowFrame` and skip `Buffer.render_snapshot/3`.
  - `:rows` — only the listed rows (`dirty_rows`) need rebuilding;
    the rest of the window keeps its cached drawing.
  - `:all` — the whole window must rebuild (the today-default for any
    edit, until per-row dirty tracking arrives in Phase 2).

  ## Reason

  `reason` records what triggered the dirty state, for telemetry and
  for sanity mode comparisons. Examples: `:viewport_scroll`,
  `:cursor_moved`, `:buffer_edit`, `:mode_change`, `:focus_change`,
  `:theme_changed`, `:resize`. No behavioral effect today.
  """

  @typedoc "Per-window dirty mode."
  @type mode :: :clean | :rows | :all

  @typedoc "Map of dirty buffer line numbers (0-based)."
  @type dirty_rows :: %{non_neg_integer() => true}

  @typedoc "Per-window dirty info."
  @type t :: %__MODULE__{
          mode: mode(),
          dirty_rows: dirty_rows(),
          reason: atom()
        }

  defstruct mode: :all, dirty_rows: %{}, reason: :unknown

  @doc "Constructs a `:clean` window dirty entry."
  @spec clean() :: t()
  def clean, do: %__MODULE__{mode: :clean}

  @doc "Constructs an `:all` window dirty entry with a reason tag."
  @spec all(atom()) :: t()
  def all(reason \\ :unknown), do: %__MODULE__{mode: :all, reason: reason}

  @doc "Constructs a `:rows` window dirty entry from a list of buffer line numbers."
  @spec rows([non_neg_integer()], atom()) :: t()
  def rows(lines, reason \\ :unknown) when is_list(lines) do
    %__MODULE__{
      mode: :rows,
      dirty_rows: Map.new(lines, fn n -> {n, true} end),
      reason: reason
    }
  end

  @doc "Returns true if every row in this window is considered dirty."
  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{mode: :all}), do: true
  def full?(%__MODULE__{}), do: false

  @doc "Returns true if no work is needed for this window."
  @spec clean?(t()) :: boolean()
  def clean?(%__MODULE__{mode: :clean}), do: true
  def clean?(%__MODULE__{}), do: false
end
