defmodule MingaEditor.RenderPipeline.AgentChatPrefetch do
  @moduledoc """
  Pre-fetched buffer data for one agent chat window.

  The agent chat renderer combines normal buffer content with prompt and dashboard chrome. This struct carries the buffer-owned data captured before the named render stages run, so the `:agent_content` stage can render without calling the buffer process.
  """

  alias Minga.Buffer.RenderSnapshot
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @enforce_keys [
    :win_id,
    :window,
    :viewport,
    :cursor_line,
    :cursor_byte_col,
    :cursor_col,
    :first_line,
    :snapshot,
    :line_number_style,
    :gutter_w,
    :content_w,
    :buf_version
  ]

  defstruct [
    :win_id,
    :window,
    :viewport,
    :cursor_line,
    :cursor_byte_col,
    :cursor_col,
    :first_line,
    :snapshot,
    :line_number_style,
    :gutter_w,
    :content_w,
    :buf_version
  ]

  @type t :: %__MODULE__{
          win_id: Window.id(),
          window: Window.t(),
          viewport: Viewport.t(),
          cursor_line: non_neg_integer(),
          cursor_byte_col: non_neg_integer(),
          cursor_col: non_neg_integer(),
          first_line: non_neg_integer(),
          snapshot: RenderSnapshot.t(),
          line_number_style: atom(),
          gutter_w: non_neg_integer(),
          content_w: pos_integer(),
          buf_version: non_neg_integer()
        }
end
