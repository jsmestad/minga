defmodule MingaAgent.InferenceRoute.Request do
  @moduledoc """
  Everything a route receives for one model request. `tools` is empty for `:summary` and `:title` requests.

  This is a compile-time stub.
  """

  alias MingaAgent.InferenceRoute.{ConversationRef, Credential, Message, Model, Options}
  alias MingaAgent.InferenceRoute.ToolDeclaration

  @enforce_keys [:model, :messages, :tools, :options, :conversation]
  defstruct [:model, :system, :messages, :tools, :options, :conversation, :credential]

  @type t :: %__MODULE__{
          model: Model.t(),
          system: String.t() | nil,
          messages: [Message.t()],
          tools: [ToolDeclaration.t()],
          options: Options.t(),
          conversation: ConversationRef.t(),
          credential: Credential.t() | nil
        }
end
