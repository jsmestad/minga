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
          root: Path.t(),
          file: Path.t(),
          home_window: pos_integer(),
          path: [String.t()]
        }

  @enforce_keys [:ctx, :root, :file, :home_window, :child_id]
  defstruct [:ctx, :root, :file, :home_window, :child_id, path: []]

  @typedoc "A semantic click: a mouse press at a cell, or a GUI action the frontend would send."
  @type click :: {:mouse, non_neg_integer(), non_neg_integer()} | {:gui_action, term()}

  @doc """
  Starts a headless editor at the factory's cold start.

  Options: `:content` (the file's text), `:file_name` (relative to the project root, default `lib/storyboard.ex`), `:width` and `:height` (default 120 by 36), and `:rendering` (`:disabled` by default).
  """
  @spec start(keyword()) :: t()
  def start(opts \\ []) do
    root = make_project()
    file = Path.join(root, Keyword.get(opts, :file_name, "lib/storyboard.ex"))
    content = Keyword.get(opts, :content, @default_content)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)

    child_id = make_ref()

    ctx =
      EditorCase.start_editor(content,
        child_id: child_id,
        file_path: file,
        project_root: root,
        width: Keyword.get(opts, :width, 120),
        height: Keyword.get(opts, :height, 36),
        rendering: Keyword.get(opts, :rendering, :disabled)
      )

    session = %__MODULE__{ctx: ctx, root: root, file: file, home_window: 0, child_id: child_id}
    %{session | home_window: window_id(session)}
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
  def stop(%__MODULE__{ctx: ctx, child_id: child_id}) do
    _ = ExUnit.Callbacks.stop_supervised(child_id)

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

  @spec make_project() :: Path.t()
  defp make_project do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-storyboard-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "mix.exs"), "defmodule Storyboard.MixProject do\nend\n")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
