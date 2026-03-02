defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  Holds references to the buffer list, port manager, viewport, modal FSM
  state, which-key popup state, and the yank register.

  ## Composed sub-structs

  Related fields are grouped into internal sub-structs to keep the top-level
  struct manageable:

  * `Minga.Editor.State.Buffers`   — buffer list, active buffer, special buffers
  * `Minga.Editor.State.Picker`    — picker instance, source, restore index
  * `Minga.Editor.State.WhichKey`  — which-key popup node, timer, visibility
  * `Minga.Editor.State.Search`    — last search pattern/direction, project results
  * `Minga.Editor.State.Registers` — named registers and active register selection
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.Registers
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.WhichKey
  alias Minga.Editor.Viewport
  alias Minga.Mode

  @typedoc "Stored last find-char motion for ; and , repeat."
  @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

  @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name (single letter)."
  @type marks :: %{pid() => %{String.t() => GapBuffer.position()}}

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @enforce_keys [:port_manager, :viewport, :mode, :mode_state]
  defstruct port_manager: nil,
            viewport: nil,
            mode: :normal,
            mode_state: nil,
            buf: %Buffers{},
            picker_ui: %Picker{},
            whichkey: %WhichKey{},
            search: %Search{},
            reg: %Registers{},
            mouse_dragging: false,
            last_find_char: nil,
            change_recorder: ChangeRecorder.new(),
            autopair_enabled: true,
            line_numbers: :hybrid,
            status_msg: nil,
            pending_conflict: nil,
            marks: %{},
            last_jump_pos: nil,
            macro_recorder: MacroRecorder.new()

  @type t :: %__MODULE__{
          port_manager: GenServer.server() | nil,
          viewport: Viewport.t(),
          mode: Mode.mode(),
          mode_state: Mode.state(),
          buf: Buffers.t(),
          picker_ui: Picker.t(),
          whichkey: WhichKey.t(),
          search: Search.t(),
          reg: Registers.t(),
          mouse_dragging: boolean(),
          last_find_char: last_find_char(),
          change_recorder: ChangeRecorder.t(),
          autopair_enabled: boolean(),
          line_numbers: line_number_style(),
          status_msg: String.t() | nil,
          pending_conflict: {pid(), String.t()} | nil,
          marks: marks(),
          last_jump_pos: GapBuffer.position() | nil,
          macro_recorder: MacroRecorder.t()
        }

  # ── Convenience accessors ─────────────────────────────────────────────────

  @doc "Returns the active buffer pid."
  @spec buffer(t()) :: pid() | nil
  def buffer(%__MODULE__{buf: %{buffer: b}}), do: b

  @doc "Returns the buffer list."
  @spec buffers(t()) :: [pid()]
  def buffers(%__MODULE__{buf: %{buffers: bs}}), do: bs

  @doc "Returns the active buffer index."
  @spec active_buffer(t()) :: non_neg_integer()
  def active_buffer(%__MODULE__{buf: %{active_buffer: idx}}), do: idx
end
