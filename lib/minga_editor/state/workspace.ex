defmodule MingaEditor.State.Workspace do
  @moduledoc """
  Domain model for an editor workspace.

  A workspace owns a task context. The manual workspace represents project-owned file work, while agent workspaces attach one optional agent session and later become the home for workspace files, agent UI, ProjectView, and review state.
  """

  alias Minga.Project.FileRef
  alias MingaEditor.State.WorkspaceReview

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
          files: [FileRef.t()],
          active_file: FileRef.t() | nil,
          agent_ui: term() | nil,
          project_view: term() | nil,
          review: WorkspaceReview.t()
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
            review: WorkspaceReview.new()

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

  @doc "Sets the ProjectView owned by the workspace."
  @spec set_project_view(t(), term() | nil) :: t()
  def set_project_view(%__MODULE__{} = workspace, project_view) do
    %{workspace | project_view: project_view}
  end

  @doc "Sets review state through the owning workspace module."
  @spec set_review(t(), WorkspaceReview.t()) :: t()
  def set_review(%__MODULE__{} = workspace, %WorkspaceReview{} = review) do
    %{workspace | review: review}
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
