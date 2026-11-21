defmodule MingaEditor.Agent.FileChange do
  @moduledoc "An agent-authored file edit translated from the subscriber event at editor ingress."

  @enforce_keys [:path, :before_content, :after_content, :tool_call_id, :tool_name]
  defstruct [:path, :before_content, :after_content, :tool_call_id, :tool_name]

  @type t :: %__MODULE__{
          path: String.t(),
          before_content: String.t() | :absent,
          after_content: String.t() | :absent,
          tool_call_id: String.t(),
          tool_name: String.t()
        }
end
