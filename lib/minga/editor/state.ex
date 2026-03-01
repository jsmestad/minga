defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  Holds references to the buffer list, port manager, viewport, modal FSM
  state, which-key popup state, and the yank register.

  ## Buffer management

  The editor tracks multiple open buffers in a list (`buffers`) with an
  `active_buffer` index pointing to the currently displayed buffer.
  The convenience field `buffer` is kept in sync as the pid of the
  active buffer for backward compatibility with rendering and commands.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Picker
  alias Minga.WhichKey

  @typedoc "Stored last find-char motion for ; and , repeat."
  @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

  @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name (single letter)."
  @type marks :: %{pid() => %{String.t() => GapBuffer.position()}}

  @enforce_keys [:port_manager, :viewport, :mode, :mode_state]
  defstruct buffer: nil,
            buffers: [],
            active_buffer: 0,
            port_manager: nil,
            viewport: nil,
            mode: :normal,
            mode_state: nil,
            whichkey_node: nil,
            whichkey_timer: nil,
            show_whichkey: false,
            register: nil,
            picker: nil,
            picker_source: nil,
            picker_restore: nil,
            mouse_dragging: false,
            last_find_char: nil,
            change_recorder: ChangeRecorder.new(),
            autopair_enabled: true,
            line_numbers: :hybrid,
            status_msg: nil,
            pending_conflict: nil,
            last_search_pattern: nil,
            last_search_direction: :forward,
            marks: %{},
            last_jump_pos: nil

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @type t :: %__MODULE__{
          buffer: pid() | nil,
          buffers: [pid()],
          active_buffer: non_neg_integer(),
          port_manager: GenServer.server() | nil,
          viewport: Viewport.t(),
          mode: Mode.mode(),
          mode_state: Mode.state(),
          whichkey_node: Minga.Keymap.Trie.node_t() | nil,
          whichkey_timer: WhichKey.timer_ref() | nil,
          show_whichkey: boolean(),
          register: String.t() | nil,
          picker: Picker.t() | nil,
          picker_source: module() | nil,
          picker_restore: non_neg_integer() | nil,
          mouse_dragging: boolean(),
          last_find_char: last_find_char(),
          change_recorder: ChangeRecorder.t(),
          autopair_enabled: boolean(),
          line_numbers: line_number_style(),
          status_msg: String.t() | nil,
          pending_conflict: {pid(), String.t()} | nil,
          last_search_pattern: String.t() | nil,
          last_search_direction: Minga.Search.direction(),
          marks: marks(),
          last_jump_pos: GapBuffer.position() | nil
        }
end
