defmodule MingaEditor.Shell.Traditional.ActMenuWorkflow do
  @moduledoc "Opens and applies the shared menu using the original input source."

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.ReviewRibbon
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias Minga.Project.FileTree
  alias Minga.Mode.VisualState
  alias Minga.RenderModel.UI.ActMenu, as: Model
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaEditor.Agent.DraftSave
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.PromptInput
  alias MingaEditor.Agent.TaskWorkflow
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.Commands.Editing
  alias MingaEditor.Commands.Folding
  alias MingaEditor.Effects.ActMenuReviewDiff
  alias MingaEditor.FileTree.Row, as: FileTreeRow
  alias MingaEditor.Frontend
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input.Router
  alias MingaEditor.PickerUI
  alias MingaEditor.PromptUI
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ActMenu
  alias MingaEditor.Shell.Traditional.InFileReview
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Shell.Traditional.TasksDrawerWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Prompt
  alias MingaEditor.UI.Picker.DiagnosticAttachmentSource
  alias MingaEditor.UI.Prompt.RejectReviewSelection
  alias MingaEditor.Target
  alias MingaEditor.VimState.PendingKeep
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus

  @spec current(State.t()) :: ActMenu.t() | nil
  def current(%State{shell_runtime: %Runtime{state: %ShellState{} = shell}}) do
    case ModalOverlay.tag(shell.modal) do
      :conflict -> nil
      _parent -> shell.act_menu
    end
  end

  def current(%State{}), do: nil

  @spec replace(State.t(), ActMenu.t() | nil) :: State.t()
  def replace(
        %State{shell_runtime: %Runtime{state: %ShellState{} = shell} = runtime} = state,
        menu
      ) do
    %{
      state
      | shell_runtime:
          Runtime.install_traditional_state(runtime, ShellState.put_act_menu(shell, menu))
    }
  end

  def replace(%State{} = state, _menu), do: state

  @spec open(State.t()) :: State.t()
  def open(%State{workspace: %{keymap_scope: :file_tree, file_tree: file_tree}} = state) do
    with %FileTree{} = tree <- FileTreeState.resident_tree(file_tree),
         %{path: _path} = entry <- FileTree.selected_entry(tree) do
      open_target(
        state,
        {:file_tree, FileTreeState.presentation_generation(file_tree), FileTreeRow.id_for(entry)}
      )
    else
      _no_entry -> state
    end
  end

  def open(
        %State{workspace: %{keymap_scope: :agent, agent_ui: %{panel: %{input_focused: true}}}} =
          state
      ),
      do: open_composer(state)

  def open(
        %State{
          workspace: %{keymap_scope: :agent},
          shell_runtime: %Runtime{state: %ShellState{} = shell}
        } = state
      ) do
    case ShellState.agent(shell).pending_approval do
      %{approval: %{target: %ApprovalTarget{} = target}} ->
        open_target(state, {:approval, target})

      nil ->
        state
    end
  end

  def open(%State{} = state), do: open_file(state, :caret)

  @doc "Opens on an existing prompt or typing surface without editing that surface."
  @spec open_for_typing(State.t()) :: {:handled, State.t()} | :unbound
  def open_for_typing(
        %State{
          shell_runtime: %Runtime{
            state: %ShellState{modal: {:prompt, %{prompt_ui: %Prompt{} = prompt}}}
          }
        } = state
      ) do
    {role, lead, rows} = prompt_choices(prompt.kind)
    source = {:prompt, prompt.generation}
    {:handled, replace(state, ActMenu.new(prompt.label, role, nil, source, lead, rows))}
  end

  def open_for_typing(%State{shell_runtime: %Runtime{state: %ShellState{modal: {:picker, _}}}}),
    do: :unbound

  def open_for_typing(%State{shell_runtime: %Runtime{state: %ShellState{modal: {:conflict, _}}}}),
    do: :unbound

  def open_for_typing(%State{workspace: %{editing: %{mode: mode, mode_state: input}}} = state)
      when mode in [:command, :search] do
    title = if mode == :command, do: "Command line", else: "Search"
    lead = [{"This prompt", "↩", "Submit", "↩", "", false, {:input, 13}}]
    rows = [{"This prompt", "c", "Cancel", "esc", "", false, {:input, 27}}]
    source = {:input, mode, input, state.workspace.windows.active}
    {:handled, replace(state, ActMenu.new(title, :neutral, nil, source, lead, rows))}
  end

  def open_for_typing(
        %State{workspace: %{keymap_scope: :agent, agent_ui: %{panel: %{input_focused: true}}}} =
          state
      ),
      do: {:handled, open_composer(state)}

  def open_for_typing(%State{workspace: %{editing: %{mode: mode}}} = state)
      when mode in [:insert, :replace],
      do: {:handled, open(state)}

  def open_for_typing(%State{}), do: :unbound

  @spec open_composer(State.t()) :: State.t()
  defp open_composer(state) do
    if available?(state) do
      case composer_source(state) do
        {:composer, _, _, _} = source ->
          {lead, rows} =
            composer_choices(PromptBuffer.prompt_text(state.workspace.agent_ui.panel))

          replace(state, ActMenu.new("Minga draft", :neutral, :caret, source, lead, rows))

        nil ->
          state
      end
    else
      state
    end
  catch
    :exit, _gone -> stale(state)
  end

  @spec composer_choices(String.t()) :: {[ActMenu.choice()], [ActMenu.choice()]}
  defp composer_choices(text) do
    newline = {"Draft", "l", "Insert newline", "⌥↩", "", false, {:composer, :newline}}

    if String.trim(text) == "" do
      {[newline], []}
    else
      submit =
        {"Draft", "↩", "Submit draft", "↩", "Sends now or steers an active turn", false,
         {:composer, :submit}}

      {[submit], [newline]}
    end
  end

  @spec composer_source(State.t()) :: ActMenu.source() | nil
  defp composer_source(state) do
    ui = state.workspace.agent_ui

    with %Window{id: window, content: {:agent_chat, :semantic}} <-
           SessionState.active_window_struct(state.workspace),
         %{input_focused: true, prompt_buffer: buffer} when is_pid(buffer) <- ui.panel,
         %CursorContext{} = cursor <- Buffer.cursor_context(buffer) do
      owner = PromptInput.submission_owner(Runtime.review_scope(state.shell_runtime), ui)
      attachment = DraftSave.attachment_offer(ui.draft_save)

      {:composer, {window, buffer, cursor.version, CursorContext.position(cursor)}, owner,
       attachment}
    else
      _outside -> nil
    end
  end

  @spec prompt_choices(Prompt.kind()) :: {Model.role(), [ActMenu.choice()], [ActMenu.choice()]}
  defp prompt_choices(:confirm) do
    {:neutral,
     [
       {"This prompt", "n", "No", "n / esc", "Leaves things unchanged", false, {:prompt, "No"}},
       {"This prompt", "y", "Yes", "y", "Carries out the requested action", true,
        {:prompt, "Yes"}}
     ], []}
  end

  defp prompt_choices(:text) do
    {:neutral, [{"This prompt", "↩", "Submit", "↩", "", false, {:prompt, "Submit"}}],
     [{"This prompt", "c", "Cancel", "esc", "", false, {:prompt, "Cancel"}}]}
  end

  @spec open_file(State.t(), Model.anchor() | nil) :: State.t()
  def open_file(%State{} = state, anchor) do
    if available?(state), do: open_current_file(state, anchor), else: state
  end

  @spec open_current_file(State.t(), Model.anchor() | nil) :: State.t()
  defp open_current_file(state, anchor) do
    with %Window{id: window, content: {:buffer, buffer}} <-
           SessionState.active_window_struct(state.workspace),
         %{version: version} = cursor <- Buffer.cursor_context(buffer) do
      point = CursorContext.position(cursor)
      source = {window, buffer, version, point}
      {selection, continuation, ordinary_source} = file_selection(state, source)

      case Buffer.prepare_review_with_extent(buffer, selection) do
        {:ok, _, _, _, _} = offer ->
          open_review(state, anchor, source, offer, continuation)

        :empty ->
          show_file(state, anchor, ordinary_source, buffer, cursor)

        {:error, :stale_selection} ->
          stale(state)

        {:error, :invalid_range} ->
          show_file(state, anchor, ordinary_source, buffer, cursor)
      end
    else
      _outside -> state
    end
  catch
    :exit, _gone -> stale(state)
  end

  @spec open_ribbon(State.t(), Window.id(), pos_integer(), ReviewRibbon.head(), Model.anchor()) ::
          State.t()
  def open_ribbon(%State{} = state, window, revision, head, anchor) do
    if available?(state) do
      with {:ok, {buffer, version, _} = lease} <-
             Reader.gutter_source(state.render.text_interaction_reader, window, revision),
           %Window{content: {:buffer, ^buffer}} <- Map.get(state.workspace.windows.map, window),
           {:ok, _, _, _, _} = offer <-
             Buffer.prepare_review_with_extent(buffer, {:presented_ribbon, lease, head}),
           {:ok, focused} <- WindowFocus.focus_buffer_result(state, window, buffer) do
        source = {window, buffer, version, elem(head, 2)}
        open_review(focused, anchor, source, offer, :notice)
      else
        _stale -> stale(state)
      end
    else
      state
    end
  catch
    :exit, _gone -> stale(state)
  end

  @type chrome_target ::
          {:picker, non_neg_integer(), pos_integer()}
          | {:fold, Window.id(), pos_integer(), non_neg_integer()}
          | {:file_tree, non_neg_integer(), String.t()}
          | {:approval, ApprovalTarget.t()}
          | {:task, String.t()}

  @spec open_target(State.t(), chrome_target()) :: State.t()
  def open_target(state, target) do
    if available?(state), do: open_chrome(state, target), else: state
  end

  @spec open_chrome(State.t(), chrome_target()) :: State.t()
  defp open_chrome(state, {:picker, generation, id}),
    do: PickerUI.open_act_menu(state, generation, id)

  defp open_chrome(state, {:task, id}), do: TasksDrawerWorkflow.open_act_menu(state, id)

  defp open_chrome(state, {:approval, target}) do
    case AgentState.approval_for(ShellState.agent(state.shell_runtime.state), target) do
      {:ok, _binding} ->
        lead = [
          {"This request", "y", "Approve once", "y", "Runs this tool call once", false,
           {:approval, :approve}},
          {"This request", "n", "Deny", "n", "Does not run this tool call", true,
           {:approval, :reject}}
        ]

        rows = [
          {"This tool", "t", "Trust this turn", "t", "Allows future calls in this turn", true,
           {:approval, :approve_turn}},
          {"This tool", "a", "Trust this session", "a", "Allows future calls in this session",
           true, {:approval, :approve_session}}
        ]

        replace(
          state,
          ActMenu.new("Needs you · Tool approval", :minga, nil, {:approval, target}, lead, rows)
        )

      {:error, _refused} ->
        stale(state)
    end
  end

  defp open_chrome(state, {:file_tree, generation, id}) do
    target = %Target{surface: :file_tree, intent: :primary, generation: generation, item_id: id}

    case Target.resolve(state, target) do
      {:ok, {:file_tree, _tree, %{name: name, dir?: dir?}}} ->
        {lead, rest} = tree_choices(state, dir?)
        replace(state, ActMenu.new(name, :neutral, nil, {:file_tree, target}, lead, rest))

      _removed ->
        stale(state)
    end
  end

  defp open_chrome(state, {:fold, window, generation, line}) do
    case Target.resolve(state, {:window, window, generation}) do
      {:ok, {:window, %Window{content: {:buffer, buffer}}}} ->
        lead = [{"This fold", "f", "Toggle fold", "za", "", false, {:fold, :toggle}}]
        source = {:fold, window, generation, line, buffer, Buffer.version(buffer)}
        replace(state, ActMenu.new("Fold at line #{line + 1}", :neutral, nil, source, lead, []))

      _gone ->
        stale(state)
    end
  catch
    :exit, _gone -> stale(state)
  end

  @spec tree_choices(State.t(), boolean()) :: {[ActMenu.choice()], [ActMenu.choice()]}
  defp tree_choices(state, dir?) do
    lead = [
      {"This entry", "↩", if(dir?, do: "Toggle folder", else: "Open"), "↩", "", false,
       {:file_tree, :primary}}
    ]

    entry =
      if dir? do
        [
          {"This folder", "f", "New file…", "", "", false, {:file_tree, :new_file}},
          {"This folder", "d", "New folder…", "", "", false, {:file_tree, :new_folder}}
        ]
      else
        [{"This entry", "s", "Open in split", "", "", false, {:file_tree, :open_in_split}}]
      end

    common = [
      {"This entry", "r", "Rename", "", "", false, {:file_tree, :rename}},
      {"This entry", "u", "Duplicate", "", "", false, {:file_tree, :duplicate}},
      {"This entry", "p", "Copy path", "", "", false, {:file_tree, :copy_path}},
      {"This entry", "l", "Copy relative path", "", "", false, {:file_tree, :copy_relative}},
      {"This entry", "x", "Move to Trash", "", "Removes this entry from the project", true,
       {:file_tree, :delete}}
    ]

    native =
      if Capabilities.gui?(state.frontend.capabilities) do
        [
          {"This entry", "v", "Reveal in Finder", "", "", false, {:file_tree, :reveal}},
          {"This entry", "t", "Open in Terminal", "", "", false, {:file_tree, :terminal}}
        ]
      else
        []
      end

    {lead, entry ++ common ++ native}
  end

  @spec click(State.t(), non_neg_integer(), non_neg_integer()) :: State.t()
  def click(state, offer, action) do
    case current(state) do
      nil ->
        state

      menu when action == 0 ->
        if ActMenu.same_offer?(menu, offer), do: replace(state, nil), else: state

      menu when action == 0xFFFF ->
        if ActMenu.same_offer?(menu, offer),
          do: replace(state, ActMenu.begin_filter(menu)),
          else: state

      menu ->
        choose(state, menu, ActMenu.action(menu, offer, action))
    end
  end

  @spec choose(State.t(), ActMenu.t(), ActMenu.action() | nil) :: State.t()
  def choose(state, _menu, nil), do: state

  def choose(state, menu, {:picker, _} = action) do
    case choose_picker(state, menu, action) do
      {:ok, next} -> next
      {:error, :choice_not_found} -> state |> replace(nil) |> stale()
    end
  end

  def choose(state, menu, action) do
    state = replace(state, nil)
    choose_source(state, ActMenu.source(menu), action)
  catch
    :exit, _gone -> stale(state)
  end

  @doc "Applies a picker action and reports if its original item or action is no longer offered."
  @spec choose_picker(State.t(), ActMenu.t(), {:picker, :default | {:source, term()}}) ::
          {:ok, State.t()} | {:error, :choice_not_found}
  def choose_picker(state, menu, {:picker, action}) do
    case ActMenu.source(menu) do
      {:picker, source} -> PickerUI.act_on_item(replace(state, nil), source, action)
      _other -> {:error, :choice_not_found}
    end
  catch
    :exit, _gone -> {:error, :choice_not_found}
  end

  @spec choose_source(State.t(), ActMenu.source(), ActMenu.action()) :: State.t()
  defp choose_source(state, {:prompt, generation}, {:prompt, action}),
    do: PromptUI.activate(state, generation, action)

  defp choose_source(state, {:approval, target}, {:approval, action}),
    do: AgentSubStates.respond_to_tool_approval(state, target, action)

  defp choose_source(state, {:task, _row, {session, target}}, {:task_approval, action}),
    do: TaskWorkflow.answer_presented(state, session, target, action)

  defp choose_source(state, {:task, row, _approval}, {:task, action}),
    do: TasksDrawerWorkflow.click(state, row, action)

  defp choose_source(
         %State{
           workspace: %{windows: %{active: window}, editing: %{mode: mode, mode_state: input}}
         } = state,
         {:input, mode, input, window},
         {:input, codepoint}
       ),
       do: Router.route_key(state, codepoint, 0)

  defp choose_source(state, {:input, _, _, _}, {:input, _}), do: stale(state)

  defp choose_source(state, {:composer, _file, _owner, attachment} = source, {:composer, action}) do
    if composer_source(state) == source do
      case action do
        :newline ->
          AgentCommands.scope_insert_newline(state)

        :submit ->
          PromptInput.with_offer(state, attachment, &AgentCommands.scope_submit_or_newline/1)
      end
    else
      stale(state)
    end
  end

  defp choose_source(state, {:file_tree, target}, {:file_tree, action})
       when action in [:copy_path, :copy_relative, :reveal, :terminal] do
    case Target.resolve(state, target) do
      {:ok, {:file_tree, tree, %{path: path, dir?: dir?}}} ->
        tree_path_action(state, action, tree.root, path, dir?)

      _removed ->
        stale(state)
    end
  end

  defp choose_source(state, {:file_tree, target}, {:file_tree, action}),
    do: GuiActionHandler.dispatch(state, %{target | intent: action})

  defp choose_source(state, {:fold, window, generation, line, buffer, version}, {:fold, :toggle}) do
    case Target.resolve(state, {:window, window, generation}) do
      {:ok, {:window, %Window{content: {:buffer, ^buffer}}}} ->
        if Buffer.version(buffer) == version,
          do: Folding.execute_at_line(state, window, line),
          else: stale(state)

      _gone ->
        stale(state)
    end
  end

  defp choose_source(state, source, action) do
    if source_current?(state, source), do: perform(state, source, action), else: stale(state)
  end

  @spec tree_path_action(
          State.t(),
          :copy_path | :copy_relative | :reveal | :terminal,
          String.t(),
          String.t(),
          boolean()
        ) :: State.t()
  defp tree_path_action(state, action, root, path, _dir?)
       when action in [:copy_path, :copy_relative] do
    value = if action == :copy_path, do: path, else: Path.relative_to(path, root)
    Minga.Clipboard.write_async(value)
    state
  end

  defp tree_path_action(state, action, _root, path, dir?) do
    path = if action == :terminal and not dir?, do: Path.dirname(path), else: path

    if Capabilities.gui?(state.frontend.capabilities) and state.frontend.port_manager do
      Frontend.send_commands(state.frontend.port_manager, [
        Protocol.encode_file_location_action(action, path)
      ])
    end

    state
  end

  @spec available?(State.t()) :: boolean()
  defp available?(%State{
         session: %{pending_quit: nil},
         shell_runtime: %Runtime{state: %ShellState{} = shell}
       }),
       do: ModalOverlay.tag(shell.modal) != :conflict

  defp available?(_state), do: false

  @spec file_selection(State.t(), ActMenu.file_source()) ::
          {Minga.Buffer.Process.review_selection(), PendingKeep.continuation(), ActMenu.source()}
  defp file_selection(
         %State{workspace: %{editing: %{mode: :visual, mode_state: %VisualState{} = visual}}},
         source
       ) do
    {_, _, version, cursor} = source
    selection = {:visual, visual.visual_type, visual.visual_anchor, cursor, version}
    {selection, {:visual, visual, cursor}, {:selection, source, visual}}
  end

  defp file_selection(_state, source), do: {{:cursor, 1}, :notice, {:file, source}}

  @spec open_review(
          State.t(),
          Model.anchor() | nil,
          ActMenu.file_source(),
          {:ok, Minga.Buffer.Process.review_target(), UndoHistory.review_scope(), pos_integer(),
           ReviewRibbon.extent()},
          PendingKeep.continuation()
        ) :: State.t()
  defp open_review(state, anchor, file, {:ok, target, scope, count, extent}, continuation) do
    # The target already owns the whole history decision. At a twist, its
    # several underlying units are one visible action and one receipt.
    count = if continuation == :notice, do: 1, else: count
    {subject, changes} = review_subject(count)

    lead = [
      {"This change", "y", "Keep #{changes}", "SPC a y", "Leaves Minga’s edits in place", false,
       {:review, :keep}},
      {"This change", "n", "Reject #{changes}", "SPC a d", "Undoes Minga’s edits. Yours stay.",
       true, {:review, :reject}}
    ]

    title = "○ " <> subject <> review_size(extent) <> " · unreviewed"

    source = {:review, file, target, count, continuation}
    rows = review_rows(file, scope, continuation)
    replace(state, ActMenu.new(title, :minga, anchor, source, lead, rows))
  end

  @spec review_subject(pos_integer()) :: {String.t(), String.t()}
  defp review_subject(1), do: {"Minga’s change", "change"}
  defp review_subject(count), do: {"#{count} Minga changes", "#{count} changes"}

  @spec review_size(ReviewRibbon.extent()) :: String.t()
  defp review_size({:lines, 1}), do: " · 1 line"
  defp review_size({:lines, lines}), do: " · #{lines} lines"
  defp review_size({:removed_bytes, 1}), do: " · 1 byte removed"
  defp review_size({:removed_bytes, bytes}), do: " · #{bytes} bytes removed"
  defp review_size(:none), do: ""

  @spec review_rows(ActMenu.file_source(), UndoHistory.review_scope(), PendingKeep.continuation()) ::
          [ActMenu.choice()]
  defp review_rows({_, buffer, _, _}, scope, continuation) do
    rows = [{"This change", "=", "Show diff", "=", "", false, {:review, :preview}}]

    conversation =
      case scope do
        {:minga, task} when is_binary(task) ->
          [
            {"This change", "o", "Open conversation", "", "", false,
             {:review, {:conversation, task}}}
          ]

        _multiple ->
          []
      end

    file_rows =
      case Buffer.file_path(buffer) do
        path when is_binary(path) ->
          [
            {"This file", "l", "Copy file:line link", "", "", false, {:review, :copy_link}},
            attach_file_diagnostics()
          ]

        nil ->
          []
      end

    minga = [{"Anywhere", "a", "Ask Minga about this", "SPC a ?", "", false, {:review, :ask}}]

    selection =
      if match?({:visual, _, _}, continuation) do
        [{"Anywhere", "e", "Rewrite selection", "SPC a e", "", false, {:review, :rewrite}}]
      else
        []
      end

    rows ++ conversation ++ file_rows ++ minga ++ selection
  end

  @spec show_file(State.t(), Model.anchor() | nil, ActMenu.source(), pid(), CursorContext.t()) ::
          State.t()
  defp show_file(state, anchor, source, buffer, cursor) do
    title = if is_binary(cursor.file_path), do: Path.basename(cursor.file_path), else: "Editor"
    selection? = match?({:selection, _, _}, source)
    language_server? = is_binary(cursor.file_path) and SyncServer.clients_for_buffer(buffer) != []
    diagnostic = at_cursor_diagnostic(cursor)
    ask = {"Anywhere", "?", "Ask Minga about this", "SPC a ?", "", false, {:command, :inline_ask}}
    {role, lead, more} = file_lead(selection?, language_server?, diagnostic, ask)

    editing = [
      {"This file", "p", "Paste", "p", "", false, {:clipboard, :paste}},
      {"This file", "s", "Select all", "", "", false, {:command, :select_all}},
      {"This file", "t", "Toggle comment", "gcc", "", false, {:command, :toggle_comment_line}},
      {"This file", "b", "Attach buffer to Agent draft", "SPC a x b", "", false,
       {:command, :agent_attach_buffer}},
      {"This file", "m", "Format document", "SPC c f", "", false, {:command, :format_buffer}}
    ]

    editing =
      if is_binary(cursor.file_path), do: [attach_file_diagnostics() | editing], else: editing

    links =
      if language_server? do
        [
          {"At the cursor", "g", "Go to definition", "SPC c d", "", false,
           {:command, :goto_definition}},
          {"At the cursor", "e", "Peek definition", "", "", false, {:command, :peek_definition}},
          {"At the cursor", "r", "Find references", "SPC c D", "", false,
           {:command, :find_references}},
          {"At the cursor", "R", "Rename symbol", "SPC c r", "Changes references to this symbol",
           true, {:command, :rename_symbol}}
        ]
      else
        []
      end

    selection =
      if selection? do
        [
          {"This selection", "a", "Attach selection to Agent draft", "", "", false,
           {:command, :agent_attach_selection}},
          {"This selection", "x", "Cut selection", "d", "Removes the selected text", true,
           {:clipboard, :cut}}
        ]
      else
        []
      end

    replace(
      state,
      ActMenu.new(title, role, anchor, source, lead, selection ++ more ++ links ++ editing)
    )
  end

  @spec file_lead(boolean(), boolean(), Diagnostic.t() | nil, ActMenu.choice()) ::
          {Model.role(), [ActMenu.choice()], [ActMenu.choice()]}
  defp file_lead(true, _server, _diagnostic, ask),
    do:
      {:neutral, [{"This selection", "c", "Copy selection", "y", "", false, {:clipboard, :copy}}],
       [ask]}

  defp file_lead(false, true, diagnostic, ask) do
    case diagnostic do
      %Diagnostic{message: message, severity: severity} ->
        role = if severity == :error, do: :failure, else: :neutral
        detail = String.slice(message, 0, 160)

        {role,
         [{"This diagnostic", "f", "Fix", "SPC c a", detail, false, {:command, :code_action}}],
         [ask]}

      nil ->
        {:neutral,
         [{"This file", "f", "Code actions", "SPC c a", "", false, {:command, :code_action}}],
         [ask]}
    end
  end

  defp file_lead(false, false, _diagnostic, ask), do: {:neutral, [ask], []}

  @spec attach_file_diagnostics() :: ActMenu.choice()
  defp attach_file_diagnostics do
    {"This file", "d", "Attach file diagnostics to Agent draft", "SPC a x d", "", false,
     :attach_file_diagnostics}
  end

  @spec at_cursor_diagnostic(CursorContext.t()) :: Diagnostic.t() | nil
  defp at_cursor_diagnostic(%CursorContext{file_path: nil}), do: nil

  defp at_cursor_diagnostic(%CursorContext{file_path: path, line: line, line_text: text} = cursor) do
    point = CursorContext.position(cursor)

    path
    |> SyncServer.path_to_uri()
    |> Diagnostics.for_uri()
    |> Enum.find(fn diagnostic ->
      %{start_line: first, end_line: last} = diagnostic.range

      first <= line and last >= line and
        (first < line or Diagnostic.start_position(diagnostic, text) <= point) and
        (last > line or Diagnostic.end_position(diagnostic, text) >= point)
    end)
  end

  @spec source_current?(State.t(), ActMenu.source()) :: boolean()
  defp source_current?(state, {:review, file, _target, _count, :notice}),
    do: file_current?(state, file)

  defp source_current?(state, {:review, file, _target, _count, {:visual, visual, _cursor}}),
    do: source_current?(state, {:selection, file, visual})

  defp source_current?(state, {:selection, {_, buffer, _, cursor} = file, visual}),
    do:
      file_current?(state, file) and state.workspace.editing.mode_state == visual and
        Buffer.cursor(buffer) == cursor

  defp source_current?(state, {:file, {_, buffer, _, cursor} = file}),
    do: file_current?(state, file) and Buffer.cursor(buffer) == cursor

  @spec file_current?(State.t(), ActMenu.file_source()) :: boolean()
  defp file_current?(state, {window, buffer, version, _cursor}) do
    case SessionState.active_window_struct(state.workspace) do
      %Window{id: ^window, content: {:buffer, ^buffer}} -> Buffer.version(buffer) == version
      _retargeted -> false
    end
  end

  @doc "Applies a confirmed rejection only if the exact selection still exists."
  @spec confirm_review_reject(State.t(), ActMenu.source()) :: State.t()
  def confirm_review_reject(
        state,
        {:review, {_, buffer, _, _}, target, count, continuation} = source
      ) do
    if source_current?(state, source) do
      InFileReview.decide_offer(state, buffer, target, :reject, count, continuation)
    else
      stale(state)
    end
  catch
    :exit, _gone -> stale(state)
  end

  @spec perform(State.t(), ActMenu.source(), ActMenu.action()) :: State.t()
  defp perform(
         state,
         {:review, _file, _target, count, {:visual, _, _}} = source,
         {:review, :reject}
       )
       when count > 1 do
    PromptUI.open(state, RejectReviewSelection,
      kind: :confirm,
      label: "Reject #{count} Minga changes? Your edits stay.",
      context: %{review: source}
    )
  end

  defp perform(
         state,
         {:review, {_, buffer, _, _}, target, count, continuation},
         {:review, decision}
       )
       when decision in [:keep, :reject],
       do: InFileReview.decide_offer(state, buffer, target, decision, count, continuation)

  defp perform(state, {:review, file, target, _, _}, {:review, :preview}),
    do: ActMenuReviewDiff.open(state, file, target)

  defp perform(state, {:review, {_, buffer, _, {line, column}}, _, _, _}, {:review, :copy_link}) do
    case Buffer.file_path(buffer) do
      path when is_binary(path) ->
        Minga.Clipboard.write_async("#{path}:#{line + 1}:#{column + 1}")
        NoticeWorkflow.publish(state, "Copied file:line link")

      nil ->
        stale(state)
    end
  end

  defp perform(state, {:review, file, _, _, continuation}, {:review, action}) do
    case review_position(file, continuation) do
      :ok ->
        case action do
          :ask -> MingaEditor.dispatch_command(state, :inline_ask)
          :rewrite -> MingaEditor.dispatch_command(state, :inline_edit)
          {:conversation, task} -> AgentCommands.open_session(state, task)
        end

      :stale ->
        stale(state)
    end
  end

  defp perform(state, {:review, {_, buffer, _, _}, _, _, _}, :attach_file_diagnostics),
    do: DiagnosticAttachmentSource.open_buffer(state, buffer)

  defp perform(state, {:selection, {_, buffer, _, _}, _}, :attach_file_diagnostics),
    do: DiagnosticAttachmentSource.open_buffer(state, buffer)

  defp perform(state, {:file, {_, buffer, _, _}}, :attach_file_diagnostics),
    do: DiagnosticAttachmentSource.open_buffer(state, buffer)

  defp perform(state, _source, {:command, command}),
    do: MingaEditor.dispatch_command(state, command)

  defp perform(state, _source, {:clipboard, :cut}), do: Editing.execute(state, :cmd_cut)
  defp perform(state, _source, {:clipboard, :copy}), do: Editing.execute(state, :cmd_copy)

  defp perform(state, _source, {:clipboard, :paste}) do
    case Minga.Clipboard.read() do
      text when is_binary(text) and text != "" -> Router.route_paste(state, text)
      _ -> NoticeWorkflow.publish(state, "The clipboard has no text")
    end
  end

  @spec review_position(ActMenu.file_source(), PendingKeep.continuation()) :: :ok | :stale
  defp review_position(_file, {:visual, _, _}), do: :ok

  defp review_position({_, buffer, version, position}, _continuation) do
    case BufferProcess.move_to_if_version(buffer, version, position) do
      {:ok, _position} -> :ok
      {:error, _stale} -> :stale
    end
  end

  @spec stale(State.t()) :: State.t()
  defp stale(state),
    do: NoticeWorkflow.publish(state, "The target changed. Open the act menu again.")
end
