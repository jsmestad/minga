defmodule MingaEditor.State.Workspace do
  @moduledoc """
  Domain model for an editor workspace.

  A workspace owns a task context. The manual workspace represents project-owned file work, while agent workspaces attach one optional agent session and later become the home for workspace files, agent UI, ProjectView, and review state.
  """

  @typedoc "Workspace kind."
  @type kind :: :manual | :agent

  @typedoc "Agent status for workspace display."
  @type agent_status :: :idle | :plan | :thinking | :tool_executing | :error | nil

  @typedoc "Workspace icon identifier."
  @type icon :: String.t()

  @typedoc "A workspace domain object."
  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          icon: icon(),
          color: non_neg_integer(),
          agent_status: agent_status(),
          session: pid() | nil,
          custom_name: String.t() | nil,
          files: [term()],
          active_file: term() | nil,
          agent_ui: term() | nil,
          project_view: term() | nil,
          review: term() | nil
        }

  @enforce_keys [:id, :kind]
  defstruct id: nil,
            kind: nil,
            label: "Workspace",
            icon: "folder",
            color: 0x51AFEF,
            agent_status: :idle,
            session: nil,
            custom_name: nil,
            files: [],
            active_file: nil,
            agent_ui: nil,
            project_view: nil,
            review: nil

  @doc "Creates the manual project workspace."
  @spec new_manual(String.t() | nil) :: t()
  def new_manual(project_root) do
    %__MODULE__{
      id: 0,
      kind: :manual,
      label: manual_label(project_root),
      icon: "folder",
      color: 0x51AFEF,
      agent_status: nil,
      session: nil
    }
  end

  @doc "Creates a new agent workspace with a unique id."
  @spec new_agent(pos_integer(), String.t(), pid() | nil) :: t()
  def new_agent(id, label, session \\ nil) when is_integer(id) and id > 0 do
    %__MODULE__{
      id: id,
      kind: :agent,
      label: label,
      icon: "cpu",
      color: agent_color(id),
      agent_status: :idle,
      session: session
    }
  end

  @doc "Sets the agent status on the workspace."
  @spec set_agent_status(t(), agent_status()) :: t()
  def set_agent_status(%__MODULE__{} = workspace, status) do
    %{workspace | agent_status: status}
  end

  @doc "Renames the workspace and protects it from future auto-naming."
  @spec rename(t(), String.t()) :: t()
  def rename(%__MODULE__{} = workspace, name) when is_binary(name) do
    %{workspace | label: name, custom_name: name}
  end

  @doc "Sets the workspace icon."
  @spec set_icon(t(), String.t()) :: t()
  def set_icon(%__MODULE__{} = workspace, icon) when is_binary(icon) do
    %{workspace | icon: icon}
  end

  @doc "Auto-names an agent workspace from an agent prompt unless the user renamed it."
  @spec auto_name(t(), String.t()) :: t()
  def auto_name(%__MODULE__{custom_name: name} = workspace, _prompt) when is_binary(name),
    do: workspace

  def auto_name(%__MODULE__{} = workspace, prompt) when is_binary(prompt) do
    prompt
    |> prompt_name()
    |> apply_auto_name(workspace)
  end

  @spec manual_label(String.t() | nil) :: String.t()
  defp manual_label(nil), do: "Files"

  defp manual_label(project_root) when is_binary(project_root) do
    project_root
    |> Path.basename()
    |> fallback_manual_label()
  end

  @spec fallback_manual_label(String.t()) :: String.t()
  defp fallback_manual_label(""), do: "Files"
  defp fallback_manual_label("."), do: "Files"
  defp fallback_manual_label(label), do: label

  @spec prompt_name(String.t()) :: String.t()
  defp prompt_name(prompt) do
    prompt
    |> String.split("\n")
    |> hd()
    |> String.slice(0, 30)
    |> String.trim()
  end

  @spec apply_auto_name(String.t(), t()) :: t()
  defp apply_auto_name("", workspace), do: workspace
  defp apply_auto_name(name, workspace), do: %{workspace | label: name}

  @workspace_colors [
    0xC678DD,
    0x98BE65,
    0xDA8548,
    0xFF6C6B,
    0x46D9FF,
    0xECBE7B
  ]

  @spec agent_color(pos_integer()) :: non_neg_integer()
  defp agent_color(id) do
    Enum.at(@workspace_colors, rem(id - 1, length(@workspace_colors)))
  end
end
