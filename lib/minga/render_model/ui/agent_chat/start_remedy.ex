defmodule Minga.RenderModel.UI.AgentChat.StartRemedy do
  @moduledoc """
  The one action a failed Agent start offers: its kind, the button label, and the key that runs it.

  Frontends render `label` and `key_hint` exactly as sent and never author remedy copy. Activating the action sends the `kind` back; the BEAM maps it to the command.
  """

  @enforce_keys [:kind, :label, :key_hint]
  defstruct @enforce_keys

  @type kind :: :retry | :set_up_provider

  @type t :: %__MODULE__{kind: kind(), label: String.t(), key_hint: String.t()}
end
