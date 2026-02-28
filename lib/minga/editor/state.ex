defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  Holds references to the buffer, port manager, viewport, modal FSM state,
  which-key popup state, and the yank register.
  """

  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.WhichKey

  @enforce_keys [:port_manager, :viewport, :mode, :mode_state]
  defstruct buffer: nil,
            port_manager: nil,
            viewport: nil,
            mode: :normal,
            mode_state: nil,
            whichkey_node: nil,
            whichkey_timer: nil,
            show_whichkey: false,
            register: nil

  @type t :: %__MODULE__{
          buffer: pid() | nil,
          port_manager: GenServer.server() | nil,
          viewport: Viewport.t(),
          mode: Mode.mode(),
          mode_state: Mode.state(),
          whichkey_node: Minga.Keymap.Trie.node_t() | nil,
          whichkey_timer: WhichKey.timer_ref() | nil,
          show_whichkey: boolean(),
          register: String.t() | nil
        }
end
