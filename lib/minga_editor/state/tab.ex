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
  alias MingaEditor.State.Tab.Context

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

  @typedoc "Agent tab status (nil for file tabs)."
  @type agent_status :: :idle | :plan | :thinking | :tool_executing | :error | nil

  @typedoc "Remote connection status for a tab backed by a remote session."
  @type connection_status :: :connected | :disconnected | :ended | :unavailable | nil

  @typedoc "Workspace id. 0 = manual workspace."
  @type group_id :: non_neg_integer()

  @typedoc "A tab."
  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          label: String.t(),
          context: context(),
          session: pid() | nil,
          agent_status: agent_status(),
          server_name: String.t() | nil,
          remote_session_id: String.t() | nil,
          connection_status: connection_status(),
          attention: boolean(),
          group_id: group_id(),
          file_ref: FileRef.t() | nil,
          background_subagent: MingaAgent.Subagent.Handle.t() | nil
        }

  @enforce_keys [:id, :kind]
  defstruct id: nil,
            kind: nil,
            label: "",
            context: Context.empty(),
            session: nil,
            agent_status: nil,
            server_name: nil,
            remote_session_id: nil,
            connection_status: nil,
            attention: false,
            group_id: 0,
            file_ref: nil,
            background_subagent: nil

  @doc "Creates a new file tab."
  @spec new_file(id(), String.t()) :: t()
  def new_file(id, label \\ "") when is_integer(id) and id > 0 do
    %__MODULE__{id: id, kind: :file, label: label}
  end

  @doc "Creates a new agent tab."
  @spec new_agent(id(), String.t()) :: t()
  def new_agent(id, label \\ "Agent") when is_integer(id) and id > 0 do
    %__MODULE__{id: id, kind: :agent, label: label}
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

  @doc "Returns true if this is a file tab."
  @spec file?(t()) :: boolean()
  def file?(%__MODULE__{kind: :file}), do: true
  def file?(%__MODULE__{}), do: false

  @doc "Returns true if this is an agent tab."
  @spec agent?(t()) :: boolean()
  def agent?(%__MODULE__{kind: :agent}), do: true
  def agent?(%__MODULE__{}), do: false

  @doc "Sets the session pid for an agent tab."
  @spec set_session(t(), pid() | nil) :: t()
  def set_session(%__MODULE__{} = tab, pid) do
    %{tab | session: pid}
  end

  @doc "Marks the tab as backed by a remote agent session."
  @spec set_remote_session(t(), String.t(), String.t(), pid()) :: t()
  def set_remote_session(%__MODULE__{} = tab, server_name, session_id, pid)
      when is_binary(server_name) and is_binary(session_id) and is_pid(pid) do
    %{
      tab
      | server_name: server_name,
        remote_session_id: session_id,
        session: pid,
        connection_status: :connected
    }
  end

  @doc "Updates remote connection status for the tab."
  @spec set_connection_status(t(), connection_status()) :: t()
  def set_connection_status(%__MODULE__{} = tab, status)
      when status in [:connected, :disconnected, :ended, :unavailable, nil] do
    %{tab | connection_status: status}
  end

  @doc "Returns true when this tab is backed by a remote session."
  @spec remote?(t()) :: boolean()
  def remote?(%__MODULE__{server_name: server_name}) when is_binary(server_name), do: true
  def remote?(%__MODULE__{}), do: false

  @doc "Returns the display label including any remote server prefix."
  @spec display_label(t()) :: String.t()
  def display_label(%__MODULE__{label: "", server_name: nil}), do: "[No Name]"

  def display_label(%__MODULE__{
        label: label,
        server_name: server_name,
        connection_status: status
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

  @doc "Sets the agent status on a tab (for tab bar rendering)."
  @spec set_agent_status(t(), agent_status()) :: t()
  def set_agent_status(%__MODULE__{} = tab, status) do
    %{tab | agent_status: status}
  end

  @doc "Sets the attention flag (agent needs user input)."
  @spec set_attention(t(), boolean()) :: t()
  def set_attention(%__MODULE__{} = tab, value) when is_boolean(value) do
    %{tab | attention: value}
  end

  @doc "Sets the workspace group id."
  @spec set_group(t(), group_id()) :: t()
  def set_group(%__MODULE__{} = tab, group_id) when is_integer(group_id) and group_id >= 0 do
    %{tab | group_id: group_id}
  end

  @doc "Sets the logical file identity for a file tab."
  @spec set_file_ref(t(), FileRef.t() | nil) :: t()
  def set_file_ref(%__MODULE__{} = tab, %FileRef{} = file_ref), do: %{tab | file_ref: file_ref}
  def set_file_ref(%__MODULE__{} = tab, nil), do: %{tab | file_ref: nil}

  @doc "Marks this tab as the UI projection of a background sub-agent."
  @spec mark_background_subagent(t(), MingaAgent.Subagent.Handle.t()) :: t()
  def mark_background_subagent(%__MODULE__{} = tab, %MingaAgent.Subagent.Handle{} = handle) do
    %{tab | background_subagent: handle}
  end

  @doc "Returns true when this tab projects a background sub-agent."
  @spec background_subagent?(t()) :: boolean()
  def background_subagent?(%__MODULE__{background_subagent: %MingaAgent.Subagent.Handle{}}),
    do: true

  def background_subagent?(%__MODULE__{}), do: false

  @doc "Removes a dead buffer pid from this tab's context snapshot."
  @spec scrub_buffer(t(), pid()) :: t()
  def scrub_buffer(%__MODULE__{context: context} = tab, pid) do
    %{tab | context: Context.scrub_buffer(context, pid)}
  end
end
