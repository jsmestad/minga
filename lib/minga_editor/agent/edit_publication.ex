defmodule MingaEditor.Agent.EditPublication do
  @moduledoc """
  Publishes or discards the approved agent edits staged in an editor-owned project view.

  An editor-started agent session edits files through the workspace's overlay `MingaAgent.ProjectView`. Approved edits are staged there (in a buffer fork for open files, in the changeset for other files) and stay off disk until the user publishes them. This module owns that lifecycle on the Editor side:

  * `record_edit/3` and `turn_finished/2` keep the workspace review state in step with agent file events. They are pure state transitions, safe on the Editor mailbox.
  * `publish/2` and `discard/2` refresh the review from the authoritative `ProjectView.diff/1`, then promote or discard the view. A successful promote or discard stops the view's changeset, so a live session's provider is first moved to a fresh overlay, and the workspace adopts it.
  * `before_quit/1` is the editor's exit gate: it blocks while any workspace still holds staged edits and offers Publish or Discard. `discard_all/1` is the explicit discard for force and abort exits.

  Publication runs while the agent is between turns. The provider is the authority: it refuses the move to a fresh overlay while a request is active, and then nothing is published or discarded. After a failed or conflicted publication the provider returns to the original view, which still holds the staged edits.
  """

  alias Minga.Buffer
  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaAgent.Session
  alias MingaEditor.Handlers.Notifications
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.WorkspaceReview
  alias MingaEditor.WorkspaceWorkflow

  @typedoc "The workspace a publish or discard acts on."
  @type target :: :active | pos_integer()

  @typedoc "Outcome of promoting one workspace's project view."
  @type promote_result ::
          {:ok, Workspace.t()} | {:review_fork, Workspace.t(), String.t()} | {:error, term()}

  @typedoc "A provider moved to a fresh overlay before its view is retired."
  @type handoff :: %{fresh: ProjectView.t() | nil, provider: pid() | nil}

  @busy_statuses [:thinking, :tool_executing, :approval_waiting]

  @doc "Records one agent-edited path on the workspace bound to `session`."
  @spec record_edit(EditorState.t(), pid() | nil, String.t()) :: EditorState.t()
  def record_edit(%EditorState{} = state, session, path)
      when is_pid(session) and is_binary(path) do
    with %TabBar{} = tb <- tab_bar(state),
         %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{} = view}} = workspace <-
           TabBar.find_workspace_by_session(tb, session),
         {:ok, %FileRef{} = file_ref} <- FileRef.from_path(view.project_root, path),
         {:ok, updated} <- Workspace.transition_review(workspace, :agent_edited, file_ref) do
      install_workspace(state, tb, updated)
    else
      _not_staged -> state
    end
  end

  def record_edit(%EditorState{} = state, _session, _path), do: state

  @doc """
  Marks a finished turn's staged edits as ready for review and tells the user.

  Only a workspace still drafting changes state, so repeated idle events post the notification once per turn.
  """
  @spec turn_finished(EditorState.t(), pid()) :: EditorState.t()
  def turn_finished(%EditorState{} = state, session) when is_pid(session) do
    with %TabBar{} = tb <- tab_bar(state),
         %Workspace{review: %WorkspaceReview{state: :draft} = review} = workspace <-
           TabBar.find_workspace_by_session(tb, session),
         {:ok, updated} <-
           Workspace.transition_review(workspace, :agent_completed, review.changed_files) do
      state
      |> install_workspace(tb, updated)
      |> notify_pending(updated)
    else
      _not_drafting -> state
    end
  end

  @doc "Publishes the target workspace's staged agent edits to disk and open buffers."
  @spec publish(EditorState.t(), target()) :: EditorState.t()
  def publish(%EditorState{} = state, target) do
    with_staged_workspace(state, target, "publish", fn state, tb, workspace, count, handoff ->
      workspace
      |> promote()
      |> install_publish_result(state, tb, workspace, count, handoff)
    end)
  end

  @doc "Discards the target workspace's staged agent edits without touching disk."
  @spec discard(EditorState.t(), target()) :: EditorState.t()
  def discard(%EditorState{} = state, target) do
    with_staged_workspace(state, target, "discard", fn state, tb, workspace, count, handoff ->
      case discard_view(workspace) do
        {:ok, discarded} ->
          state
          |> install_workspace(tb, complete_handoff(discarded, handoff))
          |> Notifications.dismiss_agent_edits(workspace.id)
          |> NoticeWorkflow.publish("Discarded agent edits in #{files_copy(count)}")

        {:error, reason} ->
          abandon_handoff(workspace, handoff)
          NoticeWorkflow.publish(state, "Discarding agent edits failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Promotes one workspace's view and applies the matching review transition.

  Shared by the publish command and the reviewed workspace promote command.
  """
  @spec promote(Workspace.t()) :: promote_result()
  def promote(
        %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{} = view}} = workspace
      ) do
    case ProjectView.promote(view, :project_root) do
      :ok ->
        Workspace.transition_review(workspace, :promote_succeeded)

      {:conflict, details} ->
        with {:ok, updated} <-
               Workspace.transition_review(
                 workspace,
                 :promote_found_overlaps,
                 {WorkspaceReview.conflict_file_refs(view.project_root, details), details}
               ) do
          conflict_review(updated, view.project_root, details)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def promote(%Workspace{}), do: {:error, :missing_project_view}

  # Opens the first fork conflict for review when one exists.
  @spec conflict_review(Workspace.t(), String.t(), map()) :: promote_result()
  defp conflict_review(updated, project_root, details) do
    case Enum.find(details.conflicts, &match?({:conflict, _, [_ | _]}, &1)) do
      {:conflict, path, _} -> {:review_fork, updated, Path.join(project_root, path)}
      nil -> {:ok, updated}
    end
  end

  @doc """
  Refreshes a workspace's review state from its view's authoritative diff.

  Clean or drafting work moves to review when files differ; no differences make the review clean.
  """
  @spec refresh_review(Workspace.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def refresh_review(%Workspace{} = workspace) do
    with {:ok, files} <- changed_files(workspace) do
      refresh_review(workspace, files, workspace.review.state)
    end
  end

  @doc """
  Checks every workspace for staged agent edits before the editor exits.

  Returns `{:ok, state}` when nothing is staged. Otherwise posts a Publish/Discard card per workspace and a notice, and returns `{:blocked, state}`.
  """
  @spec before_quit(EditorState.t()) :: {:ok, EditorState.t()} | {:blocked, EditorState.t()}
  def before_quit(%EditorState{} = state) do
    case staged_workspaces(state) do
      [] ->
        {:ok, state}

      staged ->
        state =
          Enum.reduce(staged, state, fn {workspace, count}, state ->
            state
            |> install_workspace(tab_bar(state), workspace)
            |> Notifications.agent_edits_unpublished(workspace.id, workspace.label, count)
          end)

        total = staged |> Enum.map(&elem(&1, 1)) |> Enum.sum()

        {:blocked,
         NoticeWorkflow.publish(
           state,
           "#{Notifications.agent_edits_title(total)}. Publish (SPC a p) or discard (SPC a P) them before quitting. :qa!, :q! and :cq quit and discard them."
         )}
    end
  end

  @doc "Explicitly discards every workspace's staged agent edits, for force and abort quits (`:qa!`, `:q!`, `:cq`)."
  @spec discard_all(EditorState.t()) :: EditorState.t()
  def discard_all(%EditorState{} = state) do
    Enum.each(staged_workspaces(state), fn {workspace, _count} -> discard_view(workspace) end)
    state
  end

  # ── Publish/discard workflow ────────────────────────────────────────────

  @spec with_staged_workspace(
          EditorState.t(),
          target(),
          String.t(),
          (EditorState.t(), TabBar.t(), Workspace.t(), pos_integer(), handoff() ->
             EditorState.t())
        ) :: EditorState.t()
  defp with_staged_workspace(state, target, verb, action) do
    with %TabBar{} = tb <- tab_bar(state),
         {:ok, workspace} <- target_workspace(tb, target),
         :ok <- ensure_between_turns(workspace, verb),
         {:ok, refreshed} <- refresh_review(workspace) do
      case WorkspaceReview.draft_count(refreshed.review) do
        0 ->
          state
          |> install_workspace(tb, refreshed)
          |> Notifications.dismiss_agent_edits(refreshed.id)
          |> NoticeWorkflow.publish("No unpublished agent edits")

        count ->
          state = install_workspace(state, tb, refreshed)
          handoff_then(state, refreshed, verb, &action.(&1, tab_bar(&1), refreshed, count, &2))
      end
    else
      nil ->
        NoticeWorkflow.publish(state, "No unpublished agent edits")

      {:refused, message} ->
        NoticeWorkflow.publish(state, message)

      {:error, reason} ->
        NoticeWorkflow.publish(state, "Agent edits unavailable: #{inspect(reason)}")
    end
  end

  @spec handoff_then(
          EditorState.t(),
          Workspace.t(),
          String.t(),
          (EditorState.t(), handoff() -> EditorState.t())
        ) :: EditorState.t()
  defp handoff_then(state, workspace, verb, action) do
    case prepare_handoff(workspace, verb) do
      {:ok, handoff} -> action.(state, handoff)
      {:refused, message} -> NoticeWorkflow.publish(state, message)
    end
  end

  @spec install_publish_result(
          promote_result(),
          EditorState.t(),
          TabBar.t(),
          Workspace.t(),
          pos_integer(),
          handoff()
        ) :: EditorState.t()
  defp install_publish_result(
         {:ok, %Workspace{review: %WorkspaceReview{state: :conflict}} = conflicted},
         state,
         tb,
         workspace,
         _count,
         handoff
       ) do
    abandon_handoff(workspace, handoff)

    state
    |> install_workspace(tb, conflicted)
    |> NoticeWorkflow.publish(
      "Some agent edits conflict with newer changes on disk; they stay staged for review"
    )
  end

  defp install_publish_result({:ok, published}, state, tb, workspace, count, handoff) do
    acknowledge_open_buffers(workspace.review.changed_files)

    state
    |> install_workspace(tb, complete_handoff(published, handoff))
    |> Notifications.dismiss_agent_edits(workspace.id)
    |> NoticeWorkflow.publish("Published agent edits in #{files_copy(count)} to disk")
  end

  defp install_publish_result({:review_fork, conflicted, path}, state, tb, workspace, _, handoff) do
    abandon_handoff(workspace, handoff)

    state
    |> install_workspace(tb, conflicted)
    |> NoticeWorkflow.publish(
      "Some agent edits conflict with newer changes; review the conflicts, then publish again"
    )
    |> MingaEditor.Effects.AgentReview.schedule(path)
  end

  defp install_publish_result({:error, reason}, state, _tb, workspace, _count, handoff) do
    abandon_handoff(workspace, handoff)
    NoticeWorkflow.publish(state, "Publishing agent edits failed: #{inspect(reason)}")
  end

  # Publication merged each open buffer and wrote the same text to disk. The
  # buffer owner clears its modified flag only when disk and buffer match.
  @spec acknowledge_open_buffers([FileRef.t()]) :: :ok
  defp acknowledge_open_buffers(files) do
    Enum.each(files, fn
      %FileRef{kind: :path, project_root: root, relative_path: path} ->
        acknowledge_open_buffer(Path.join(root, path))

      _buffer_ref ->
        :ok
    end)
  end

  @spec acknowledge_open_buffer(String.t()) :: :ok
  defp acknowledge_open_buffer(path) do
    with {:ok, buffer} <- Buffer.pid_for_path(path) do
      _ = Buffer.mark_saved_if_disk_matches(buffer)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @spec target_workspace(TabBar.t(), target()) ::
          {:ok, Workspace.t()} | {:refused, String.t()} | nil
  defp target_workspace(tb, :active) do
    case TabBar.active_workspace(tb) do
      %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{}}} = workspace ->
        {:ok, workspace}

      _manual_or_unstaged ->
        tb.workspaces
        |> Enum.filter(&staged_view?/1)
        |> single_staged_workspace()
    end
  end

  defp target_workspace(tb, workspace_id) when is_integer(workspace_id) do
    case TabBar.get_workspace(tb, workspace_id) do
      %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{}}} = workspace ->
        {:ok, workspace}

      _missing ->
        nil
    end
  end

  @spec single_staged_workspace([Workspace.t()]) ::
          {:ok, Workspace.t()} | {:refused, String.t()} | nil
  defp single_staged_workspace([]), do: nil
  defp single_staged_workspace([workspace]), do: {:ok, workspace}

  defp single_staged_workspace([_ | _]),
    do: {:refused, "Several agent workspaces have staged edits; switch to one first"}

  @spec staged_view?(Workspace.t()) :: boolean()
  defp staged_view?(%Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{}}} = ws),
    do: WorkspaceReview.pending?(ws.review)

  defp staged_view?(%Workspace{}), do: false

  @spec ensure_between_turns(Workspace.t(), String.t()) :: :ok | {:refused, String.t()}
  defp ensure_between_turns(
         %Workspace{payload: %WorkspaceAgent{session: session, agent_status: status}},
         verb
       )
       when is_pid(session) and status in @busy_statuses do
    if live_local_session?(session),
      do: {:refused, "Wait for the agent turn to finish before you #{verb} its edits"},
      else: :ok
  end

  defp ensure_between_turns(%Workspace{}, _verb), do: :ok

  @spec discard_view(Workspace.t()) :: {:ok, Workspace.t()} | {:error, term()}
  defp discard_view(
         %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{} = view}} = workspace
       ) do
    with :ok <- ProjectView.discard(view) do
      {:ok, Workspace.set_review(workspace, WorkspaceReview.clean(workspace.review))}
    end
  end

  # ── Provider handoff ────────────────────────────────────────────────────
  #
  # A successful promote or discard stops the view's changeset. Before touching
  # the view, a live session's provider is moved to a fresh overlay. The provider
  # is the authority on whether a turn is running: it refuses the move with
  # `:request_active`, and then nothing is published or discarded. After a failed
  # or conflicted publication the provider moves back to the original view, which
  # still holds the staged edits.

  @spec prepare_handoff(Workspace.t(), String.t()) :: {:ok, handoff()} | {:refused, String.t()}
  defp prepare_handoff(
         %Workspace{
           payload: %WorkspaceAgent{project_view: %ProjectView{} = old, session: session}
         },
         verb
       )
       when is_pid(session) do
    if live_local_session?(session),
      do: hand_off_live_session(old, session, verb),
      else: no_handoff()
  end

  defp prepare_handoff(%Workspace{}, _verb), do: no_handoff()

  @spec no_handoff() :: {:ok, handoff()}
  defp no_handoff, do: {:ok, %{fresh: nil, provider: nil}}

  @spec hand_off_live_session(ProjectView.t(), pid(), String.t()) ::
          {:ok, handoff()} | {:refused, String.t()}
  defp hand_off_live_session(%ProjectView{} = old, session, verb) do
    case ProjectView.overlay(old.project_root) do
      {:ok, fresh} ->
        move_provider(fresh, session_provider(session), verb)

      {:error, reason} ->
        {:refused,
         "Agent edits stay staged: a new staging area could not be created (#{inspect(reason)})"}
    end
  end

  @spec move_provider(ProjectView.t(), pid() | nil, String.t()) ::
          {:ok, handoff()} | {:refused, String.t()}
  defp move_provider(%ProjectView{} = fresh, nil, _verb),
    do: {:ok, %{fresh: fresh, provider: nil}}

  defp move_provider(%ProjectView{} = fresh, provider, verb) do
    case refresh_provider(provider, fresh) do
      :ok ->
        {:ok, %{fresh: fresh, provider: provider}}

      {:error, :request_active} ->
        close_view(fresh)
        {:refused, "Wait for the agent turn to finish before you #{verb} its edits"}

      {:error, reason} ->
        close_view(fresh)

        {:refused,
         "Agent edits stay staged: the agent's editable view could not be renewed (#{inspect(reason)})"}
    end
  end

  # The fresh overlay replaces the retired view; without a live session the
  # workspace drops the dead view and the next session creates one.
  @spec complete_handoff(Workspace.t(), handoff()) :: Workspace.t()
  defp complete_handoff(
         %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{} = old}} = workspace,
         %{fresh: fresh}
       ) do
    close_view(old)
    Workspace.set_project_view(workspace, fresh)
  end

  defp complete_handoff(%Workspace{} = workspace, %{fresh: fresh}),
    do: Workspace.set_project_view(workspace, fresh)

  # The workspace keeps the original view with its staged edits. The provider
  # returns to it; if it cannot, the user is told which view the agent now uses.
  @spec abandon_handoff(Workspace.t(), handoff()) :: :ok
  defp abandon_handoff(_workspace, %{fresh: nil}), do: :ok

  defp abandon_handoff(_workspace, %{fresh: fresh, provider: nil}), do: close_view(fresh)

  defp abandon_handoff(
         %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{} = old}},
         %{fresh: fresh, provider: provider}
       ) do
    case refresh_provider(provider, old) do
      :ok ->
        close_view(fresh)

      {:error, reason} ->
        Minga.API.message(
          "Agent editable view could not be restored after a failed publish (#{inspect(reason)}). The agent now edits a new staging area; earlier staged edits remain in review."
        )
    end
  end

  @spec session_provider(pid()) :: pid() | nil
  defp session_provider(session) do
    # minga:allow-blocking — Editor, once per user publish or discard of agent edits
    case Session.get_provider(session) do
      provider when is_pid(provider) -> provider
      _no_provider -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec live_local_session?(pid()) :: boolean()
  defp live_local_session?(session) when node(session) == node(), do: Process.alive?(session)
  defp live_local_session?(_remote_session), do: false

  @spec refresh_provider(pid(), ProjectView.t()) :: :ok | {:error, term()}
  defp refresh_provider(provider, %ProjectView{} = view) do
    MingaAgent.Providers.Native.refresh_project_view(provider, view)
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  @spec close_view(ProjectView.t()) :: :ok
  defp close_view(%ProjectView{} = view) do
    _ = ProjectView.close(view)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── Review refresh ──────────────────────────────────────────────────────

  @spec refresh_review(Workspace.t(), [FileRef.t()], WorkspaceReview.state()) ::
          {:ok, Workspace.t()} | {:error, term()}
  defp refresh_review(%Workspace{} = workspace, [], _state),
    do: {:ok, Workspace.set_review(workspace, WorkspaceReview.clean(workspace.review))}

  defp refresh_review(%Workspace{} = workspace, files, :clean) do
    with {:ok, workspace} <- Workspace.transition_review(workspace, :agent_started_editing, files) do
      Workspace.transition_review(workspace, :agent_completed, files)
    end
  end

  defp refresh_review(%Workspace{} = workspace, files, :draft),
    do: Workspace.transition_review(workspace, :agent_completed, files)

  defp refresh_review(%Workspace{} = workspace, files, state)
       when state in [:needs_review, :conflict] do
    {:ok,
     Workspace.set_review(
       workspace,
       WorkspaceReview.set_changed_files(workspace.review, files)
     )}
  end

  @spec changed_files(Workspace.t()) :: {:ok, [FileRef.t()]} | {:error, term()}
  defp changed_files(%Workspace{
         payload: %WorkspaceAgent{project_view: %ProjectView{} = view}
       }) do
    with {:ok, entries} <- ProjectView.diff(view) do
      {:ok, WorkspaceReview.changed_file_refs(view.project_root, entries)}
    end
  end

  defp changed_files(%Workspace{}), do: {:ok, []}

  @spec staged_workspaces(EditorState.t()) :: [{Workspace.t(), pos_integer()}]
  defp staged_workspaces(state) do
    case tab_bar(state) do
      %TabBar{workspaces: workspaces} ->
        for %Workspace{payload: %WorkspaceAgent{project_view: %ProjectView{} = view}} = ws <-
              workspaces,
            ProjectView.active?(view),
            {:ok, %Workspace{} = refreshed} <- [refresh_review(ws)],
            count <- [WorkspaceReview.draft_count(refreshed.review)],
            count > 0,
            do: {refreshed, count}

      _no_tab_bar ->
        []
    end
  end

  # ── Presentation and installation ───────────────────────────────────────

  @spec notify_pending(EditorState.t(), Workspace.t()) :: EditorState.t()
  defp notify_pending(state, %Workspace{review: review} = workspace) do
    case WorkspaceReview.draft_count(review) do
      0 -> state
      count -> Notifications.agent_edits_unpublished(state, workspace.id, workspace.label, count)
    end
  end

  @spec files_copy(pos_integer()) :: String.t()
  defp files_copy(1), do: "1 file"
  defp files_copy(count), do: "#{count} files"

  @spec tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp tab_bar(%EditorState{shell_runtime: runtime}), do: Runtime.traditional_tab_bar(runtime)

  @spec install_workspace(EditorState.t(), TabBar.t(), Workspace.t()) :: EditorState.t()
  defp install_workspace(state, %TabBar{} = tb, %Workspace{} = workspace),
    do: WorkspaceWorkflow.install_tab_bar(state, TabBar.accept_workspace(tb, workspace))
end
