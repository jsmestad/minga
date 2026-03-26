defmodule Minga.Editing.Model.Vim do
  @moduledoc """
  Vim editing model implementation.

  Wraps the existing `Minga.Mode` FSM in the `EditingModel` behaviour.
  This is a thin delegation layer, not a reimplementation. All modal
  logic (normal, insert, visual, operator-pending, command, search,
  etc.) stays in the `Mode` modules where it already works.

  ## State

  The vim editing model state is a `%Vim.State{}` struct containing
  the current mode atom and the FSM-level state (count prefix, leader
  sequence, pending operators, visual anchor, etc.).

  Currently `mode` and `mode_state` also live on `EditorState` for
  backward compatibility. During the Phase H migration they will be
  removed from EditorState and this struct will be the single source
  of truth.
  """

  @behaviour Minga.Editing.Model

  alias Minga.Mode

  # ── State ──────────────────────────────────────────────────────────────────

  @typedoc "Vim editing model state: current mode + FSM state."
  @type t :: %__MODULE__{
          mode: Mode.mode(),
          mode_state: Mode.state()
        }

  defstruct mode: :normal,
            mode_state: %Mode.State{}

  # ── EditingModel callbacks ─────────────────────────────────────────────────

  @impl Minga.Editing.Model
  @spec process_key(t(), Minga.Editing.Model.key()) ::
          {Minga.Editing.Model.mode_label(), [Minga.Editing.Model.command()], t()}
  def process_key(%__MODULE__{mode: mode, mode_state: mode_state}, key) do
    {new_mode, commands, new_mode_state} = Mode.process(mode, key, mode_state)
    new_state = %__MODULE__{mode: new_mode, mode_state: new_mode_state}
    {new_mode, commands, new_state}
  end

  @impl Minga.Editing.Model
  @spec initial_state() :: t()
  def initial_state, do: %__MODULE__{}

  @impl Minga.Editing.Model
  @spec mode_display(t()) :: String.t()
  def mode_display(%__MODULE__{mode: mode, mode_state: mode_state}) do
    Mode.display(mode, mode_state)
  end

  @impl Minga.Editing.Model
  @spec mode(t()) :: Minga.Editing.Model.mode_label()
  def mode(%__MODULE__{mode: mode}), do: mode

  @impl Minga.Editing.Model
  @spec inserting?(t()) :: boolean()
  def inserting?(%__MODULE__{mode: :insert}), do: true
  def inserting?(%__MODULE__{}), do: false

  @impl Minga.Editing.Model
  @spec selecting?(t()) :: boolean()
  def selecting?(%__MODULE__{mode: mode}) when mode in [:visual, :visual_line, :visual_block],
    do: true

  def selecting?(%__MODULE__{}), do: false

  @impl Minga.Editing.Model
  @spec cursor_shape(t()) :: :beam | :block | :underline
  def cursor_shape(%__MODULE__{mode: :normal, mode_state: %{pending_replace: true}}),
    do: :underline

  def cursor_shape(%__MODULE__{mode: :insert}), do: :beam
  def cursor_shape(%__MODULE__{mode: :replace}), do: :underline

  def cursor_shape(%__MODULE__{mode: mode})
      when mode in [:search, :command, :eval, :search_prompt],
      do: :beam

  def cursor_shape(%__MODULE__{}), do: :block

  @impl Minga.Editing.Model
  @spec key_sequence_pending?(t()) :: boolean()
  def key_sequence_pending?(%__MODULE__{mode_state: %{leader_node: node}})
      when node != nil,
      do: true

  def key_sequence_pending?(%__MODULE__{mode_state: %{prefix_node: node}})
      when node != nil,
      do: true

  def key_sequence_pending?(%__MODULE__{mode: mode})
      when mode in [:operator_pending, :command],
      do: true

  def key_sequence_pending?(%__MODULE__{}), do: false

  @impl Minga.Editing.Model
  @spec status_segment(t()) :: String.t()
  def status_segment(%__MODULE__{mode: mode}) do
    mode |> to_string() |> String.upcase()
  end

  # ── Convenience ────────────────────────────────────────────────────────────

  @doc "Creates a Vim editing model state from an existing mode and mode_state."
  @spec from_editor(Mode.mode(), Mode.state()) :: t()
  def from_editor(mode, mode_state) do
    %__MODULE__{mode: mode, mode_state: mode_state}
  end

  @doc "Extracts the mode and mode_state for writing back to EditorState."
  @spec to_editor(t()) :: {Mode.mode(), Mode.state()}
  def to_editor(%__MODULE__{mode: mode, mode_state: mode_state}) do
    {mode, mode_state}
  end
end
