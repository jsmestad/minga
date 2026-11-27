defmodule Minga.Test.Storyboard.Session do
  @moduledoc """
  Drives one headless editor through the BEAM for the storyboard factory.

  A session wraps `Minga.Test.EditorCase.start_editor/2` with a project in a private temporary directory, so every scenario starts from the same cold start: `minga .` in a project with no saved session, which lands on the project home with the project's one Elixir file as recent file 1. `press/2` takes the key notation from `docs/design/scenarios.toml` (see `Minga.Test.Storyboard.Keys`), `click/2` sends a semantic click, and `model/1` returns the committed semantic frame as a `Minga.Test.Storyboard.Model`.

  Call `start/1` from an ExUnit test process: the editor is started with `start_supervised`, so it stops with the test. Rendering is disabled by default because the model is built from editor state with the same builder the render pipeline uses; pass `rendering: :enabled` when a caller also needs rendered frames (#4036).
  """

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias Minga.Test.EditorCase
  alias Minga.Test.Storyboard.Keys
  alias Minga.Test.Storyboard.Model
  alias MingaEditor.Agent.{Activity, UIState}
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.MinibufferData
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.RenderModel.UI.Builder, as: UIBuilder
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.StatusBar.Data, as: StatusBarData

  @default_content """
  defmodule Storyboard do
    @moduledoc "A small file every storyboard scenario starts in."

    def greet(name) do
      "Hello, " <> name
    end
  end
  """

  @type t :: %__MODULE__{
          ctx: EditorCase.editor_ctx(),
          child_id: reference(),
          children: [term()],
          root: Path.t(),
          file: Path.t(),
          peek_parent:
            {GenServer.server(), MingaAgent.SessionManager.foreground_identity()} | nil,
          home_window: pos_integer(),
          parser: GenServer.server(),
          path: [String.t()]
        }

  @enforce_keys [:ctx, :root, :file, :home_window, :child_id]
  defstruct [
    :ctx,
    :root,
    :file,
    :home_window,
    :child_id,
    :parser,
    :peek_parent,
    children: [],
    path: []
  ]

  @typedoc "A semantic click: a mouse press at a cell, or a GUI action the frontend would send."
  @type click ::
          {:mouse, non_neg_integer(), non_neg_integer()}
          | {:gui_action, term()}
          | {:subagent_started, String.t()}
          | {:tasks_row, String.t(), String.t()}

  @doc """
  Starts a headless editor at the factory's cold start.

  Options: `:content` (the file's text), `:file_name` (relative to the project root, default `lib/storyboard.ex`), `:width` and `:height` (default 120 by 36), and `:rendering` (`:disabled` by default).

  `:place` says where `minga` was started: `:project` (default, the project home), `:folder` (a directory without project markers) or `:outside` (no project; the home lists the project as a recent project). `:restored` (default false) gives the project a saved session that shows the file in a vertical split, so the start is `minga .` picking up where you left off.

  Every session runs the real tree-sitter parser, and `settle/1` returns only once an open file's highlights are applied, so parser-dependent keys (structural motions, text objects, folds) behave as in the app and every frame is highlighted. The parser is the suite's shared one (`shared_parser/0`) unless `:parser_manager` names another running `Minga.Parser.Manager`.

  `:minga` puts Minga in an Agent status before the first key, for example `:thinking` for "Minga is working". Use `{:thinking, :in_file}` to make the fixture file the task's last edited file. The status goes into the editor's live presentation cache, so every surface reads the same value.

  `:conversation` starts a real Agent session before the first key. It takes `messages:`, `notices:`, `prompt:`, `turn:` (`:idle`, `:working` or `:stopped`), and `queue:` (follow-up messages queued while Minga works). Its provider never finishes a turn. By default the fixture returns to the file before the first key, so `SPC a v` opens the seeded conversation. Set `open?: true` when the scenario begins inside that conversation.

  `:review_edits` opens the fixture file and applies attributed edits before the keys or clicks that lead to a review scenario.

  The storyboard renderer (#4036) adds four more: `:root` (a fixed project directory, so the path the chrome shows is the same on every machine; the caller keeps it unique among concurrent sessions in one run, and the directory is written atomically and never deleted, so concurrent runs on one machine can share it), `:theme` (a built-in theme name such as `:astrodark`, set on a private options server before the editor starts), `:capabilities` (the `MingaEditor.Frontend.Capabilities` the frontend would report), and `:record_packets` (keep every packet for `packets/1`).
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    content = Keyword.get(opts, :content, @default_content)
    file_name = Keyword.get(opts, :file_name, "lib/storyboard.ex")
    root = make_project(Keyword.get(opts, :root), file_name, content)
    file = Path.join(root, file_name)
    Enum.each(Keyword.get(opts, :empty_dirs, []), &File.mkdir_p!(Path.join(root, &1)))

    child_id = make_ref()
    parser = Keyword.get_lazy(opts, :parser_manager, &shared_parser!/0)

    place = Keyword.get(opts, :place, :project)

    {conversation_opts, conversation_children} =
      conversation_editor_opts(Keyword.get(opts, :conversation), root)

    editor_opts =
      [
        child_id: child_id,
        empty: true,
        project_root: if(place == :outside, do: nil, else: root),
        home: home_opts(place, root, file_name),
        width: Keyword.get(opts, :width, 120),
        height: Keyword.get(opts, :height, 36),
        rendering: Keyword.get(opts, :rendering, :disabled),
        record_packets: Keyword.get(opts, :record_packets, false),
        parser_manager: parser
      ] ++
        restored_opts(Keyword.get(opts, :restored, false), root, file) ++
        conversation_opts

    {theme_opts, theme_children} = theme_opts(Keyword.get(opts, :theme))

    {project_opts, project_children} =
      project_opts(Keyword.get(opts, :directory_workspace, false), root)

    ctx =
      EditorCase.start_editor(
        content,
        editor_opts ++ Keyword.take(opts, [:capabilities]) ++ theme_opts ++ project_opts
      )

    relay = start_relay(ctx, parser)

    # Outside a project nothing restores at start; the saved session waits for the project to be opened.
    await_restore!(ctx, place != :outside and Keyword.get(opts, :restored, false))
    settle_highlights(ctx, parser)
    seed_tasks(ctx, Keyword.get(opts, :tasks, []))
    install_git_status(ctx, root, Keyword.get(opts, :git_status))
    peek_parent = start_conversation(ctx, parser, file, Keyword.get(opts, :conversation))

    session = %__MODULE__{
      ctx: ctx,
      root: root,
      file: file,
      home_window: 0,
      child_id: child_id,
      parser: parser,
      peek_parent: peek_parent,
      children: [relay | theme_children ++ project_children ++ conversation_children]
    }

    session = seed_review(session, Keyword.get(opts, :review_edits, []))
    install_minga_status(ctx, file, Keyword.get(opts, :minga))
    %{session | home_window: window_id(session)}
  end

  @typedoc "The `:conversation` start option."
  @type conversation :: [
          messages: [MingaAgent.Message.t()],
          notices: [{String.t(), :info | :warning | :error}],
          prompt: String.t(),
          turn: :idle | :working | :stopped,
          queue: [String.t()],
          draft: String.t(),
          peek?: boolean(),
          open?: boolean()
        ]

  @spec conversation_editor_opts(conversation() | nil, Path.t()) :: {keyword(), [term()]}
  defp conversation_editor_opts(nil, _root), do: {[], []}

  defp conversation_editor_opts(conversation, root) do
    if conversation[:peek?] do
      native_peek_fixture(root)
    else
      {[
         agent_provider_module: Minga.Test.SessionSlowMockProvider,
         agent_arrival_budget_ms: 4_000
       ], []}
    end
  end

  @spec native_peek_fixture(Path.t()) :: {keyword(), [term()]}
  defp native_peek_fixture(root) do
    # The real Native route waits for the packaged catalog even with a fixture resolver. Complete that prerequisite before timing the conversation's startup.
    {:ok, :ready} = MingaAgent.ModelCatalog.load()

    provider = Minga.Test.Storyboard.SubagentPeekProvider
    :ok = provider.prepare_files(root)
    suffix = System.unique_integer([:positive])
    sessions_id = make_ref()
    manager_id = make_ref()

    sessions =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {DynamicSupervisor,
           name: :"storyboard_peek_sessions_#{suffix}", strategy: :one_for_one},
          id: sessions_id
        )
      )

    manager =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {MingaAgent.SessionManager,
           name: :"storyboard_peek_manager_#{suffix}",
           session_supervisor: sessions,
           foreground_provider_opts: provider.opts()},
          id: manager_id
        )
      )

    {
      [
        agent_provider_module: MingaAgent.Providers.Native,
        agent_provider_opts: provider.opts(),
        agent_session_manager: manager,
        agent_arrival_budget_ms: 4_000
      ],
      [manager_id, sessions_id]
    }
  end

  # Opens the conversation once to start its session, fills it through the
  # Session API, then closes it so the scenario's own keys open it again.
  @spec start_conversation(
          EditorCase.editor_ctx(),
          GenServer.server() | nil,
          Path.t(),
          conversation() | nil
        ) :: {GenServer.server(), MingaAgent.SessionManager.foreground_identity()} | nil
  defp start_conversation(_ctx, _parser, _file, nil), do: nil

  defp start_conversation(ctx, parser, file, conversation) do
    conversation =
      Keyword.validate!(conversation,
        messages: [],
        notices: [],
        prompt: nil,
        turn: :idle,
        queue: [],
        draft: "",
        peek?: false,
        open?: false
      )

    EditorCase.send_keys_sync(ctx, "1")

    EditorCase.wait_until(
      ctx,
      fn state ->
        case state.workspace.buffers.active do
          buffer when is_pid(buffer) -> Minga.Buffer.file_path(buffer) == file
          nil -> false
        end
      end,
      message: "expected home shortcut 1 to open the conversation fixture file #{file}"
    )

    await_highlights!(ctx, parser)
    EditorCase.send_keys_sync(ctx, "<SPC>av")
    session = await_conversation_session!(ctx)

    if conversation[:messages] != [] do
      :ok = MingaAgent.Session.seed_messages(session, conversation[:messages])
      await_transcript!(ctx, session)
    end

    # Notices follow the seeded messages, the way Minga adds them to a conversation.
    for {text, level} <- conversation[:notices],
        do: MingaAgent.Session.add_system_message(session, text, level)

    peek_parent =
      if conversation[:peek?] do
        run_peek_turn(ctx, session, conversation)
      else
        run_turn(ctx, session, conversation)
        nil
      end

    await_transcript!(ctx, session)

    if conversation[:open?] do
      await_queue_contents!(ctx, conversation[:queue])
      if conversation[:draft] != "", do: EditorCase.send_keys_sync(ctx, conversation[:draft])
    else
      EditorCase.send_keys_sync(ctx, "<Esc><Esc><SPC>av")

      EditorCase.wait_until(ctx, &(not &1.workspace.agent_ui.panel.visible),
        max_attempts: 500,
        message: "expected the storyboard conversation's split to close before the first key"
      )
    end

    peek_parent
  end

  @spec await_queue_contents!(EditorCase.editor_ctx(), [String.t()]) :: :ok
  defp await_queue_contents!(ctx, expected) do
    EditorCase.wait_until(
      ctx,
      fn state ->
        case state.workspace.agent_ui.queue.contents do
          %{pending: pending} -> Enum.map(pending, & &1.preview) == expected
          _loading -> false
        end
      end,
      max_attempts: 500,
      message: "expected the open conversation to display its seeded queue"
    )

    :ok
  end

  @spec project_opts(boolean(), Path.t()) :: {keyword(), [term()]}
  defp project_opts(false, _root), do: {[], []}

  defp project_opts(true, root) do
    id = make_ref()
    name = :"storyboard_project_#{System.unique_integer([:positive])}"

    project =
      ExUnit.Callbacks.start_supervised!(
        {Minga.Project,
         name: name,
         subscribe: false,
         command_frecency: %{},
         startup_directory: root,
         file_find_module: Minga.Project.SlowFileFind},
        id: id
      )

    {[project_server: project], [id]}
  end

  @doc """
  Waits until an open file's highlights are applied, after a key path opened one (`1` on the home).

  Returns at once when no file is open. `Minga.Test.Storyboard.Registry.drive/2` calls it after every reach.
  """
  @spec settle(t()) :: t()
  def settle(%__MODULE__{ctx: ctx, parser: parser} = session) do
    settle_highlights(ctx, parser)
    session
  end

  @doc "Opens the project's file from the home with `1`, the way `edit.plain` is reached, and waits for its highlights."
  @spec open_file(t()) :: t()
  def open_file(%__MODULE__{} = session), do: session |> press("1") |> settle()

  @spec seed_review(
          t(),
          [{Minga.Buffer.Document.position(), non_neg_integer(), binary(), EditSource.t()}]
        ) :: t()
  defp seed_review(session, []), do: session

  defp seed_review(session, edits) do
    session = open_file(session)
    buffer = EditorCase.active_buffer(session.ctx)

    Enum.each(edits, fn {position, length, text, source} ->
      {:ok, _version} =
        BufferProcess.replace_byte_range_if_version(
          buffer,
          Buffer.version(buffer),
          position,
          length,
          text,
          source
        )
    end)

    settle(session)
  end

  # The project home's reads are fixed so every machine shows the same home: the project's one file is recent file 1.
  @spec home_opts(:project | :folder | :outside, Path.t(), String.t()) :: keyword()
  defp home_opts(:project, _root, file_name),
    do: [place: :project, recents: [file_name], git: nil, projects: []]

  defp home_opts(:folder, _root, _file_name),
    do: [place: :folder, recents: [], git: nil, projects: []]

  defp home_opts(:outside, root, _file_name),
    do: [place: :outside, recents: [], git: nil, projects: [root]]

  # A saved session for the project: the file in a vertical split with its cursor on `greet`.
  @spec restored_opts(boolean(), Path.t(), Path.t()) :: keyword()
  defp restored_opts(false, _root, _file), do: []

  defp restored_opts(true, root, file) do
    sessions = Path.join(root, ".storyboard-sessions-#{System.unique_integer([:positive])}")
    pane = %Minga.Session.Pane{file: file, cursor_line: 3, cursor_col: 2}

    snapshot = %Minga.Session.Snapshot{
      version: Minga.Session.Snapshot.current_version(),
      project_root: root,
      buffers: [%Minga.Session.BufferEntry{file: file, cursor_line: 3, cursor_col: 2}],
      active_file: file,
      layout: {:split, :vertical, {:pane, pane}, {:pane, %{pane | cursor_line: 0}}, 0},
      active_pane: 0
    }

    :ok = Minga.Session.save(snapshot, session_dir: sessions, project_root: root)
    [session_dir: sessions]
  end

  @spec await_restore!(EditorCase.editor_ctx(), boolean()) :: :ok
  defp await_restore!(_ctx, false), do: :ok

  defp await_restore!(ctx, true) do
    EditorCase.wait_until(ctx, &match?([_ | _], &1.workspace.buffers.list),
      max_attempts: 200,
      message: "the storyboard session was not restored"
    )

    :ok
  end

  # The Editor names the task and fills its transcript when it hears the Session's
  # messages changed; wait for that, so every theme's frame starts from the same state.
  @spec await_transcript!(EditorCase.editor_ctx(), pid()) :: map()
  defp await_transcript!(ctx, session) do
    expected = length(MingaAgent.Session.messages(session))

    EditorCase.wait_until(
      ctx,
      fn state ->
        MingaEditor.Agent.UIState.TranscriptProjection.source_count(
          state.workspace.agent_ui.panel.transcript
        ) == expected
      end,
      max_attempts: 500,
      message: "expected the Editor to hold the storyboard conversation's transcript"
    )
  end

  # The local inference route leaves the other three children working. Observe the real handback before checking its editor projection, so a slow reader does not spend the UI wait budget on provider work.
  @spec run_peek_turn(EditorCase.editor_ctx(), pid(), conversation()) ::
          {GenServer.server(), MingaAgent.SessionManager.foreground_identity()}
  defp run_peek_turn(ctx, parent, conversation) do
    :ok = MingaAgent.Session.subscribe(parent)

    try do
      run_turn(ctx, parent, conversation)
      key = await_peek_report!(parent)
      await_peek_fanout!(ctx, parent, key)
    after
      :ok = MingaAgent.Session.unsubscribe(parent)
    end
  end

  @spec await_peek_report!(pid()) :: MingaAgent.Tool.Invocation.key()
  defp await_peek_report!(parent) do
    receive do
      {:agent_event, ^parent,
       {:tool_ended,
        %MingaAgent.Event.ToolEnd{name: "subagent", outcome: :complete, invocation_key: key}}}
      when key != nil ->
        key

      {:agent_event, ^parent, {:tool_ended, %MingaAgent.Event.ToolEnd{name: "subagent"} = event}} ->
        raise ExUnit.AssertionError, message: "Fixture subagent failed: #{inspect(event)}"
    after
      15_000 ->
        raise ExUnit.AssertionError,
          message: "No subagent reported: #{inspect(MingaAgent.Session.messages(parent))}"
    end
  end

  @spec await_peek_fanout!(EditorCase.editor_ctx(), pid(), MingaAgent.Tool.Invocation.key()) ::
          {GenServer.server(), MingaAgent.SessionManager.foreground_identity()}
  defp await_peek_fanout!(ctx, parent, key) do
    id = MingaAgent.Session.session_id(parent)
    token = MingaEditor.Agent.Tasks.Subagent.action_token({id, key})
    manager = EditorCase.editor_state(ctx).agent_connection.session_manager

    ExUnit.Callbacks.on_exit({__MODULE__, id}, fn ->
      if Process.alive?(manager), do: MingaAgent.SessionManager.stop_session(manager, id)
    end)

    EditorCase.wait_until(
      ctx,
      fn state ->
        case MingaEditor.RenderModel.UI.SubagentPeekBuilder.capture(state) do
          {%{steps: [{_entry, ^token, _, "1 of 4 reports in"}, _, _, _]}, nil} ->
            true

          _not_ready ->
            false
        end
      end,
      max_attempts: 500,
      message: "expected the fixture's four Started rows and the exact committed first report"
    )

    {manager, {id, key}}
  rescue
    error in ExUnit.AssertionError ->
      snapshot = MingaAgent.Session.editor_snapshot(parent)
      messages = MingaAgent.Session.messages(parent)
      state = EditorCase.editor_state(ctx)
      projection = MingaEditor.RenderModel.UI.SubagentPeekBuilder.capture(state)

      reraise %{
                error
                | message:
                    "#{error.message}\nParent status: #{inspect(snapshot.status)}\n" <>
                      "Peek offers: #{inspect(projection)}\nLast messages: #{inspect(Enum.take(messages, -8))}"
              },
              __STACKTRACE__
  end

  @spec run_turn(EditorCase.editor_ctx(), pid(), conversation()) :: :ok
  defp run_turn(ctx, session, conversation) do
    case conversation[:turn] do
      :idle ->
        :ok

      turn when turn in [:working, :stopped] ->
        :ok = MingaAgent.Session.send_prompt(session, conversation[:prompt] || "Keep going")
        await_working!(ctx)

        for text <- conversation[:queue] do
          {:queued, :follow_up} = MingaAgent.Session.queue_follow_up(session, text)
        end

        if turn == :stopped, do: stop_turn!(ctx, session)
        :ok
    end
  end

  @spec stop_turn!(EditorCase.editor_ctx(), pid()) :: :ok
  defp stop_turn!(ctx, session) do
    %{stop_target: {_, _} = target} = MingaAgent.Session.editor_snapshot(session)
    :ok = MingaAgent.Session.stop_turn(session, target)

    EditorCase.wait_until(ctx, &(agent_status(&1) == :stopped),
      max_attempts: 500,
      message: "expected the storyboard conversation to stop"
    )

    :ok
  end

  @spec await_working!(EditorCase.editor_ctx()) :: map()
  defp await_working!(ctx) do
    EditorCase.wait_until(ctx, &(agent_status(&1) in [:thinking, :tool_executing]),
      max_attempts: 500,
      message: "expected the storyboard conversation to be working"
    )
  end

  @spec await_conversation_session!(EditorCase.editor_ctx()) :: pid()
  defp await_conversation_session!(ctx) do
    state =
      EditorCase.wait_until(
        ctx,
        fn state ->
          session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

          is_pid(session) and
            match?(
              %{connection: %{provider_phase: :running, target: %{session: ^session}}},
              state.workspace.agent_ui
            )
        end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected SPC a v to start the storyboard conversation's session"
      )

    MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
  end

  @spec agent_status(map()) :: atom()
  defp agent_status(state),
    do: MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state).runtime.status

  @spec install_minga_status(
          EditorCase.editor_ctx(),
          String.t(),
          Minga.Design.Tokens.agent_status()
          | {Minga.Design.Tokens.agent_status(), :in_file}
          | nil
        ) :: :ok
  defp install_minga_status(_ctx, _file, nil), do: :ok

  defp install_minga_status(%{editor: editor}, file, {status, :in_file}) do
    identity = Buffer.file_identity(file)

    :sys.replace_state(editor, fn state ->
      ui = state.workspace.agent_ui
      author = Activity.task_author(UIState.task_id(ui))
      activity = Activity.record_file(ui.view.activity, author, file, identity)

      state
      |> Workflow.install_agent_ui(UIState.replace_activity(ui, activity))
      |> Workflow.install_agent_status(status)
    end)

    :ok
  end

  defp install_minga_status(%{editor: editor}, _file, status) do
    :sys.replace_state(editor, &Workflow.install_agent_status(&1, status))
    :ok
  end

  # Git Status comes from an extension (GitExtended), so a scenario installs the core panel with the repository facts it needs.
  @spec install_git_status(EditorCase.editor_ctx(), Path.t(), map() | nil) :: :ok
  defp install_git_status(_ctx, _root, nil), do: :ok

  defp install_git_status(%{editor: editor}, root, facts) do
    panel =
      MingaEditor.GitStatus.Panel.new(Map.merge(%{git_root: root, entry_base_path: root}, facts))

    :sys.replace_state(editor, fn state ->
      state
      |> SidebarWorkflow.replace_git_status(panel)
      |> SidebarWorkflow.handle_git_status_action("activate", :builtin)
      |> MingaEditor.Renderer.render()
    end)

    :ok
  end

  # Fake agent sessions for scenarios that show Minga's tasks (`Minga.Test.FakeTaskSession`), oldest first.
  @spec seed_tasks(EditorCase.editor_ctx(), [{String.t(), Minga.Test.FakeTaskSession.seed()}]) ::
          :ok
  defp seed_tasks(_ctx, []), do: :ok

  defp seed_tasks(ctx, tasks) do
    Enum.each(tasks, fn {title, seed} ->
      Minga.Test.FakeTaskSession.start(ctx.editor, title, seed)
    end)

    _ = EditorCase.editor_state(ctx)
    :ok
  end

  @doc "Presses a key path in inventory notation, or already parsed key steps. Raises if the editor dies."
  @spec press(t(), String.t() | [Keys.step()]) :: t()
  def press(%__MODULE__{} = session, notation) when is_binary(notation) do
    session
    |> press(Keys.parse!(notation))
    |> record(notation)
  end

  def press(%__MODULE__{ctx: ctx} = session, steps) when is_list(steps) do
    Enum.each(steps, &step(ctx, &1))
    await_picker_fetch!(ctx)
    await_queue_edit!(ctx)
    await_peek_reader!(ctx)
    await_keep!(ctx)
    session
  end

  @spec await_keep!(EditorCase.editor_ctx()) :: map()
  defp await_keep!(ctx) do
    EditorCase.wait_until(ctx, &is_nil(&1.interaction.keep_requests),
      max_attempts: 500,
      message: "expected the in-file Keep decision to settle"
    )
  end

  @spec await_queue_edit!(EditorCase.editor_ctx()) :: :ok
  defp await_queue_edit!(ctx) do
    case EditorCase.editor_state(ctx).workspace.agent_ui.queue.edit_request do
      ref when is_reference(ref) ->
        EditorCase.wait_until(ctx, &(&1.workspace.agent_ui.queue.edit_request != ref),
          max_attempts: 500,
          message: "expected the queue's Enter action to settle"
        )

      nil ->
        :ok
    end

    :ok
  end

  @spec await_peek_reader!(EditorCase.editor_ctx()) :: map()
  defp await_peek_reader!(ctx) do
    EditorCase.wait_until(
      ctx,
      fn state ->
        case state.agent_connection.peek_session do
          %{link: {:connecting, _, _}} -> false
          %{read: {_request, _dirty}} -> false
          _settled -> true
        end
      end,
      max_attempts: 500,
      message: "expected the selected child reader to settle"
    )
  end

  @doc "Sends one semantic click and waits until the editor has handled it."
  @spec click(t(), click()) :: t()
  def click(%__MODULE__{ctx: %{editor: editor} = ctx} = session, {:mouse, row, col}) do
    send(editor, {:minga_input, {:mouse_event, row, col, :left, 0, :press, 1}})
    send(editor, {:minga_input, {:mouse_event, row, col, :left, 0, :release, 1}})
    _ = EditorCase.editor_state(ctx)
    record(session, "click #{row},#{col}")
  end

  def click(%__MODULE__{ctx: %{editor: editor} = ctx} = session, {:gui_action, action}) do
    send(editor, {:minga_input, {:gui_action, action}})
    _ = EditorCase.editor_state(ctx)
    record(session, "click #{inspect(action)}")
  end

  def click(%__MODULE__{} = session, {:tasks_row, title, action}) do
    %{ui: %{tasks_drawer: %{visible?: true, rows: rows}}} = model(session)
    row = Enum.find(rows, &(&1.title == title))

    unless row && (action == "select" || List.keymember?(row.actions, action, 0)) do
      raise ExUnit.AssertionError, message: "No displayed #{inspect(action)} action on #{title}"
    end

    click(session, {:gui_action, {:tasks_drawer_action, row.id, action}})
  end

  def click(%__MODULE__{} = session, {:subagent_started, label}) do
    %{ui: %{subagent_peek: %{parent_window_id: parent, steps: steps}}} = model(session)
    {_, target, ^label, _report} = Enum.find(steps, fn {_, _, text, _} -> text == label end)

    session
    |> click({:gui_action, {:subagent_peek_action, :started, parent, "", target, {0, 0}}})
    |> then(fn session ->
      await_peek_reader!(session.ctx)
      session
    end)
  end

  @doc """
  Delivers an interruption while you are somewhere else: a warning arrives in the editor's log, the way a failing background job reports one.

  The event goes through this session's private events registry, never the global bus.
  """
  @spec interrupt(t(), String.t()) :: t()
  def interrupt(%__MODULE__{ctx: ctx} = session, text) do
    event = %Minga.Events.LogMessageEvent{text: text, level: :warning}
    :ok = Minga.Events.broadcast(:log_message, event, ctx.events_registry)
    _ = EditorCase.editor_state(ctx)
    record(session, "interrupt #{inspect(text)}")
  end

  @doc """
  Returns every packet the editor has sent to its frontend so far, oldest first.

  Requires `record_packets: true` and `rendering: :enabled`. Replaying the packets in order through a frontend's production decoder rebuilds the frame the session shows now.
  """
  @spec packets(t()) :: [binary()]
  def packets(%__MODULE__{ctx: ctx}) do
    _ = EditorCase.editor_state(ctx)
    Minga.Test.HeadlessPort.packets(ctx.port)
  end

  @doc "The text grid the headless frontend shows now, one string per row. Requires `rendering: :enabled`."
  @spec screen_text(t()) :: [String.t()]
  def screen_text(%__MODULE__{ctx: ctx}) do
    await_rendered!(ctx)
    Minga.Test.HeadlessPort.get_screen_text(ctx.port)
  end

  @doc "True when the focused window shows a file, not the project home."
  @spec file_open?(t()) :: boolean()
  def file_open?(%__MODULE__{ctx: ctx}) do
    state = EditorCase.editor_state(ctx)

    match?(
      %{content: {:buffer, _}},
      MingaEditor.Session.State.active_window_struct(state.workspace)
    )
  end

  @doc "Waits for the headless frontend to show the frame the capture will measure."
  @spec await_frame(t()) :: t()
  def await_frame(%__MODULE__{ctx: ctx} = session) do
    await_rendered!(ctx)
    session
  end

  # A key schedules its render on a short timer, so the grid can lag the editor.
  # A conversation that is still arriving holds its frame back, so nothing is
  # scheduled yet while the grid still shows the tab the user left. Wait until no
  # frame is held or scheduled and the frontend has acknowledged the latest one.
  @spec await_rendered!(EditorCase.editor_ctx()) :: map()
  defp await_rendered!(ctx) do
    alias MingaEditor.State.RenderCorrelation

    EditorCase.wait_until(
      ctx,
      fn %{render: %{render_correlation: correlation}} = state ->
        not MingaEditor.Agent.Arrival.defer_frame?(state) and
          not RenderCorrelation.scheduled?(correlation) and
          RenderCorrelation.last_receipt_revision(correlation) ==
            RenderCorrelation.latest_intent_revision(correlation)
      end,
      max_attempts: 500,
      message: "expected the headless frontend to show the editor's latest frame"
    )
  end

  @doc """
  The most tree-sitter highlight spans any open buffer carries now. Zero without a parser.

  It reads every buffer, not only the active one, so a scenario whose focus is elsewhere (the composer, a picker) still proves the file beside it shows real colours.
  """
  @spec highlight_span_count(t()) :: non_neg_integer()
  def highlight_span_count(%__MODULE__{ctx: ctx}) do
    state = EditorCase.editor_state(ctx)

    state.parser.highlighting.highlights
    |> Map.values()
    |> Enum.map(&tuple_size(&1.spans))
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  The terminal header height for a conversation or a remaining Agent workspace, or nil for scenes that use measured grid fixtures.

  This mirrors `headerChrome` in `go/tui/internal/ui/render_chrome.go`: the workspace bar when there is more than one workspace, tabs, and the breadcrumb from `breadcrumb_min_cols` columns up when it has segments.
  """
  @spec conversation_header_rows(t(), pos_integer(), pos_integer()) :: pos_integer() | nil
  def conversation_header_rows(%__MODULE__{ctx: ctx}, cols, breadcrumb_min_cols) do
    ui = ctx |> EditorCase.editor_state() |> semantic_ui()

    workspaces = ui.workspaces.workspaces

    if match?(%{visible?: true}, ui.agent_chat) or Enum.any?(workspaces, &(&1.kind == :agent)) do
      rows =
        Enum.count(
          [
            match?([_, _ | _], workspaces),
            match?(%{tabs: [_ | _]}, ui.tab_bar),
            cols >= breadcrumb_min_cols and match?(%{segments: [_ | _]}, ui.breadcrumb)
          ],
          & &1
        )

      max(rows, 1)
    end
  end

  @doc "Reports a new grid size, the way a frontend does when its row fit or its header changes, and waits for the frame laid out for it."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{ctx: ctx} = session, cols, rows) do
    ctx = EditorCase.send_resize(ctx, cols, rows)
    await_rendered!(ctx)
    %{session | ctx: ctx}
  end

  @doc """
  Installs the macOS composer's reported fit and waits for the frame laid out for it.

  The storyboard has no retained frontend prompt presentation, so it installs the fit through the panel owner, as `MingaEditor.Agent.PromptInput.fit/5` does after admitting a live frontend's report.
  """
  @spec fit_prompt(t(), pos_integer(), pos_integer()) :: t()
  def fit_prompt(%__MODULE__{ctx: %{editor: editor} = ctx} = session, cols, rows) do
    :sys.replace_state(editor, fn state ->
      agent_ui = state.workspace.agent_ui
      panel = MingaEditor.Agent.UIState.Panel.fit_prompt(agent_ui.panel, cols, rows)

      state
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        MingaEditor.Agent.UIState.replace_panel(agent_ui, panel)
      )
      |> MingaEditor.Renderer.render()
    end)

    await_rendered!(ctx)

    case EditorCase.editor_state(ctx).workspace.agent_ui.panel.prompt_viewport.fit do
      {^cols, ^rows} ->
        session

      other ->
        raise "the editor did not keep the composer fit #{cols}x#{rows}; it holds #{inspect(other)}"
    end
  end

  @doc "Returns the semantic frame the editor would commit now."
  @spec model(t()) :: Model.t()
  def model(%__MODULE__{ctx: ctx}) do
    state = EditorCase.editor_state(ctx)
    ui = semantic_ui(state)

    ui |> with_resident_transcript(state) |> Model.from_ui(state.appearance.theme)
  end

  @spec semantic_ui(map()) :: Minga.RenderModel.UI.t()
  defp semantic_ui(state) do
    status_bar = StatusBarData.from_state(state)
    minibuffer = MinibufferData.from_state(state)

    {ui, _context} =
      state |> Context.from_editor_state() |> UIBuilder.build_ui(status_bar, minibuffer)

    ui
  end

  # The conversation's resident transcript belongs to the renderer, so a model
  # built from editor state alone has no messages. Admit a fresh seed the way a
  # new renderer would, so checks see the transcript the frontends draw.
  @spec with_resident_transcript(Minga.RenderModel.UI.t(), map()) :: Minga.RenderModel.UI.t()
  defp with_resident_transcript(%{agent_chat: %{visible?: true}} = ui, state),
    do: %{ui | agent_chat: Minga.Test.AgentWorkflowDriver.chat_model(state)}

  defp with_resident_transcript(ui, _state), do: ui

  @doc """
  Stops the session's editor, buffer and headless port before the test ends.

  Callers that start many sessions in one test (the flow explorer, the key walk) stop each one when done, so idle editors do not pile up. Safe to call on a session whose editor already died.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{ctx: ctx, child_id: child_id, children: children, peek_parent: peek}) do
    stop_peek_fixture(peek)

    # The editor opened its files itself, under the global buffer supervisor; they go with the session, so the next
    # session on the same project directory opens fresh buffers.
    opened = opened_buffers(ctx)
    _ = ExUnit.Callbacks.stop_supervised(child_id)
    Enum.each(opened, &unlink_and_stop/1)
    Enum.each(children, &ExUnit.Callbacks.stop_supervised/1)

    for pid <- [ctx.buffer, ctx.port], is_pid(pid), Process.alive?(pid) do
      unlink_and_stop(pid)
    end

    :ok
  end

  @spec stop_peek_fixture(
          {GenServer.server(), MingaAgent.SessionManager.foreground_identity()}
          | nil
        ) :: :ok
  defp stop_peek_fixture(nil), do: :ok

  defp stop_peek_fixture({manager, {parent, _key} = identity}) do
    :ok = Minga.Events.subscribe(:foreground_subagent_disposed)

    try do
      case MingaAgent.SessionManager.stop_session(manager, parent) do
        :ok ->
          receive do
            {:minga_event, :foreground_subagent_disposed, %{identity: ^identity}} -> :ok
          after
            5_000 -> raise "the storyboard fixture's managed child was not disposed"
          end

        {:error, :not_found} ->
          :ok
      end
    after
      Minga.Events.unsubscribe(:foreground_subagent_disposed)
    end
  end

  @doc "True while the editor process is alive."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{ctx: %{editor: editor}}), do: Process.alive?(editor)

  @doc "The key path pressed so far, in inventory notation."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{path: path}), do: path |> Enum.reverse() |> Enum.join(" · ")

  @doc "The id of the window that has focus now."
  @spec window_id(t()) :: pos_integer()
  def window_id(%__MODULE__{ctx: ctx}), do: EditorCase.active_window_id(ctx)

  @spec step(EditorCase.editor_ctx(), Keys.step()) :: :ok
  defp step(ctx, {:key, codepoint, mods}) do
    _ = EditorCase.send_key_sync(ctx, codepoint, mods)
    :ok
  end

  defp step(%{editor: editor} = ctx, :pause) do
    # The test config never fires the which-key timer, so a pause delivers the reveal the timer would send.
    generation = EditorCase.editor_state(ctx).shell_runtime.state.whichkey.generation
    send(editor, {:whichkey_reveal, generation})
    _ = EditorCase.editor_state(ctx)
    :ok
  end

  @spec opened_buffers(EditorCase.editor_ctx()) :: [pid()]
  defp opened_buffers(%{editor: editor} = ctx) do
    if Process.alive?(editor),
      do: MingaEditor.Handlers.BufferRegistry.buffer_inventory(EditorCase.editor_state(ctx)),
      else: []
  catch
    :exit, _reason -> []
  end

  @spec unlink_and_stop(pid()) :: :ok
  defp unlink_and_stop(pid) do
    Process.unlink(pid)
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @spec record(t(), String.t()) :: t()
  defp record(%__MODULE__{path: path} = session, label), do: %{session | path: [label | path]}

  @shared_parser Minga.Test.Storyboard.Parser
  @highlight_deadline_ms 10_000
  @wake_ms 20

  @doc """
  The child spec of the parser every storyboard session shares.

  `test/test_helper.exs` starts it once, before any test runs, because it opens the native `minga-parser` Port and OS processes must not be spawned while async tests run. Sessions only register their buffers with it.
  """
  @spec shared_parser_child_spec() :: Supervisor.child_spec()
  def shared_parser_child_spec,
    do: Supervisor.child_spec({Minga.Parser.Manager, name: @shared_parser}, id: @shared_parser)

  @spec shared_parser!() :: GenServer.server()
  defp shared_parser! do
    case Process.whereis(@shared_parser) do
      nil ->
        raise "the storyboard parser is not running; test/test_helper.exs starts it with Session.shared_parser_child_spec/0"

      _pid ->
        @shared_parser
    end
  end

  # Awaits highlights only when a file is open; the home has none to wait for.
  @spec settle_highlights(EditorCase.editor_ctx(), GenServer.server()) :: :ok
  defp settle_highlights(ctx, parser) do
    if EditorCase.editor_state(ctx).workspace.buffers.active,
      do: await_highlights!(ctx, parser),
      else: :ok
  end

  # The parser answers asynchronously: the editor applies the spans, then schedules a render; fold ranges and conceals
  # follow, and parse_complete ends the parse. A session is ready when the newest parse is complete and, when it
  # renders, the frame that shows all of it has reached the headless frontend (#4314). Parser events wake the wait
  # early; the short timeout only re-checks a render that is still in flight.
  @spec await_highlights!(EditorCase.editor_ctx(), GenServer.server()) :: :ok
  defp await_highlights!(ctx, parser) do
    :ok = Minga.Parser.Manager.subscribe(parser)
    deadline = System.monotonic_time(:millisecond) + @highlight_deadline_ms
    wait_for_highlights!(ctx, deadline)
    flush_parser_events()
  end

  defp wait_for_highlights!(ctx, deadline) do
    state = EditorCase.editor_state(ctx)

    cond do
      highlights_settled?(state) and rendered?(ctx, state) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "the storyboard parser applied no highlights, or never completed the parse, within " <>
                "#{@highlight_deadline_ms} ms; is priv/minga-parser built and current (mix native.build.support)?"

      true ->
        receive do
          {:minga_highlight, _event} -> :ok
        after
          @wake_ms -> :ok
        end

        wait_for_highlights!(ctx, deadline)
    end
  end

  @spec rendered?(EditorCase.editor_ctx(), MingaEditor.State.t()) :: boolean()
  defp rendered?(%{rendering: :disabled}, _state), do: true

  defp rendered?(%{port: port}, state) do
    correlation = state.render.render_correlation

    settled =
      not RenderCorrelation.scheduled?(correlation) and
        RenderCorrelation.last_receipt_revision(correlation) >=
          RenderCorrelation.latest_intent_revision(correlation)

    # The receipt says the renderer handed the frame over; reading the port orders this after the port applied it.
    if settled, do: Minga.Test.HeadlessPort.get_screen(port)
    settled
  end

  @fetch_deadline_ms 10_000

  # An async picker (project search, find file) opens while it loads and fills in when its fetch lands.
  # A scenario that ends on one is the frame after the fetch, so pressing waits for it, and for the frame that shows it.
  @spec await_picker_fetch!(EditorCase.editor_ctx()) :: :ok
  defp await_picker_fetch!(ctx) do
    wait_for_fetch!(ctx, System.monotonic_time(:millisecond) + @fetch_deadline_ms)
  end

  defp wait_for_fetch!(ctx, deadline) do
    state = EditorCase.editor_state(ctx)

    cond do
      not picker_loading?(state) and not tree_loading?(state) and rendered?(ctx, state) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "the picker fetch or file tree load did not finish within #{@fetch_deadline_ms} ms"

      true ->
        receive do
        after
          @wake_ms -> wait_for_fetch!(ctx, deadline)
        end
    end
  end

  # A rerooted or opened file tree lists its folder off the Editor process.
  @spec tree_loading?(MingaEditor.State.t()) :: boolean()
  defp tree_loading?(state),
    do: MingaEditor.State.FileTree.status(state.workspace.file_tree) == :loading

  @spec picker_loading?(MingaEditor.State.t()) :: boolean()
  defp picker_loading?(state),
    do: match?({:picker, %{picker_ui: %{load_status: :loading}}}, state.shell_runtime.state.modal)

  @spec flush_parser_events() :: :ok
  defp flush_parser_events do
    receive do
      {:minga_highlight, _event} -> flush_parser_events()
    after
      0 -> :ok
    end
  end

  @spec highlights_settled?(MingaEditor.State.t()) :: boolean()
  defp highlights_settled?(state) do
    highlight = MingaEditor.HighlightSync.get_active_highlight(state)
    tuple_size(highlight.spans) > 0 and MingaEditor.UI.Highlight.parse_settled?(highlight)
  end

  # The relay is a supervised child of the test, stopped with the session.
  @spec start_relay(EditorCase.editor_ctx(), GenServer.server()) :: term()
  defp start_relay(ctx, parser) do
    id = {:storyboard_parser_relay, make_ref()}

    ExUnit.Callbacks.start_supervised!(
      {Minga.Test.Storyboard.ParserRelay, registry: ctx.events_registry, parser: parser},
      id: id
    )

    id
  end

  # A private options server carries the theme, so concurrent sessions never share a theme through the global one.
  # Returns the editor options and the child ids `stop/1` stops.
  @spec theme_opts(atom() | nil) :: {keyword(), [term()]}
  defp theme_opts(nil), do: {[], []}

  defp theme_opts(theme) when is_atom(theme) do
    events = :"minga_storyboard_events_#{System.unique_integer([:positive])}"
    ExUnit.Callbacks.start_supervised!({Minga.Events, name: events}, id: events)
    options_id = {:storyboard_options, events}

    options =
      ExUnit.Callbacks.start_supervised!(
        {Minga.Config.Options, name: nil, events_registry: events},
        id: options_id
      )

    {:ok, _theme} = Minga.Config.Options.set(options, :theme, theme)
    {[events_registry: events, options_server: options], [options_id, events]}
  end

  # Without a root, every session gets a fresh private project. A fixed root (the renderer's) is shared by every run
  # on the machine, including concurrent runs in other worktrees, so it is never deleted: its files are written
  # atomically with the same content every time, and a run never removes a project another run is using.
  # Its saved workspaces are cleared, though: the editor restores them at start, so a capture would otherwise
  # show the task names and tabs an earlier capture left there instead of the scenario's own.
  @spec make_project(Path.t() | nil, Path.t(), String.t()) :: Path.t()
  # Under `tmp/MingaEditor.*`, the project registry treats the root as a test fixture and never remembers it, so a
  # session that opens its project (the home's recent-project row) cannot add it to another session's project list.
  defp make_project(nil, file_name, content) do
    root =
      Path.join([
        System.tmp_dir!(),
        "tmp",
        "MingaEditor.Storyboard",
        "project-#{System.unique_integer([:positive])}"
      ])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    write_project(root, file_name, content)
  end

  defp make_project(root, file_name, content) do
    File.rm_rf!(Path.join([root, ".minga", "workspaces"]))
    write_project(root, file_name, content)
  end

  @spec write_project(Path.t(), Path.t(), String.t()) :: Path.t()
  defp write_project(root, file_name, content) do
    atomic_write!(Path.join(root, "mix.exs"), "defmodule Storyboard.MixProject do\nend\n")
    atomic_write!(Path.join(root, file_name), content)

    # The scenarios search for words the project does not hold, so the search answers from memory, never ripgrep.
    :ok = Minga.Test.ProjectSearchStub.set_results(root, [])
    root
  end

  @spec atomic_write!(Path.t(), String.t()) :: :ok
  defp atomic_write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, content)
    File.rename!(temporary, path)
  end
end
