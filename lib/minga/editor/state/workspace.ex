defmodule Minga.Editor.State.Workspace do
  @moduledoc """
  A workspace groups related tabs in the tab bar.

  Workspaces provide progressive disclosure: when no agents are running,
  the tab bar looks exactly like today. When agents start, their files
  are grouped into workspace sections with visual separators.

  ## Kinds

  - `:manual` - The default workspace for user-opened files (id 0).
    Always exists, cannot be removed.
  - `:agent` - Auto-created when an agent session starts. Tracks files
    the agent modifies and shows live status.

  ## Colors

  Each workspace has a 24-bit RGB accent color used for group separators
  and the workspace indicator in the tab bar. The manual workspace uses
  the theme's default accent. Agent workspaces cycle through a palette.
  """

  @typedoc "Workspace kind."
  @type kind :: :manual | :agent

  @typedoc "Agent status for workspace display."
  @type agent_status :: :idle | :thinking | :tool_executing | :error | nil

  @typedoc "A workspace."
  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          color: non_neg_integer(),
          agent_status: agent_status(),
          session: pid() | nil
        }

  @enforce_keys [:id, :kind]
  defstruct id: 0,
            kind: :manual,
            label: "My Files",
            color: 0x51AFEF,
            agent_status: nil,
            session: nil

  @doc "The default manual workspace. Always workspace id 0."
  @spec manual() :: t()
  def manual do
    %__MODULE__{id: 0, kind: :manual, label: "My Files", color: 0x51AFEF}
  end

  @doc "Creates a new agent workspace with a unique id."
  @spec new_agent(pos_integer(), String.t(), pid() | nil) :: t()
  def new_agent(id, label, session \\ nil) when is_integer(id) and id > 0 do
    color = agent_color(id)

    %__MODULE__{
      id: id,
      kind: :agent,
      label: label,
      color: color,
      agent_status: :idle,
      session: session
    }
  end

  @doc "Sets the agent status on the workspace."
  @spec set_agent_status(t(), agent_status()) :: t()
  def set_agent_status(%__MODULE__{} = ws, status) do
    %{ws | agent_status: status}
  end

  @doc "Returns true if this is the manual (default) workspace."
  @spec manual?(t()) :: boolean()
  def manual?(%__MODULE__{kind: :manual}), do: true
  def manual?(%__MODULE__{}), do: false

  @doc "Returns true if this is an agent workspace."
  @spec agent?(t()) :: boolean()
  def agent?(%__MODULE__{kind: :agent}), do: true
  def agent?(%__MODULE__{}), do: false

  # Palette of 6 visually distinct accent colors for agent workspaces.
  # Cycles based on workspace id.
  @agent_colors [
    0xC678DD,
    0x98BE65,
    0xDA8548,
    0xFF6C6B,
    0x46D9FF,
    0xECBE7B
  ]

  @spec agent_color(pos_integer()) :: non_neg_integer()
  defp agent_color(id) do
    Enum.at(@agent_colors, rem(id - 1, length(@agent_colors)))
  end
end
