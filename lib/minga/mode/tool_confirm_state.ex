defmodule Minga.Mode.ToolConfirmState do
  @moduledoc """
  FSM state for the tool install confirmation prompt.

  Holds a queue of missing tool names to prompt about sequentially, the display label for each (resolved by the caller from `Minga.Tool.Recipe.Registry.labels/1`, so this Layer 0 state never reads the registry), plus the set of tools the user has declined this session.
  """

  @enforce_keys [:pending]
  defstruct pending: [],
            labels: %{},
            current: 0,
            declined: MapSet.new(),
            count: nil

  @type t :: %__MODULE__{
          pending: [atom()],
          labels: %{atom() => String.t()},
          current: non_neg_integer(),
          declined: MapSet.t(atom()),
          count: non_neg_integer() | nil
        }

  @doc "Display label for a tool, falling back to its name when the caller supplied none."
  @spec label(t(), atom()) :: String.t()
  def label(%__MODULE__{labels: labels}, name), do: Map.get(labels, name, Atom.to_string(name))
end
