defmodule MingaEditor.FocusOwnerTest do
  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Editing.Completion
  alias Minga.Keymap.Scope
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.Commands.InlineAsk
  alias MingaEditor.Commands.InlineEdit
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.FocusOwner
  alias MingaEditor.Input
  alias MingaEditor.Input.Router
  alias MingaEditor.PickerUI
  alias MingaEditor.PromptUI
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Search
  alias MingaEditor.UI.Picker.CommandSource
  alias MingaEditor.UI.Prompt.WorkspaceRename

  @modal_rows %{
    none: {:editor_view, :scope},
    conflict: {:editor_view, :conflict},
    prompt: {:editor_view, :prompt},
    picker: {:picker_query, :picker},
    completion: {:editor_view, :completion},
    command_completion: {:editor_view, :command_completion}
  }
  @scope_rows %{editor: :editor, file_tree: :file_tree, agent: :agent, git_status: :git_status}

  # Agent scope claims Escape in command mode; other scopes yield to ModeFSM.
  @modal_scope_rows %{
    {:command_completion, :agent} => {:editor_view, :agent}
  }

  # Every current modal has a producing workflow below. A future tag with no
  # public producing path must be recorded here with its missing path, not
  # manufactured with a raw modal/state update.
  @unreachable_tags %{}

  @handler_surfaces %{
    Input.ConflictPrompt => :conflict,
    Input.InlineEdit => :inline_edit,
    Input.InlineAsk => :inline_ask,
    Input.Prompt => :prompt,
    Input.Picker => :picker,
    Input.Completion => :completion,
    Input.FileTreeHandler => :file_tree,
    Input.Scoped => :scoped,
    Input.AgentPanel => :agent,
    Input.AgentNav => :agent,
    Input.ModeFSM => :editor,
    Input.CUA.Dispatch => :editor,
    MingaGitPorcelain.Input.GitStatus => :git_status
  }

  @tag :tmp_dir
  test "every real modal tag crossed with every registered scope agrees with dispatch", %{
    tmp_dir: root
  } do
    tags = [:none | ModalOverlay.variants()]
    scopes = Scope.all_scopes()

    for tag <- tags do
      assert Map.has_key?(@modal_rows, tag) or Map.has_key?(@unreachable_tags, tag),
             "missing focus agreement row for modal #{inspect(tag)}"
    end

    for scope <- scopes do
      assert Map.has_key?(@scope_rows, scope),
             "missing focus agreement row for registered scope #{inspect(scope)}"
    end

    for tag <- tags, scope <- scopes, not Map.has_key?(@unreachable_tags, tag) do
      path = Path.join(root, "#{tag}-#{scope}.txt")
      File.write!(path, "original\nsecond")
      ctx = start_editor("original\nsecond", file_path: path, project_root: root)
      state = ctx |> activate_modal(tag, path) |> activate_scope(scope, root)
      assert ModalOverlay.tag(state.shell_runtime.state.modal) == tag

      {responder, expected_surface} =
        Map.get(@modal_scope_rows, {tag, scope}, Map.fetch!(@modal_rows, tag))

      surface = resolve_surface(expected_surface, scope)
      probe = probe_key(tag)
      assert_owner_agrees(state, responder, surface, probe, {tag, scope})
    end
  end

  @tag :tmp_dir
  test "inline edit and ask own the active buffer above ordinary modals in every scope", %{
    tmp_dir: root
  } do
    for variant <- [:inline_edit, :inline_ask], scope <- Scope.all_scopes() do
      path = Path.join(root, "#{variant}-#{scope}.txt")
      File.write!(path, "original\nsecond")
      ctx = start_editor("original\nsecond", file_path: path, project_root: root)
      state = activate_inline(ctx, variant)
      state = PromptUI.open(state, WorkspaceRename)
      state = activate_scope(state, scope, root)
      responder = inline_responder(variant)
      assert_owner_agrees(state, responder, variant, 27, {variant, scope})
    end
  end

  @tag :tmp_dir
  test "conflict precedes inline edit, which precedes inline ask", %{tmp_dir: root} do
    path = Path.join(root, "precedence.txt")
    File.write!(path, "original\nsecond")
    ctx = start_editor("original\nsecond", file_path: path, project_root: root)
    state = ctx |> activate_inline(:inline_edit) |> InlineAsk.open()
    assert_owner_agrees(state, :inline_edit, :inline_edit, 27, :edit_before_ask)

    BufferProcess.insert_text(ctx.buffer, "local")
    File.write!(path, "external change that is longer than original")
    state = FileWatcherHelpers.handle_file_change(state, path)
    assert ModalOverlay.tag(state.shell_runtime.state.modal) == :conflict
    assert_owner_agrees(state, :editor_view, :conflict, 27, :conflict_before_inline)
  end

  @tag :tmp_dir
  test "active native search owns its field in every scope and yields to a modal", %{
    tmp_dir: root
  } do
    for scope <- Scope.all_scopes() do
      ctx = start_editor("search me", project_root: root)
      state = ctx |> editor_state() |> activate_scope(scope, root)
      search = Search.focus_gui_search(state.workspace.search, false)
      state = %{state | workspace: SessionState.set_search(state.workspace, search)}

      # Search-field keys never reach Input.Router; only the ownership half of
      # agreement applies to this row. Native query edits use gui_action instead.
      assert %{responder: :search_query, surface: :search, generation: 0} =
               FocusOwner.derive(state)

      state = PromptUI.open(state, WorkspaceRename)
      assert_owner_agrees(state, :editor_view, :prompt, 27, {:prompt_before_search, scope})
    end
  end

  test "picker activation and insert completion use their source-owned generations" do
    ctx = start_editor("hello")
    first = ctx |> editor_state() |> PickerUI.open(CommandSource)
    {:picker, %{picker_ui: picker}} = first.shell_runtime.state.modal
    assert FocusOwner.derive(first).generation == picker.activation_offer.generation
    assert picker.activation_offer.generation > 0

    reopened = first |> ModalWorkflow.dismiss() |> PickerUI.open(CommandSource)
    assert FocusOwner.derive(reopened).generation != FocusOwner.derive(first).generation

    completion_state = activate_modal(ctx, :completion, nil)

    assert FocusOwner.derive(completion_state).generation ==
             ModalWorkflow.completion_generation(completion_state)

    assert FocusOwner.derive(completion_state).generation > 0
  end

  test "command completion retains its source-owned presentation generation" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, ":")
    state = editor_state(ctx)
    payload = ModalWorkflow.command_completion(state)
    owner = FocusOwner.derive(state)
    assert owner.surface == :command_completion
    assert owner.generation == payload.generation
    assert owner.generation > 0

    send_keys_sync(ctx, "w")
    changed = editor_state(ctx)

    assert FocusOwner.derive(changed).generation ==
             ModalWorkflow.command_completion(changed).generation

    assert FocusOwner.derive(changed).generation != owner.generation
  end

  test "completion trigger bookkeeping without a populated popup does not own keyboard input" do
    ctx = start_editor("hello")
    send_keys_sync(ctx, "i")
    state = editor_state(ctx)

    # This is the payload shape ModalOverlay.put_completion_trigger/4 creates
    # while a provider request is pending. Use its public payload/workflow
    # constructors rather than writing the lifecycle tag directly.
    payload = ModalWorkflow.new_completion_payload(nil)
    state = ModalWorkflow.open(state, {:completion, payload})
    assert ModalOverlay.tag(state.shell_runtime.state.modal) == :completion
    assert ModalWorkflow.completion(state) == nil
    assert_owner_agrees(state, :editor_view, :editor, 27, :pending_completion)
  end

  @tag :tmp_dir
  test "file-tree rename admits the native field and confirm or cancel restores tree routing", %{
    tmp_dir: root
  } do
    path = Path.join(root, "original.swift")
    File.write!(path, "original\n")
    ctx = start_editor("original\n", file_path: path, project_root: root)
    state = ctx |> editor_state() |> activate_scope(:file_tree, root)

    for completion <- [:confirm_editing, :cancel_editing] do
      editing = MingaEditor.Commands.FileTree.rename(state)
      token = FileTreeState.editing(editing.workspace.file_tree).token

      assert %{responder: :inline_edit, surface: :inline_edit, generation: ^token} =
               FocusOwner.derive(editing)

      finished = apply(MingaEditor.Commands.FileTree, completion, [editing])
      assert FileTreeState.editing(finished.workspace.file_tree) == nil
      assert finished.workspace.keymap_scope == :file_tree
      assert %{responder: :editor_view, surface: :file_tree} = FocusOwner.derive(finished)
    end
  end

  test "focused hover and empty launchpad name the actual BEAM-routed surface" do
    alias Mix.Tasks.Conformance.FocusScenarios
    base = %MingaEditor.State{workspace: %SessionState{}}
    hover = FocusScenarios.transition(base, :hover_open)
    assert %{responder: :editor_view, surface: :hover_popup} = FocusOwner.derive(hover)
    search = FocusScenarios.transition(hover, :search_open)
    assert %{responder: :search_query, surface: :search} = FocusOwner.derive(search)
    empty = FocusScenarios.transition(base, :empty_state)
    assert %{responder: :editor_view, surface: :empty_state} = FocusOwner.derive(empty)
  end

  @tag :tmp_dir
  test "normal leader ownership follows the launchpad and sidebar admission rules", %{
    tmp_dir: root
  } do
    ctx = start_editor("leader target")
    send_keys_sync(ctx, " ")
    leader = editor_state(ctx)
    assert Minga.Editing.in_leader?(leader)

    launchpad =
      MingaEditor.State.Launchpad.new(recents: [], session_file_count: 0, crashed?: false)

    empty = %{leader | workspace: SessionState.set_launchpad(leader.workspace, launchpad)}
    assert {:passthrough, _} = MingaEditor.Input.EmptyState.handle_key(empty, 0xF701, 0)
    assert %{responder: :editor_view, surface: :editor, generation: 0} = FocusOwner.derive(empty)

    file_tree = activate_scope(leader, :file_tree, root)

    assert %{responder: :editor_view, surface: :editor, generation: 0} =
             FocusOwner.derive(file_tree)

    assert {:handled, after_down} =
             MingaEditor.Input.FileTreeHandler.handle_key(file_tree, 0xF701, 0)

    refute Minga.Editing.in_leader?(after_down)

    git_status = activate_scope(leader, :git_status, root)

    assert %{responder: :editor_view, surface: :editor, generation: 0} =
             FocusOwner.derive(git_status)
  end

  @tag :tmp_dir
  test "leader projection preserves higher-priority native edit and hover admission", %{
    tmp_dir: root
  } do
    path = Path.join(root, "original.swift")
    File.write!(path, "original\n")
    ctx = start_editor("original\n", file_path: path, project_root: root)
    send_keys_sync(ctx, " ")
    leader = editor_state(ctx)
    assert Minga.Editing.in_leader?(leader)

    editing = leader |> activate_scope(:file_tree, root) |> MingaEditor.Commands.FileTree.rename()
    token = FileTreeState.editing(editing.workspace.file_tree).token

    assert %{responder: :inline_edit, surface: :inline_edit, generation: ^token} =
             FocusOwner.derive(editing)

    hover = Mix.Tasks.Conformance.FocusScenarios.transition(leader, :hover_open)
    assert %{responder: :editor_view, surface: :hover_popup} = FocusOwner.derive(hover)
    assert {:handled, _} = MingaEditor.Input.Hover.handle_key(hover, ?j, 0)
  end

  test "agent leader admission is not generalized past its navigation fallback" do
    ctx = start_editor("agent leader")
    send_keys_sync(ctx, " ")
    agent = activate_scope(editor_state(ctx), :agent, nil)
    assert Minga.Editing.in_leader?(agent)
    assert {:passthrough, _} = MingaEditor.Input.Scoped.handle_key(agent, ?j, 0)
    assert {:handled, _} = MingaEditor.Input.AgentNav.handle_key(agent, ?j, 0)
    assert %{responder: :editor_view, surface: :agent} = FocusOwner.derive(agent)
  end

  defp activate_modal(ctx, :none, _path), do: editor_state(ctx)
  defp activate_modal(ctx, :prompt, _path), do: PromptUI.open(editor_state(ctx), WorkspaceRename)
  defp activate_modal(ctx, :picker, _path), do: PickerUI.open(editor_state(ctx), CommandSource)

  defp activate_modal(ctx, :conflict, path) do
    BufferProcess.insert_text(ctx.buffer, "local")
    File.write!(path, "external change that is longer than original")
    FileWatcherHelpers.handle_file_change(editor_state(ctx), path)
  end

  defp activate_modal(ctx, :completion, _path) do
    send_keys_sync(ctx, "i")
    state = editor_state(ctx)
    completion = Completion.new([%{label: "hello", insert_text: "hello"}], {0, 0})
    payload = ModalWorkflow.new_completion_payload(nil, completion: completion)
    ModalWorkflow.open(state, {:completion, payload})
  end

  # ':' is the real KeyDispatch producing path for :command_completion. Its
  # keys are claimed by ModeFSM (or FileTreeHandler delegating to ModeFSM),
  # unlike insert completion, which Input.Completion claims directly.
  defp activate_modal(ctx, :command_completion, _path) do
    send_keys_sync(ctx, ":")
    editor_state(ctx)
  end

  defp activate_inline(ctx, :inline_edit) do
    send_keys_sync(ctx, "v")
    InlineEdit.open(editor_state(ctx))
  end

  defp activate_inline(ctx, :inline_ask), do: InlineAsk.open(editor_state(ctx))

  defp activate_scope(state, :file_tree, root) do
    tree = FileTree.new(root)
    buffer = start_supervised!({BufferProcess, content: ""}, id: make_ref())
    BufferSync.sync(buffer, tree)
    file_tree = FileTreeState.open(state.workspace.file_tree, tree, buffer)
    workspace = SessionState.set_file_tree(state.workspace, file_tree)
    %{state | workspace: SessionState.set_keymap_scope(workspace, :file_tree)}
  end

  defp activate_scope(state, scope, _root),
    do: %{state | workspace: SessionState.set_keymap_scope(state.workspace, scope)}

  defp assert_owner_agrees(state, responder, surface, probe, row) do
    owner = FocusOwner.derive(state)
    assert {owner.responder, owner.surface} == {responder, surface}, inspect(row)
    assert owner.window_id == state.workspace.windows.active, inspect(row)
    handler = Router.claiming_handler(state, probe, 0)

    assert handler_surface(handler, state) == surface,
           "#{inspect(row)} claimed by #{inspect(handler)}"
  end

  defp handler_surface(handler, %{workspace: %{editing: %{mode: :command}}})
       when handler in [Input.ModeFSM, Input.FileTreeHandler],
       do: :command_completion

  defp handler_surface(Input.Scoped, %{workspace: %{keymap_scope: :agent}}), do: :agent
  defp handler_surface(handler, _state), do: Map.fetch!(@handler_surfaces, handler)

  defp resolve_surface(:scope, scope), do: Map.fetch!(@scope_rows, scope)
  defp resolve_surface(surface, _scope), do: surface
  defp probe_key(:none), do: ?j
  defp probe_key(_modal), do: 27
  defp inline_responder(:inline_edit), do: :inline_edit
  defp inline_responder(:inline_ask), do: :editor_view
end
