defmodule Minga.RenderModel.UI.AgentHelp do
  @moduledoc "Agent Help presentation independent of chat, composer and Review visibility."

  @type binding :: {String.t(), String.t()}
  @type group :: {String.t(), [binding()]}
  @type t :: %__MODULE__{visible?: boolean(), groups: [group()]}

  defstruct visible?: false, groups: []
end
