defmodule Minga.RenderModel.UI.BottomPanel do
  @moduledoc """
  Semantic bottom panel model.

  Describes the bottom panel as domain data: visibility, the active tab index,
  height, filter, the message stream instance, the tab definitions (pre-resolved type byte + name), and the
  resolved message entries to send this frame. The GUI adapter
  (`Minga.Frontend.Adapter.GUI.BottomPanelEncoder`) owns the wire encoding.

  The message-store cursor advance is a builder concern, not an encoder concern:
  the builder resolves which entries are new, advances the store, and places the
  resolved entries here. The encoder is a pure function of this model.
  """

  alias __MODULE__.MessageEntry

  @typedoc "A tab definition: its wire type byte and display name."
  @type tab :: {type_byte :: non_neg_integer(), name :: String.t()}

  @typedoc "Producer-assigned Messages stream identity. Hidden panels keep 0 because they do not encode content."
  @type stream_instance :: 1..0xFFFF_FFFF

  @type t :: %__MODULE__{
          visible?: boolean(),
          active_tab_index: non_neg_integer(),
          height_percent: non_neg_integer(),
          filter_byte: non_neg_integer(),
          stream_instance: 0 | stream_instance(),
          tabs: [tab()],
          messages: [MessageEntry.t()]
        }

  defstruct visible?: false,
            active_tab_index: 0,
            height_percent: 0,
            filter_byte: 0,
            stream_instance: 0,
            tabs: [],
            messages: []

  defmodule MessageEntry do
    @moduledoc """
    One resolved message-log entry to render. Level and subsystem are
    pre-resolved to their wire bytes by the builder so the encoder stays free of
    editor-defined level/subsystem semantics.
    """

    @type t :: %__MODULE__{
            id: non_neg_integer(),
            level_byte: non_neg_integer(),
            subsystem_byte: non_neg_integer(),
            ts_secs: non_neg_integer(),
            file_path: String.t() | nil,
            text: String.t()
          }

    @enforce_keys [:id, :level_byte, :subsystem_byte, :ts_secs, :text]
    defstruct [:id, :level_byte, :subsystem_byte, :ts_secs, :text, file_path: nil]
  end
end
