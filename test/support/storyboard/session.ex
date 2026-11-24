defmodule Minga.Test.Storyboard.Session do
  @moduledoc """
  Drives one headless editor through the BEAM for the storyboard factory.

  A session wraps `Minga.Test.EditorCase.start_editor/2` with a project in a private temporary directory, so every scenario starts from the same cold start: one Elixir file open in Normal mode. `press/2` takes the key notation from `docs/design/scenarios.toml` (see `Minga.Test.Storyboard.Keys`), `click/2` sends a semantic click, and `model/1` returns the committed semantic frame as a `Minga.Test.Storyboard.Model`.

  Call `start/1` from an ExUnit test process: the editor is started with `start_supervised`, so it stops with the test. Rendering is disabled by default because the model is built from editor state with the same builder the render pipeline uses; pass `rendering: :enabled` when a caller also needs rendered frames (#4036).
  """

  alias Minga.Test.EditorCase
  alias Minga.Test.Storyboard.Keys
  alias Minga.Test.Storyboard.Model
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.MinibufferData
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.RenderModel.UI.Builder, as: UIBuilder
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
          home_window: pos_integer(),
          path: [String.t()]
        }

  @enforce_keys [:ctx, :root, :file, :home_window, :child_id]
  defstruct [:ctx, :root, :file, :home_window, :child_id, children: [], path: []]

  @typedoc "A semantic click: a mouse press at a cell, or a GUI action the frontend would send."
  @type click :: {:mouse, non_neg_integer(), non_neg_integer()} | {:gui_action, term()}

  @doc """
  Starts a headless editor at the factory's cold start.

  Options: `:content` (the file's text), `:file_name` (relative to the project root, default `lib/storyboard.ex`), `:width` and `:height` (default 120 by 36), and `:rendering` (`:disabled` by default).

  Every session runs the real tree-sitter parser and returns only once its highlights are applied, so parser-dependent keys (structural motions, text objects, folds) behave as in the app and every frame is highlighted. The parser is the suite's shared one (`shared_parser/0`) unless `:parser_manager` names another running `Minga.Parser.Manager`.

  `:minga` puts Minga in an Agent status before the first key, for example `:thinking` for "Minga is working". The status goes into the editor's live presentation cache, the value every surface reads, so the modeline, the activity card and the rest show it the way they would for a running session. The factory has no running session, so nothing changes the status afterwards.

  The storyboard renderer (#4036) adds four more: `:root` (a fixed project directory, so the path the chrome shows is the same on every machine; the caller keeps it unique among concurrent sessions in one run, and the directory is written atomically and never deleted, so concurrent runs on one machine can share it), `:theme` (a built-in theme name such as `:astrodark`, set on a private options server before the editor starts), `:capabilities` (the `MingaEditor.Frontend.Capabilities` the frontend would report), and `:record_packets` (keep every packet for `packets/1`).
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    content = Keyword.get(opts, :content, @default_content)
    file_name = Keyword.get(opts, :file_name, "lib/storyboard.ex")
    root = make_project(Keyword.get(opts, :root), file_name, content)
    file = Path.join(root, file_name)

    child_id = make_ref()
    parser = Keyword.get_lazy(opts, :parser_manager, &shared_parser!/0)

    editor_opts =
      [
        child_id: child_id,
        file_path: file,
        project_root: root,
        width: Keyword.get(opts, :width, 120),
        height: Keyword.get(opts, :height, 36),
        rendering: Keyword.get(opts, :rendering, :disabled),
        record_packets: Keyword.get(opts, :record_packets, false),
        parser_manager: parser
      ]

    {theme_opts, theme_children} = theme_opts(Keyword.get(opts, :theme))

    ctx =
      EditorCase.start_editor(
        content,
        editor_opts ++ Keyword.take(opts, [:capabilities]) ++ theme_opts
      )

    relay = start_relay(ctx, parser)
    await_highlights!(ctx, parser)
    install_minga_status(ctx, Keyword.get(opts, :minga))

    session = %__MODULE__{
      ctx: ctx,
      root: root,
      file: file,
      home_window: 0,
      child_id: child_id,
      children: [relay | theme_children]
    }

    %{session | home_window: window_id(session)}
  end

  @spec install_minga_status(EditorCase.editor_ctx(), Minga.Design.Tokens.agent_status() | nil) ::
          :ok
  defp install_minga_status(_ctx, nil), do: :ok

  defp install_minga_status(%{editor: editor}, status) do
    :sys.replace_state(
      editor,
      &MingaEditor.Shell.Traditional.Workflow.install_agent_status(&1, status)
    )

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
    session
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
    _ = EditorCase.editor_state(ctx)
    Minga.Test.HeadlessPort.get_screen_text(ctx.port)
  end

  @doc "The number of tree-sitter highlight spans the active buffer carries now. Zero without a parser."
  @spec highlight_span_count(t()) :: non_neg_integer()
  def highlight_span_count(%__MODULE__{ctx: ctx}) do
    ctx |> EditorCase.editor_state() |> highlight_spans() |> tuple_size()
  end

  @doc "Returns the semantic frame the editor would commit now."
  @spec model(t()) :: Model.t()
  def model(%__MODULE__{ctx: ctx}) do
    state = EditorCase.editor_state(ctx)
    status_bar = StatusBarData.from_state(state)
    minibuffer = MinibufferData.from_state(state)

    {ui, _context} =
      state |> Context.from_editor_state() |> UIBuilder.build_ui(status_bar, minibuffer)

    Model.from_ui(ui, state.appearance.theme)
  end

  @doc """
  Stops the session's editor, buffer and headless port before the test ends.

  Callers that start many sessions in one test (the flow explorer, the key walk) stop each one when done, so idle editors do not pile up. Safe to call on a session whose editor already died.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{ctx: ctx, child_id: child_id, children: children}) do
    _ = ExUnit.Callbacks.stop_supervised(child_id)
    Enum.each(children, &ExUnit.Callbacks.stop_supervised/1)

    for pid <- [ctx.buffer, ctx.port], Process.alive?(pid) do
      unlink_and_stop(pid)
    end

    :ok
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

  # The parser answers asynchronously: the editor applies the spans, then schedules a render. A session is ready when
  # the spans are applied and, when it renders, the frame that shows them has reached the headless frontend. Parser
  # events wake the wait early; the short timeout only re-checks a render that is still in flight.
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
      tuple_size(highlight_spans(state)) > 0 and rendered?(ctx, state) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "the storyboard parser applied no highlights within #{@highlight_deadline_ms} ms; " <>
                "is priv/minga-parser built (mix native.build.support)?"

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

  @spec flush_parser_events() :: :ok
  defp flush_parser_events do
    receive do
      {:minga_highlight, _event} -> flush_parser_events()
    after
      0 -> :ok
    end
  end

  @spec highlight_spans(MingaEditor.State.t()) :: tuple()
  defp highlight_spans(state), do: MingaEditor.HighlightSync.get_active_highlight(state).spans

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
  @spec make_project(Path.t() | nil, Path.t(), String.t()) :: Path.t()
  defp make_project(nil, file_name, content) do
    root = Path.join(System.tmp_dir!(), "minga-storyboard-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    write_project(root, file_name, content)
  end

  defp make_project(root, file_name, content), do: write_project(root, file_name, content)

  @spec write_project(Path.t(), Path.t(), String.t()) :: Path.t()
  defp write_project(root, file_name, content) do
    atomic_write!(Path.join(root, "mix.exs"), "defmodule Storyboard.MixProject do\nend\n")
    atomic_write!(Path.join(root, file_name), content)
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
