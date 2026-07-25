defmodule MingaEditor.State.Tab do
  @moduledoc """
  A single tab in the tab bar.

  Each tab has a unique id, a kind (`:file` or `:agent`), a display label,
  and a typed context that stores snapshotted per-tab state when the tab is
  inactive. The active tab's context is "live" on EditorState; inactive
  tabs carry a frozen snapshot that gets restored when you switch to them.

  ## Context format

  The canonical context is `MingaEditor.State.Tab.Context`, a struct with explicit workspace fields. Restore still accepts legacy maps for migration, including empty maps for brand-new tabs.
  """

  alias Minga.Project.FileRef
  alias MingaEditor.FeatureState
  alias MingaEditor.State.Tab.{Agent, Context, File}
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaAgent.Subagent.Handle

  @typedoc "Unique tab identifier."
  @type id :: pos_integer()

  @typedoc "Tab kind."
  @type kind :: :file | :agent

  @typedoc """
  Snapshotted per-tab state.

  Stores per-tab workspace fields in an explicit struct. Empty context means a brand-new tab.
  """
  @type context :: Context.t()

  @typedoc "Legacy context map accepted at migration boundaries."
  @type legacy_context :: Context.legacy()

  @typedoc "Agent tab status."
  @type agent_status :: Workspace.agent_status()

  @typedoc "Remote connection status for a tab backed by a remote session."
  @type connection_status :: RemoteSession.connection_status() | nil

  @typedoc "Workspace id. 0 = manual workspace."
  @type group_id :: non_neg_integer()

  @type file :: %__MODULE__{kind: :file, payload: File.t()}

  @type agent :: %__MODULE__{kind: :agent, payload: Agent.t()}

  @typedoc "A tab."
  @type t :: file() | agent()

  @enforce_keys [:id, :kind, :payload]
  defstruct id: nil,
            kind: nil,
            label: "",
            context: Context.empty(),
            group_id: 0,
            pinned?: false,
            payload: nil

  @doc "Creates a new file tab."
  @spec new_file(id(), String.t()) :: file()
  def new_file(id, label \\ "") when is_integer(id) and id > 0 do
    %__MODULE__{id: id, kind: :file, label: label, payload: %File{}}
  end

  @doc "Creates a new agent tab."
  @spec new_agent(id(), String.t()) :: agent()
  def new_agent(id, label \\ "Agent") when is_integer(id) and id > 0 do
    %__MODULE__{id: id, kind: :agent, label: label, payload: %Agent{}}
  end

  @doc "Updates the tab's label."
  @spec set_label(t(), String.t()) :: t()
  def set_label(%__MODULE__{} = tab, label) when is_binary(label) do
    %{tab | label: label}
  end

  @doc "Stores a context snapshot into the tab."
  @spec set_context(t(), context() | legacy_context()) :: t()
  def set_context(%__MODULE__{} = tab, %Context{} = context) do
    %{tab | context: context}
  end

  def set_context(%__MODULE__{} = tab, context) when is_map(context) do
    %{tab | context: Context.from_map(context)}
  end

  @doc "Drops all snapshotted feature state owned by a source."
  @spec drop_feature_state_source(t(), FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{} = tab, source) do
    update_context_feature_state(tab, &FeatureState.drop_source(&1, source))
  end

  @doc "Drops all snapshotted extension-owned feature state."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = tab) do
    update_context_feature_state(tab, &FeatureState.drop_extension_sources/1)
  end

  @doc "Returns true if this is a file tab."
  @spec file?(t()) :: boolean()
  def file?(%__MODULE__{kind: :file, payload: %File{}}), do: true
  def file?(%__MODULE__{}), do: false

  @doc "Returns true if this is an agent tab."
  @spec agent?(t()) :: boolean()
  def agent?(%__MODULE__{kind: :agent, payload: %Agent{}}), do: true
  def agent?(%__MODULE__{}), do: false

  @doc "Refreshes any background-subagent pid references after a managed restart."
  @spec refresh_session_pid(t(), pid(), pid()) :: t()
  def refresh_session_pid(%__MODULE__{kind: :agent, payload: %Agent{}} = tab, old_pid, new_pid)
      when is_pid(old_pid) and is_pid(new_pid) do
    refresh_background_subagent(tab, old_pid, new_pid)
  end

  def refresh_session_pid(%__MODULE__{payload: %File{}} = tab, old_pid, new_pid)
      when is_pid(old_pid) and is_pid(new_pid),
      do: tab

  @spec refresh_background_subagent(t(), pid(), pid()) :: t()
  defp refresh_background_subagent(
         %__MODULE__{payload: %Agent{background_subagent: %Handle{} = handle} = payload} = tab,
         old_pid,
         new_pid
       ) do
    handle = refresh_background_subagent_pid(handle, old_pid, new_pid)
    handle = refresh_background_subagent_parent_pid(handle, old_pid, new_pid)
    %{tab | payload: %Agent{payload | background_subagent: handle}}
  end

  defp refresh_background_subagent(%__MODULE__{} = tab, _old_pid, _new_pid), do: tab

  @spec refresh_background_subagent_pid(Handle.t(), pid(), pid()) :: Handle.t()
  defp refresh_background_subagent_pid(%Handle{pid: pid} = handle, old_pid, new_pid)
       when pid == old_pid do
    Handle.with_pid(handle, new_pid)
  end

  defp refresh_background_subagent_pid(%Handle{} = handle, _old_pid, _new_pid), do: handle

  @spec refresh_background_subagent_parent_pid(Handle.t(), pid(), pid()) :: Handle.t()
  defp refresh_background_subagent_parent_pid(
         %Handle{parent_pid: parent_pid} = handle,
         old_pid,
         new_pid
       )
       when parent_pid == old_pid do
    Handle.with_parent_pid(handle, new_pid)
  end

  defp refresh_background_subagent_parent_pid(%Handle{} = handle, _old_pid, _new_pid), do: handle

  @doc "Projects workspace-owned lifecycle and remote metadata onto this tab for display."
  @spec project_agent_lifecycle(agent(), Workspace.agent()) :: agent()
  def project_agent_lifecycle(
        %__MODULE__{kind: :agent, payload: %Agent{} = payload} = tab,
        %Workspace{payload: %Workspace.Agent{} = workspace_agent}
      ) do
    remote_projection =
      case workspace_agent.remote_session do
        %RemoteSession{} = remote_session ->
          [
            server_name: remote_session.server_name,
            remote_session_id: remote_session.session_id,
            connection_status: remote_session.connection_status
          ]

        nil ->
          [server_name: nil, remote_session_id: nil, connection_status: nil]
      end

    %{
      tab
      | payload:
          struct!(
            payload,
            [
              session: workspace_agent.session,
              agent_status: workspace_agent.agent_status
            ] ++ remote_projection
          )
    }
  end

  @doc "Marks an orphaned remote tab projection as disconnected."
  @spec mark_orphan_remote_disconnected(agent()) :: agent()
  def mark_orphan_remote_disconnected(
        %__MODULE__{kind: :agent, payload: %Agent{} = payload} = tab
      ) do
    %{tab | payload: %Agent{payload | connection_status: :disconnected}}
  end

  @doc "Clears lifecycle fields for an orphaned agent tab after its session exits."
  @spec mark_orphan_session_down(agent(), agent_status()) :: agent()
  def mark_orphan_session_down(
        %__MODULE__{kind: :agent, payload: %Agent{} = payload} = tab,
        status
      ) do
    %{
      tab
      | payload: %Agent{
          payload
          | session: nil,
            agent_status: status
        }
    }
  end

  @doc "Clears agent lifecycle projection data from this tab."
  @spec clear_agent_projection(t()) :: t()
  def clear_agent_projection(%__MODULE__{kind: :agent, payload: %Agent{} = payload} = tab) do
    %{
      tab
      | payload: %Agent{
          payload
          | session: nil,
            agent_status: nil,
            server_name: nil,
            remote_session_id: nil,
            connection_status: nil,
            attention: false
        }
    }
  end

  def clear_agent_projection(%__MODULE__{payload: %File{}} = tab), do: tab

  @doc "Returns true when this tab is backed by a remote session."
  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{kind: :agent, payload: %Agent{server_name: server_name}})
      when is_binary(server_name),
      do: true

  def remote?(%__MODULE__{}), do: false

  @doc "Returns the display label including any remote server prefix."
  @spec display_label(t()) :: String.t()
  def display_label(%__MODULE__{label: "", payload: %Agent{server_name: nil}}), do: "[No Name]"
  def display_label(%__MODULE__{label: "", payload: %File{}}), do: "[No Name]"

  def display_label(%__MODULE__{
        label: label,
        payload: %Agent{server_name: server_name, connection_status: status}
      })
      when is_binary(server_name) do
    "[#{server_name}] #{base_label(label)}#{status_suffix(status)}"
  end

  def display_label(%__MODULE__{label: label}), do: base_label(label)

  @spec base_label(String.t()) :: String.t()
  defp base_label(""), do: "[No Name]"
  defp base_label(label), do: label

  @spec status_suffix(connection_status()) :: String.t()
  defp status_suffix(:disconnected), do: " [disconnected]"
  defp status_suffix(:ended), do: " [ended]"
  defp status_suffix(:unavailable), do: " [unavailable]"
  defp status_suffix(_status), do: ""

  @doc "Sets the attention flag (agent needs user input)."
  @spec set_attention(t(), boolean()) :: t()
  def set_attention(%__MODULE__{kind: :agent, payload: %Agent{} = payload} = tab, value)
      when is_boolean(value) do
    %{tab | payload: %Agent{payload | attention: value}}
  end

  def set_attention(%__MODULE__{payload: %File{}} = tab, value) when is_boolean(value), do: tab

  @doc "Sets whether this tab is pinned in the tab strip."
  @spec set_pinned(t(), boolean()) :: t()
  def set_pinned(%__MODULE__{} = tab, value) when is_boolean(value) do
    %{tab | pinned?: value}
  end

  @doc "Toggles whether this tab is pinned in the tab strip."
  @spec toggle_pinned(t()) :: t()
  def toggle_pinned(%__MODULE__{} = tab) do
    set_pinned(tab, not tab.pinned?)
  end

  @doc "Sets the workspace group id."
  @spec set_group(t(), group_id()) :: t()
  def set_group(%__MODULE__{} = tab, group_id) when is_integer(group_id) and group_id >= 0 do
    %{tab | group_id: group_id}
  end

  @doc "Sets the logical file identity for a file tab."
  @spec set_file_ref(t(), FileRef.t() | nil) :: t()
  def set_file_ref(
        %__MODULE__{kind: :file, payload: %File{} = payload} = tab,
        %FileRef{} = file_ref
      ),
      do: %{tab | payload: %File{payload | file_ref: file_ref}}

  def set_file_ref(%__MODULE__{kind: :file, payload: %File{} = payload} = tab, nil),
    do: %{tab | payload: %File{payload | file_ref: nil}}

  def set_file_ref(%__MODULE__{payload: %Agent{}} = tab, value)
      when is_nil(value) or is_struct(value, FileRef),
      do: tab

  @doc "Marks this tab as the UI projection of a background sub-agent."
  @spec mark_background_subagent(t(), Handle.t()) :: t()
  def mark_background_subagent(
        %__MODULE__{kind: :agent, payload: %Agent{} = payload} = tab,
        %Handle{} = handle
      ) do
    %{tab | payload: %Agent{payload | background_subagent: handle}}
  end

  def mark_background_subagent(%__MODULE__{payload: %File{}} = tab, %Handle{}), do: tab

  @doc "Returns true when this tab projects a background sub-agent."
  @spec background_subagent?(t()) :: boolean()
  def background_subagent?(%__MODULE__{
        kind: :agent,
        payload: %Agent{background_subagent: %Handle{}}
      }),
      do: true

  def background_subagent?(%__MODULE__{}), do: false

  @doc "Removes a dead buffer pid from this tab's context and logical file projection."
  @spec scrub_buffer(t(), pid()) :: t()
  def scrub_buffer(%__MODULE__{context: context} = tab, pid) do
    tab
    |> scrub_buffer_file_ref(pid)
    |> set_context(Context.scrub_buffer(context, pid))
  end

  @spec scrub_buffer_file_ref(t(), pid()) :: t()
  defp scrub_buffer_file_ref(
         %__MODULE__{
           kind: :file,
           payload: %File{file_ref: %FileRef{kind: :buffer, buffer_pid: pid}} = payload
         } = tab,
         pid
       ) do
    %{tab | payload: %File{payload | file_ref: nil}}
  end

  defp scrub_buffer_file_ref(%__MODULE__{} = tab, _pid), do: tab

  @spec update_context_feature_state(t(), (FeatureState.t() -> FeatureState.t())) :: t()
  defp update_context_feature_state(%__MODULE__{context: %Context{} = context} = tab, fun) do
    if :feature_state in context.present_fields do
      feature_state = context.feature_state || FeatureState.new()
      context = Context.put_fields(context, feature_state: fun.(feature_state))
      set_context(tab, context)
    else
      tab
    end
  end
end
