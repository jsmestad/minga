defmodule Minga.RenderModel.UI.SubagentPeek do
  @moduledoc "A parent conversation's subagent activations and optional right-hand peek."

  alias Minga.RenderModel.UI.AgentChat

  @type pane_state :: :working | :done | :failed | :stopped
  @type rect :: {row :: non_neg_integer(), col :: non_neg_integer(), pos_integer(), pos_integer()}
  @type step ::
          {entry_id :: pos_integer(), token :: String.t(), label :: String.t(),
           report :: String.t()}
  @type sibling :: {token :: String.t(), title :: String.t(), pane_state()}
  @type pane :: %{
          window_id: pos_integer(),
          token: String.t(),
          parent: String.t(),
          title: String.t(),
          state: pane_state(),
          elapsed: String.t(),
          siblings: [sibling()],
          index: pos_integer(),
          brief: String.t(),
          brief_open?: boolean(),
          result: String.t() | nil,
          prompt: String.t(),
          cursor: {non_neg_integer(), non_neg_integer()},
          focused?: boolean(),
          editing?: boolean(),
          sending?: boolean(),
          notice: String.t() | nil
        }

  @type transcript :: {non_neg_integer(), [AgentChat.message()], boolean()} | nil

  @type t :: %__MODULE__{
          parent_window_id: pos_integer() | nil,
          steps: [step()],
          pane: pane() | nil,
          parent_rect: rect() | nil,
          peek_rect: rect() | nil,
          transcript: transcript()
        }

  defstruct parent_window_id: nil,
            steps: [],
            pane: nil,
            parent_rect: nil,
            peek_rect: nil,
            transcript: nil
end
