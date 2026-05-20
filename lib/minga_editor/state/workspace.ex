defmodule MingaEditor.State.Workspace do
  @moduledoc """
  Domain model for an editor workspace.

  A workspace owns a task context. The manual workspace represents project-owned file work, while agent workspaces attach one optional agent session and later become the home for workspace files, agent UI, ProjectView, and review state.
  """

  alias Minga.Project.FileRef
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State.Workspace.RemoteSession

  @typedoc "Workspace kind."
  @type kind :: :manual | :agent

  @typedoc "Agent status for workspace display."
  @type agent_status ::
          :idle | :plan | :thinking | :tool_executing | :error | :needs_review | :done | nil

  @typedoc "Remote connection status for workspace-owned remote sessions."
  @type connection_status :: RemoteSession.connection_status()

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
          remote_session: RemoteSession.t() | nil,
          custom_name: String.t() | nil,
          files: [FileRef.t()],
          active_file: FileRef.t() | nil,
          agent_ui: UIState.t() | nil,
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
            remote_session: nil,
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
      session: nil,
      remote_session: nil
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
      session: session,
      agent_ui: UIState.new()
    }
  end

  @doc "Sets the agent session pid on the workspace."
  @spec set_session(t(), pid() | nil) :: t()
  def set_session(%__MODULE__{} = workspace, session) when is_pid(session) or is_nil(session) do
    %{workspace | session: session}
  end

  @doc "Clears the live agent session pid and returns the workspace to idle lifecycle status. Durable remote identity is preserved."
  @spec clear_session(t()) :: t()
  def clear_session(%__MODULE__{} = workspace) do
    workspace
    |> set_session(nil)
    |> set_agent_status(:idle)
  end

  @doc "Sets durable remote metadata on the workspace."
  @spec set_remote_session(t(), RemoteSession.t() | nil) :: t()
  def set_remote_session(%__MODULE__{} = workspace, %RemoteSession{} = remote_session) do
    %{workspace | remote_session: remote_session}
  end

  def set_remote_session(%__MODULE__{} = workspace, nil) do
    %{workspace | remote_session: nil}
  end

  @doc "Sets durable remote metadata from its fields."
  @spec put_remote_session(t(), String.t(), String.t(), connection_status()) :: t()
  def put_remote_session(%__MODULE__{} = workspace, server_name, session_id, status \\ :connected) do
    set_remote_session(workspace, RemoteSession.new(server_name, session_id, status))
  end

  @doc "Updates durable remote connection status when the workspace has remote metadata."
  @spec set_remote_connection_status(t(), connection_status()) :: t()
  def set_remote_connection_status(
        %__MODULE__{remote_session: %RemoteSession{} = remote_session} = workspace,
        status
      ) do
    set_remote_session(workspace, RemoteSession.set_connection_status(remote_session, status))
  end

  def set_remote_connection_status(%__MODULE__{} = workspace, _status), do: workspace

  @doc "Clears durable remote metadata. Use only when the workspace no longer represents a remote session."
  @spec clear_remote_session(t()) :: t()
  def clear_remote_session(%__MODULE__{} = workspace) do
    set_remote_session(workspace, nil)
  end

  @doc "Returns true when the workspace has durable remote metadata."
  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{remote_session: %RemoteSession{}}), do: true
  def remote?(%__MODULE__{}), do: false

  @doc "Returns true when the workspace represents the remote server/session pair."
  @spec matches_remote_session?(t(), String.t(), String.t()) :: boolean()
  def matches_remote_session?(
        %__MODULE__{remote_session: %RemoteSession{} = remote_session},
        server_name,
        session_id
      ) do
    RemoteSession.matches?(remote_session, server_name, session_id)
  end

  def matches_remote_session?(%__MODULE__{}, _server_name, _session_id), do: false

  @doc "Returns true when the workspace represents any session on the remote server."
  @spec remote_server?(t(), String.t()) :: boolean()
  def remote_server?(%__MODULE__{remote_session: %RemoteSession{} = remote_session}, server_name) do
    RemoteSession.server?(remote_session, server_name)
  end

  def remote_server?(%__MODULE__{}, _server_name), do: false

  @doc "Sets the agent UI state on the workspace."
  @spec set_agent_ui(t(), UIState.t()) :: t()
  def set_agent_ui(%__MODULE__{} = workspace, %UIState{} = agent_ui) do
    Map.put(workspace, :agent_ui, agent_ui)
  end

  @doc "Updates the agent UI state on the workspace."
  @spec update_agent_ui(t(), (UIState.t() -> UIState.t())) :: t()
  def update_agent_ui(%__MODULE__{} = workspace, fun) when is_function(fun, 1) do
    set_agent_ui(workspace, fun.(workspace.agent_ui || UIState.new()))
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

  @doc "Adds a file membership to the workspace, preserving existing membership order."
  @spec add_file(t(), FileRef.t()) :: t()
  def add_file(%__MODULE__{} = workspace, %FileRef{} = file_ref) do
    if has_file?(workspace, file_ref) do
      workspace
    else
      %{workspace | files: workspace.files ++ [file_ref]}
    end
  end

  @doc "Removes a file membership from the workspace."
  @spec remove_file(t(), FileRef.t()) :: t()
  def remove_file(%__MODULE__{} = workspace, %FileRef{} = file_ref) do
    files = Enum.reject(workspace.files, &FileRef.equal?(&1, file_ref))
    active_file = remove_active_file(workspace.active_file, file_ref)
    %{workspace | files: files, active_file: active_file}
  end

  @doc "Rebinds the active file membership from one logical file ref to another."
  @spec rebind_file(t(), FileRef.t() | nil, FileRef.t()) :: t()
  def rebind_file(%__MODULE__{} = workspace, old_file_ref, %FileRef{} = new_file_ref) do
    workspace =
      case old_file_ref do
        %FileRef{} = old ->
          if FileRef.equal?(old, new_file_ref), do: workspace, else: remove_file(workspace, old)

        nil ->
          workspace
      end

    set_active_file(workspace, new_file_ref)
  end

  @doc "Retargets a file membership for a tab, preserving unrelated active file state."
  @spec retarget_file(t(), FileRef.t() | nil, FileRef.t(), boolean()) :: t()
  def retarget_file(
        %__MODULE__{} = workspace,
        old_file_ref,
        %FileRef{} = new_file_ref,
        is_active_tab
      )
      when is_boolean(is_active_tab) do
    was_active_file = active_file_matches?(workspace.active_file, old_file_ref)

    workspace =
      case old_file_ref do
        %FileRef{} = old ->
          if FileRef.equal?(old, new_file_ref) do
            workspace
          else
            workspace
            |> remove_file(old)
            |> add_file(new_file_ref)
          end

        nil ->
          add_file(workspace, new_file_ref)
      end

    maybe_rebind_active_file(workspace, new_file_ref, is_active_tab or was_active_file)
  end

  @doc "Returns true when the workspace already contains the file membership."
  @spec has_file?(t(), FileRef.t()) :: boolean()
  def has_file?(%__MODULE__{files: files}, %FileRef{} = file_ref) do
    Enum.any?(files, &FileRef.equal?(&1, file_ref))
  end

  @doc "Sets the active file membership for the workspace."
  @spec set_active_file(t(), FileRef.t() | nil) :: t()
  def set_active_file(%__MODULE__{} = workspace, nil), do: %{workspace | active_file: nil}

  def set_active_file(%__MODULE__{} = workspace, %FileRef{} = file_ref) do
    workspace
    |> add_file(file_ref)
    |> Map.put(:active_file, file_ref)
  end

  @spec maybe_rebind_active_file(t(), FileRef.t(), boolean()) :: t()
  defp maybe_rebind_active_file(%__MODULE__{} = workspace, %FileRef{} = new_file_ref, true) do
    set_active_file(workspace, new_file_ref)
  end

  defp maybe_rebind_active_file(%__MODULE__{} = workspace, %FileRef{} = _new_file_ref, false),
    do: workspace

  @spec active_file_matches?(FileRef.t() | nil, FileRef.t() | nil) :: boolean()
  defp active_file_matches?(%FileRef{} = active_file, %FileRef{} = old_file_ref) do
    FileRef.equal?(active_file, old_file_ref)
  end

  defp active_file_matches?(_active_file, _old_file_ref), do: false

  @spec remove_active_file(FileRef.t() | nil, FileRef.t()) :: FileRef.t() | nil
  defp remove_active_file(%FileRef{} = active_file, %FileRef{} = removed_file) do
    if FileRef.equal?(active_file, removed_file), do: nil, else: active_file
  end

  defp remove_active_file(nil, %FileRef{}), do: nil

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
