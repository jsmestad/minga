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

  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Picker
  alias Minga.WhichKey

  @typedoc "Identifies what kind of picker is currently open."
  @type picker_kind :: :buffer | :find_file | nil

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
            picker_kind: nil,
            picker_prev_buffer: nil,
            mouse_dragging: false

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
          picker_kind: picker_kind(),
          picker_prev_buffer: non_neg_integer() | nil,
          mouse_dragging: boolean()
        }
end
