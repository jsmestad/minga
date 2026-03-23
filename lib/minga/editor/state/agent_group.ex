defmodule Minga.Editor.State.AgentGroup do
  @moduledoc """
  An agent group in the tab bar.

  Each agent session gets its own group. The group tracks the agent's
  status, the files it modified, and provides visual identity (icon,
  color, label) in the tab bar.

  Tabs with `group_id: 0` are ungrouped (the user's own tabs). Tabs
  with `group_id > 0` belong to an agent group. There is no "manual
  workspace" concept; ungrouped tabs are simply tabs without a group.

  ## Colors

  Each group has a 24-bit RGB accent color for group separators and
  capsule rendering. Colors cycle through a 6-color palette.
  """

  @typedoc "Agent status for group display."
  @type agent_status :: :idle | :thinking | :tool_executing | :error | nil

  @typedoc "SF Symbol name for group icon."
  @type icon :: String.t()

  @typedoc "An agent group."
  @type t :: %__MODULE__{
          id: pos_integer(),
          label: String.t(),
          icon: icon(),
          color: non_neg_integer(),
          agent_status: agent_status(),
          session: pid() | nil,
          custom_name: boolean()
        }

  @enforce_keys [:id]
  defstruct id: nil,
            label: "Agent",
            icon: "cpu",
            color: 0x51AFEF,
            agent_status: :idle,
            session: nil,
            custom_name: false

  @doc "Creates a new agent group with a unique id."
  @spec new(pos_integer(), String.t(), pid() | nil) :: t()
  def new(id, label, session \\ nil) when is_integer(id) and id > 0 do
    %__MODULE__{
      id: id,
      label: label,
      icon: "cpu",
      color: agent_color(id),
      agent_status: :idle,
      session: session
    }
  end

  @doc "Sets the agent status on the group."
  @spec set_agent_status(t(), agent_status()) :: t()
  def set_agent_status(%__MODULE__{} = group, status) do
    %{group | agent_status: status}
  end

  @doc "Updates the group label."
  @spec set_label(t(), String.t()) :: t()
  def set_label(%__MODULE__{} = group, label) when is_binary(label) do
    %{group | label: label}
  end

  @doc "Renames the group (marks as custom so auto-naming stops)."
  @spec rename(t(), String.t()) :: t()
  def rename(%__MODULE__{} = group, name) when is_binary(name) do
    %{group | label: name, custom_name: true}
  end

  @doc "Sets the group icon (SF Symbol name)."
  @spec set_icon(t(), String.t()) :: t()
  def set_icon(%__MODULE__{} = group, icon) when is_binary(icon) do
    %{group | icon: icon}
  end

  @doc """
  Auto-names the group from an agent prompt, unless the user has
  set a custom name. Takes first line, truncates to 30 chars.
  """
  @spec auto_name(t(), String.t()) :: t()
  def auto_name(%__MODULE__{custom_name: true} = group, _prompt), do: group

  def auto_name(%__MODULE__{} = group, prompt) when is_binary(prompt) do
    name =
      prompt
      |> String.split("\n")
      |> hd()
      |> String.slice(0, 30)
      |> String.trim()

    if name == "", do: group, else: %{group | label: name}
  end

  # Palette of 6 visually distinct accent colors.
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
