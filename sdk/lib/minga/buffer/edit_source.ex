defmodule Minga.Buffer.EditSource do
  @moduledoc """
  Identifies who made an edit to a buffer.

  Extensions pattern-match on the source in `BufferChangedEvent` to
  filter for agent-sourced edits:

      case event.source do
        {:agent, session_pid, tool_call_id} -> handle_agent_edit(...)
        :user -> ignore
        _ -> ignore
      end

  This is a compile-time stub.
  """

  @type t ::
          :user
          | {:agent, session_id :: pid(), tool_call_id :: String.t()}
          | {:lsp, server_name :: atom()}
          | :formatter
          | :unknown
end
