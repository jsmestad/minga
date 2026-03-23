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

  @typedoc "SF Symbol name for workspace icon."
  @type icon :: String.t()

  @typedoc "A workspace."
  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          icon: icon(),
          color: non_neg_integer(),
          agent_status: agent_status(),
          session: pid() | nil,
          custom_name: boolean()
        }

  @enforce_keys [:id, :kind]
  defstruct id: 0,
            kind: :manual,
            label: "",
            icon: "folder",
            color: 0x51AFEF,
            agent_status: nil,
            session: nil,
            custom_name: false

  @doc """
  The default manual workspace. Always workspace id 0.

  Label defaults to "Files". Call `set_label/2` with the project name
  once the project root is known (the Project GenServer isn't available
  at compile time when this is used as a struct default).
  """
  @spec manual() :: t()
  def manual do
    %__MODULE__{id: 0, kind: :manual, label: "Files", icon: "doc.on.doc", color: 0x51AFEF}
  end

  @doc "Updates the workspace label."
  @spec set_label(t(), String.t()) :: t()
  def set_label(%__MODULE__{} = ws, label) when is_binary(label) do
    %{ws | label: label}
  end

  @doc "Renames the workspace (marks as custom so auto-naming stops)."
  @spec rename(t(), String.t()) :: t()
  def rename(%__MODULE__{} = ws, name) when is_binary(name) do
    %{ws | label: name, custom_name: true}
  end

  @doc "Sets the workspace icon (SF Symbol name)."
  @spec set_icon(t(), String.t()) :: t()
  def set_icon(%__MODULE__{} = ws, icon) when is_binary(icon) do
    %{ws | icon: icon}
  end

  @doc """
  Auto-names the workspace from an agent prompt, unless the user has
  set a custom name. Truncates to 30 chars.
  """
  @spec auto_name(t(), String.t()) :: t()
  def auto_name(%__MODULE__{custom_name: true} = ws, _prompt), do: ws

  def auto_name(%__MODULE__{} = ws, prompt) when is_binary(prompt) do
    name =
      prompt
      |> String.split("\n")
      |> hd()
      |> String.slice(0, 30)
      |> String.trim()

    if name == "" do
      ws
    else
      %{ws | label: name}
    end
  end

  @doc "Creates a new agent workspace with a unique id."
  @spec new_agent(pos_integer(), String.t(), pid() | nil) :: t()
  def new_agent(id, label, session \\ nil) when is_integer(id) and id > 0 do
    color = agent_color(id)

    %__MODULE__{
      id: id,
      kind: :agent,
      label: label,
      icon: "cpu",
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
