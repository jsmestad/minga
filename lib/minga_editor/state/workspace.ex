defmodule MingaEditor.State.Workspace do
  @moduledoc """
  Domain model for an editor workspace.

  A workspace owns a task context. The manual workspace represents project-owned file work, while agent workspaces attach one optional agent session and later become the home for workspace files, agent UI, ProjectView, and review state.
  """

  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaEditor.State.WorkspaceReview

  @typedoc "Workspace kind."
  @type kind :: :manual | :agent

  @typedoc "Agent status for workspace display."
  @type agent_status ::
          :idle
          | :plan
          | :thinking
          | :tool_executing
          | :error
          | :stopped
          | :needs_review
          | :done
          | nil

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
          project_view: ProjectView.t() | nil,
          review: WorkspaceReview.t(),
          project_root: String.t() | nil
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
            review: WorkspaceReview.new(),
            project_root: nil

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
      remote_session: nil,
      project_root: normalize_project_root(project_root)
    }
  end

  @doc "Creates a new agent workspace with a unique id."
  @spec new_agent(pos_integer(), String.t(), pid() | nil, String.t() | nil) :: t()
  def new_agent(id, label, session \\ nil, project_root \\ nil) when is_integer(id) and id > 0 do
    %__MODULE__{
      id: id,
      kind: :agent,
      label: label,
      icon: "cpu",
      color: agent_color(id),
      agent_status: :idle,
      session: session,
      agent_ui: UIState.new(),
      project_root: normalize_project_root(project_root)
    }
  end

  @doc "Sets the agent status on the workspace."
  @spec set_agent_status(t(), agent_status()) :: t()
  def set_agent_status(%__MODULE__{} = workspace, status) do
    %{workspace | agent_status: status}
  end

  @doc "Sets the workspace-owned agent UI projection."
  @spec set_agent_ui(t(), UIState.t() | nil) :: t()
  def set_agent_ui(%__MODULE__{} = workspace, %UIState{} = agent_ui) do
    struct!(workspace, agent_ui: agent_ui)
  end

  def set_agent_ui(%__MODULE__{} = workspace, nil) do
    struct!(workspace, agent_ui: nil)
  end

  @doc "Sets the ProjectView owned by the workspace."
  @spec set_project_view(t(), ProjectView.t() | nil) :: t()
  def set_project_view(%__MODULE__{} = workspace, project_view) do
    %{workspace | project_view: project_view}
  end

  @doc "Sets the session owned by the workspace."
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

  @doc "Returns true when the workspace belongs to the named remote server."
  @spec remote_server?(t(), String.t()) :: boolean()
  def remote_server?(%__MODULE__{remote_session: %RemoteSession{} = remote_session}, server_name) do
    remote_session.server_name == server_name
  end

  def remote_server?(%__MODULE__{}, _server_name), do: false

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

  @doc "Returns true when the workspace still has a live ProjectView."
  @spec project_view_active?(t()) :: boolean()
  def project_view_active?(%__MODULE__{project_view: %ProjectView{} = project_view}) do
    ProjectView.active?(project_view)
  end

  def project_view_active?(%__MODULE__{}), do: false

  @doc "Returns a copy scoped to a project root for persistence."
  @spec with_project_root(t(), String.t() | nil) :: t()
  def with_project_root(%__MODULE__{} = workspace, project_root) do
    %{workspace | project_root: normalize_project_root(project_root)}
  end

  @doc "Sets review state through the owning workspace module."
  @spec set_review(t(), WorkspaceReview.t()) :: t()
  def set_review(%__MODULE__{} = workspace, %WorkspaceReview{} = review) do
    workspace
    |> Map.put(:review, review)
    |> persist()
  end

  @doc "Returns true when drafts or conflicts require user action before close."
  @spec review_pending?(t()) :: boolean()
  def review_pending?(%__MODULE__{review: %WorkspaceReview{} = review}),
    do: WorkspaceReview.pending?(review)

  @doc "Moves review state through a legal transition."
  @spec transition_review(t(), atom(), [FileRef.t()] | nil | term()) ::
          {:ok, t()} | {:error, term()}
  def transition_review(%__MODULE__{} = workspace, event, payload \\ nil) do
    case apply_review_transition(workspace.review, event, payload) do
      {:ok, review} -> {:ok, set_review(workspace, review)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Renames the workspace and protects it from future auto-naming."
  @spec rename(t(), String.t()) :: t()
  def rename(%__MODULE__{} = workspace, name) when is_binary(name) do
    workspace
    |> Map.merge(%{label: name, custom_name: name})
    |> persist()
  end

  @doc "Sets the workspace icon."
  @spec set_icon(t(), String.t()) :: t()
  def set_icon(%__MODULE__{} = workspace, icon) when is_binary(icon) do
    workspace
    |> Map.put(:icon, icon)
    |> persist()
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
      workspace
      |> Map.put(:files, workspace.files ++ [file_ref])
      |> persist()
    end
  end

  @doc "Removes a file membership from the workspace."
  @spec remove_file(t(), FileRef.t()) :: t()
  def remove_file(%__MODULE__{} = workspace, %FileRef{} = file_ref) do
    files = Enum.reject(workspace.files, &FileRef.equal?(&1, file_ref))
    active_file = remove_active_file(workspace.active_file, file_ref)

    workspace
    |> Map.merge(%{files: files, active_file: active_file})
    |> persist()
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
  def set_active_file(%__MODULE__{} = workspace, nil) do
    workspace
    |> Map.put(:active_file, nil)
    |> persist()
  end

  def set_active_file(%__MODULE__{} = workspace, %FileRef{} = file_ref) do
    workspace
    |> add_file(file_ref)
    |> Map.put(:active_file, file_ref)
    |> persist()
  end

  @doc "Serializes the persisted workspace fields to a JSON-ready map."
  @spec to_persisted_map(t()) :: map()
  def to_persisted_map(%__MODULE__{} = workspace) do
    %{
      "schema_version" => 1,
      "id" => workspace.id,
      "kind" => Atom.to_string(workspace.kind),
      "label" => workspace.label,
      "custom_name" => workspace.custom_name,
      "icon" => workspace.icon,
      "color" => workspace.color,
      "files" => Enum.map(workspace.files, &file_ref_to_map/1),
      "active_file" => file_ref_to_map(workspace.active_file),
      "review" => review_to_map(workspace.review)
    }
  end

  @doc "Restores a workspace from persisted JSON data, ignoring unknown fields and using defaults for missing fields."
  @spec from_persisted_map(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_persisted_map(data, project_root) when is_map(data) and is_binary(project_root) do
    root = normalize_project_root(project_root)
    kind = persisted_kind(Map.get(data, "kind"), Map.get(data, "id", 0))
    workspace = default_persisted_workspace(kind, persisted_id(Map.get(data, "id")), root)

    {:ok,
     %{
       workspace
       | label: persisted_string(Map.get(data, "label"), workspace.label),
         custom_name: persisted_nullable_string(Map.get(data, "custom_name")),
         icon: persisted_string(Map.get(data, "icon"), workspace.icon),
         color: persisted_color(Map.get(data, "color"), workspace.color),
         files: persisted_file_refs(Map.get(data, "files"), root),
         active_file: persisted_file_ref(Map.get(data, "active_file"), root),
         review: persisted_review(Map.get(data, "review"), root),
         session: nil,
         agent_status: :stopped,
         project_root: root
     }}
  end

  def from_persisted_map(_data, _project_root), do: {:error, :invalid_workspace_json}

  @spec apply_review_transition(WorkspaceReview.t(), atom(), term()) ::
          {:ok, WorkspaceReview.t()} | {:error, term()}
  defp apply_review_transition(%WorkspaceReview{} = review, :agent_started_editing, files),
    do: WorkspaceReview.agent_started_editing(review, files || [])

  defp apply_review_transition(%WorkspaceReview{} = review, :agent_made_more_edits, files),
    do: WorkspaceReview.agent_made_more_edits(review, files || [])

  defp apply_review_transition(%WorkspaceReview{} = review, :agent_completed, files),
    do: WorkspaceReview.agent_completed(review, files || [])

  defp apply_review_transition(%WorkspaceReview{} = review, :agent_resumed, _payload),
    do: WorkspaceReview.agent_resumed(review)

  defp apply_review_transition(%WorkspaceReview{} = review, :promote_succeeded, _payload),
    do: WorkspaceReview.promote_succeeded(review)

  defp apply_review_transition(
         %WorkspaceReview{} = review,
         :promote_found_overlaps,
         {files, error}
       ),
       do: WorkspaceReview.promote_found_overlaps(review, files, error)

  defp apply_review_transition(%WorkspaceReview{} = review, :discard, _payload),
    do: WorkspaceReview.discard(review)

  defp apply_review_transition(%WorkspaceReview{} = review, :resolved_and_promoted, _payload),
    do: WorkspaceReview.resolved_and_promoted(review)

  defp apply_review_transition(%WorkspaceReview{state: from}, event, _payload),
    do: {:error, {:invalid_transition, from, event}}

  @spec default_persisted_workspace(kind(), non_neg_integer(), String.t() | nil) :: t()
  defp default_persisted_workspace(:manual, _id, project_root), do: new_manual(project_root)

  defp default_persisted_workspace(:agent, id, project_root),
    do: new_agent(max(id, 1), "Agent #{id}", nil, project_root)

  @spec file_ref_to_map(FileRef.t() | nil) :: map() | nil
  defp file_ref_to_map(nil), do: nil

  defp file_ref_to_map(%FileRef{kind: :path} = file_ref) do
    %{
      "kind" => "path",
      "project_root" => file_ref.project_root,
      "relative_path" => file_ref.relative_path,
      "display_name" => file_ref.display_name
    }
  end

  defp file_ref_to_map(%FileRef{kind: :buffer} = file_ref) do
    %{"kind" => "buffer", "display_name" => file_ref.display_name}
  end

  @spec review_to_map(WorkspaceReview.t()) :: map()
  defp review_to_map(%WorkspaceReview{} = review) do
    %{
      "state" => Atom.to_string(review.state),
      "changed_files" => Enum.map(review.changed_files, &file_ref_to_map/1),
      "conflict_files" => Enum.map(review.conflict_files, &file_ref_to_map/1),
      "last_error" => json_safe(review.last_error),
      "in_progress" => review.in_progress?
    }
  end

  @spec json_safe(term()) :: term()
  defp json_safe(value)
       when is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value), do: value

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_safe_key(key), json_safe(item)} end)
  end

  defp json_safe(value), do: inspect(value)

  @spec json_safe_key(term()) :: String.t()
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: inspect(key)

  @spec persisted_id(term()) :: non_neg_integer()
  defp persisted_id(id) when is_integer(id) and id >= 0, do: id
  defp persisted_id(_id), do: 0

  @spec persisted_kind(term(), term()) :: kind()
  defp persisted_kind("manual", _id), do: :manual
  defp persisted_kind("agent", _id), do: :agent
  defp persisted_kind(_kind, 0), do: :manual
  defp persisted_kind(_kind, _id), do: :agent

  @spec persisted_string(term(), String.t()) :: String.t()
  defp persisted_string(value, _default) when is_binary(value), do: value
  defp persisted_string(_value, default), do: default

  @spec persisted_nullable_string(term()) :: String.t() | nil
  defp persisted_nullable_string(value) when is_binary(value), do: value
  defp persisted_nullable_string(_value), do: nil

  @spec persisted_color(term(), non_neg_integer() | nil) :: non_neg_integer() | nil
  defp persisted_color(value, _default) when is_integer(value) and value >= 0, do: value
  defp persisted_color(_value, default), do: default

  @spec persisted_file_refs(term(), String.t() | nil) :: [FileRef.t()]
  defp persisted_file_refs(files, project_root) when is_list(files) do
    Enum.flat_map(files, fn file -> persisted_file_ref_list(file, project_root) end)
  end

  defp persisted_file_refs(_files, _project_root), do: []

  @spec persisted_file_ref_list(term(), String.t() | nil) :: [FileRef.t()]
  defp persisted_file_ref_list(file, project_root) do
    case persisted_file_ref(file, project_root) do
      %FileRef{} = file_ref -> [file_ref]
      nil -> []
    end
  end

  @spec persisted_file_ref(term(), String.t() | nil) :: FileRef.t() | nil
  defp persisted_file_ref(%{"kind" => "path", "relative_path" => path}, project_root)
       when is_binary(path) and is_binary(project_root) do
    case FileRef.from_path(project_root, path) do
      {:ok, file_ref} -> file_ref
      {:error, _reason} -> nil
    end
  end

  defp persisted_file_ref(_file, _project_root), do: nil

  @spec persisted_review(term(), String.t() | nil) :: WorkspaceReview.t()
  defp persisted_review(%{"state" => state} = data, project_root) do
    %WorkspaceReview{
      state: persisted_review_state(state),
      changed_files: persisted_file_refs(Map.get(data, "changed_files"), project_root),
      conflict_files: persisted_file_refs(Map.get(data, "conflict_files"), project_root),
      last_error: Map.get(data, "last_error"),
      in_progress?: false
    }
  end

  defp persisted_review(_data, _project_root), do: WorkspaceReview.new()

  @spec persisted_review_state(term()) :: WorkspaceReview.state()
  defp persisted_review_state("draft"), do: :draft
  defp persisted_review_state("needs_review"), do: :needs_review
  defp persisted_review_state("conflict"), do: :conflict
  defp persisted_review_state(_state), do: :clean

  @spec persist(t()) :: t()
  defp persist(%__MODULE__{project_root: project_root} = workspace) do
    Persistence.write(workspace, project_root)
    workspace
  end

  @spec normalize_project_root(String.t() | nil) :: String.t() | nil
  defp normalize_project_root(project_root) when is_binary(project_root),
    do: Path.expand(project_root)

  defp normalize_project_root(_project_root), do: nil

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

  defp apply_auto_name(name, workspace) do
    workspace
    |> Map.put(:label, name)
    |> persist()
  end

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
