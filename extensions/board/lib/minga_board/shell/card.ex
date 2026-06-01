defmodule MingaBoard.Shell.Card do
  @moduledoc """
  A card on The Board representing an agent session or manual workspace.

  Each card carries a workspace snapshot (buffers, editing state) that
  gets restored when the user zooms in and captured when they zoom out.
  This is the same pattern as tab context snapshots in Shell.Traditional.

  The "You" card has `session: nil` and provides the traditional editing
  experience without an agent.

  ## Status lifecycle

      :idle → :working → :iterating → :done
                  ↓           ↓
              :needs_you   :errored

  `:working` means the agent is actively generating. `:iterating` means
  it's running tests or linter feedback loops. `:needs_you` means it
  hit a wall and needs human input (approval, clarifying question).
  """

  alias MingaEditor.FeatureState
  alias MingaEditor.State.Tab.Context, as: TabContext

  @type status :: :idle | :working | :iterating | :needs_you | :done | :errored

  @type id :: pos_integer()

  @type connection_status :: :connected | :disconnected | :ended | :unavailable | nil

  @type workspace_snapshot :: TabContext.t()

  @type t :: %__MODULE__{
          id: id(),
          session: pid() | nil,
          server_name: String.t() | nil,
          remote_session_id: String.t() | nil,
          connection_status: connection_status(),
          workspace: workspace_snapshot() | nil,
          task: String.t(),
          status: status(),
          model: String.t() | nil,
          kind: :you | :agent,
          created_at: DateTime.t(),
          recent_files: [String.t()],
          sparkline: [float()]
        }

  @enforce_keys [:id, :task, :created_at]
  defstruct id: nil,
            session: nil,
            server_name: nil,
            remote_session_id: nil,
            connection_status: nil,
            workspace: nil,
            task: "",
            status: :idle,
            model: nil,
            kind: :agent,
            created_at: nil,
            recent_files: [],
            sparkline: []

  @doc "Creates a new card with the given attributes."
  @spec new(id(), keyword()) :: t()
  def new(id, attrs \\ []) do
    %__MODULE__{
      id: id,
      task: Keyword.get(attrs, :task, ""),
      session: Keyword.get(attrs, :session),
      server_name: Keyword.get(attrs, :server_name),
      remote_session_id: Keyword.get(attrs, :remote_session_id),
      connection_status: Keyword.get(attrs, :connection_status),
      model: Keyword.get(attrs, :model),
      workspace: normalize_workspace(Keyword.get(attrs, :workspace)),
      status: Keyword.get(attrs, :status, :idle),
      kind: Keyword.get(attrs, :kind, :agent),
      created_at: DateTime.utc_now(),
      recent_files: Keyword.get(attrs, :recent_files, []),
      sparkline: Keyword.get(attrs, :sparkline, [])
    }
  end

  @doc "Transitions the card to a new status."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = card, status) do
    %{card | status: status}
  end

  @doc "Attaches an agent session PID to the card."
  @spec attach_session(t(), pid()) :: t()
  def attach_session(%__MODULE__{} = card, pid) when is_pid(pid) do
    %{card | session: pid, status: :working}
  end

  @doc "Marks this card as backed by a remote session."
  @spec attach_remote_session(t(), String.t(), String.t(), pid()) :: t()
  def attach_remote_session(%__MODULE__{} = card, server_name, session_id, pid)
      when is_binary(server_name) and is_binary(session_id) and is_pid(pid) do
    %{
      card
      | session: pid,
        server_name: server_name,
        remote_session_id: session_id,
        connection_status: :connected,
        status: :working
    }
  end

  @doc "Updates remote connection status."
  @spec set_connection_status(t(), connection_status()) :: t()
  def set_connection_status(%__MODULE__{} = card, status)
      when status in [:connected, :disconnected, :ended, :unavailable, nil] do
    %{card | connection_status: status}
  end

  @doc "Returns a display task with the remote server prefix when present."
  @spec display_task(t()) :: String.t()
  def display_task(%__MODULE__{task: task, server_name: server_name, connection_status: status})
      when is_binary(server_name) do
    "[#{server_name}] #{base_task(task)}#{status_suffix(status)}"
  end

  def display_task(%__MODULE__{task: task}), do: base_task(task)

  @spec base_task(String.t()) :: String.t()
  defp base_task(""), do: "Untitled"
  defp base_task(task), do: task

  @spec status_suffix(connection_status()) :: String.t()
  defp status_suffix(:disconnected), do: " [disconnected]"
  defp status_suffix(:ended), do: " [ended]"
  defp status_suffix(:unavailable), do: " [unavailable]"
  defp status_suffix(_status), do: ""

  @doc "Detaches the agent session PID. Used after the session process has died."
  @spec detach_session(t()) :: t()
  def detach_session(%__MODULE__{} = card) do
    %{card | session: nil}
  end

  @doc "Refreshes the attached session PID after a managed restart."
  @spec refresh_session_pid(t(), pid(), pid()) :: t()
  def refresh_session_pid(%__MODULE__{session: session} = card, old_pid, new_pid)
      when session == old_pid and is_pid(new_pid) do
    %{card | session: new_pid}
  end

  def refresh_session_pid(%__MODULE__{} = card, _old_pid, _new_pid), do: card

  @doc "Stores a workspace snapshot on the card."
  @spec store_workspace(t(), workspace_snapshot() | TabContext.legacy()) :: t()
  def store_workspace(%__MODULE__{} = card, workspace) when is_map(workspace) do
    %{card | workspace: TabContext.from_map(workspace)}
  end

  @doc "Clears the stored workspace snapshot."
  @spec clear_workspace(t()) :: t()
  def clear_workspace(%__MODULE__{} = card) do
    %{card | workspace: nil}
  end

  @doc "Drops source-owned feature state from the stored workspace snapshot."
  @spec drop_feature_state_source(t(), FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{} = card, source) do
    update_workspace_feature_state(card, &FeatureState.drop_source(&1, source))
  end

  @doc "Drops extension-owned feature state from the stored workspace snapshot."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = card) do
    update_workspace_feature_state(card, &FeatureState.drop_extension_sources/1)
  end

  @doc "Updates the list of recently touched files."
  @spec set_recent_files(t(), [String.t()]) :: t()
  def set_recent_files(%__MODULE__{} = card, files) when is_list(files) do
    %{card | recent_files: files}
  end

  @doc "Returns true if this is the 'You' card (manual editing)."
  @spec you_card?(t()) :: boolean()
  def you_card?(%__MODULE__{kind: :you}), do: true
  def you_card?(%__MODULE__{}), do: false

  @doc """
  Maps an agent session lifecycle status to the corresponding card status.

  Agent sessions speak in `Tab.agent_status` (`:idle | :plan | :thinking | :tool_executing
  | :error | nil`); cards have a richer status vocabulary intended for the Board
  grid. This mapping is the single source of truth so foreground (active session)
  and background (non-active session) routing apply the same translation.
  """
  @spec from_agent_status(MingaEditor.State.Tab.agent_status()) :: status()
  def from_agent_status(:plan), do: :needs_you
  def from_agent_status(:thinking), do: :working
  def from_agent_status(:tool_executing), do: :iterating
  def from_agent_status(:error), do: :errored
  def from_agent_status(:idle), do: :done
  def from_agent_status(_), do: :idle

  @spec normalize_workspace(workspace_snapshot() | TabContext.legacy() | nil) ::
          workspace_snapshot() | nil
  defp normalize_workspace(nil), do: nil
  defp normalize_workspace(workspace) when is_map(workspace), do: TabContext.from_map(workspace)

  @spec update_workspace_feature_state(t(), (FeatureState.t() -> FeatureState.t())) :: t()
  defp update_workspace_feature_state(%__MODULE__{workspace: workspace} = card, fun)
       when is_map(workspace) do
    context = TabContext.from_map(workspace)

    if :feature_state in context.present_fields do
      feature_state = context.feature_state || FeatureState.new()
      context = TabContext.put_fields(context, feature_state: fun.(feature_state))
      store_workspace(card, context)
    else
      card
    end
  end

  defp update_workspace_feature_state(%__MODULE__{} = card, _fun), do: card
end
