defmodule Minga.Test.EditorCase do
  @moduledoc """
  ExUnit case template for headless editor tests.
  Provides helpers to start an editor with a virtual screen capture,
  send keystrokes, and assert on rendered output.
  ## Usage
      defmodule MyTest do
        use Minga.Test.EditorCase, async: true
        test "shows file content on screen", ctx do
          ctx = start_editor(ctx, "hello world")
          assert_row_contains(ctx, 0, "hello world")
        end
      end
  """
  use ExUnit.CaseTemplate
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor
  alias Minga.Test.HeadlessPort
  alias Minga.Test.Snapshot

  using do
    quote do
      import Minga.Test.EditorCase
      alias Minga.Buffer.Process, as: BufferProcess
    end
  end

  @typedoc "Test context with editor processes."
  @type editor_ctx :: %{
          editor: pid(),
          buffer: pid(),
          port: pid(),
          width: pos_integer(),
          height: pos_integer(),
          events_registry: Minga.Events.registry()
        }

  @sync_timeout 15_000

  # ── Setup helpers ────────────────────────────────────────────────────────────
  @doc """
  Starts an editor with headless port for render capture.
  Returns the context map with `:editor`, `:buffer`, `:port` keys added.
  Options:
    - `:width` — terminal width (default 80)
    - `:height` — terminal height (default 24)
    - `:file_path` — optional file path for the buffer
  """
  @spec start_editor(String.t(), keyword()) :: editor_ctx()
  def start_editor(content, opts \\ []) do
    ctx = %{}
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    file_path = Keyword.get(opts, :file_path)
    clipboard = Keyword.get(opts, :clipboard, :none)
    id = :erlang.unique_integer([:positive])

    events_registry =
      Keyword.get_lazy(opts, :events_registry, fn -> start_events_registry(id) end)

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)
    buffer_opts = [content: content, events_registry: events_registry]
    buffer_opts = if file_path, do: [{:file_path, file_path} | buffer_opts], else: buffer_opts

    buffer_opts =
      if Keyword.has_key?(opts, :options_server),
        do: [{:options_server, Keyword.get(opts, :options_server)} | buffer_opts],
        else: buffer_opts

    {:ok, buffer} = BufferProcess.start_link(buffer_opts)

    # Inject clipboard mode directly on the buffer so the Editor never
    # reads the global Config.Options for clipboard. Each test is isolated.
    BufferProcess.set_option(buffer, :clipboard, clipboard)

    # Pin editing model per-editor so async tests don't race on global ETS.
    editing_model = Keyword.get(opts, :editing_model, :vim)
    # Backend defaults to :headless; override to :tui for TUI-specific tests.
    backend = Keyword.get(opts, :backend, :headless)
    # Shell defaults to nil (uses config); override to :board for Board tests.
    shell = Keyword.get(opts, :shell)

    editor_opts = [
      name: :"headless_editor_#{id}",
      backend: backend,
      port_manager: port,
      buffer: buffer,
      width: width,
      height: height,
      editing_model: editing_model,
      events_registry: events_registry,
      suppress_tool_prompts: true
    ]

    editor_opts =
      if Keyword.has_key?(opts, :options_server),
        do: [{:options_server, Keyword.get(opts, :options_server)} | editor_opts],
        else: editor_opts

    editor_opts =
      if shell, do: [{:shell, shell}, {:skip_persistence, true} | editor_opts], else: editor_opts

    # Thread project_root for file tree isolation in tests
    project_root = Keyword.get(opts, :project_root)

    editor_opts =
      if project_root, do: [{:project_root, project_root} | editor_opts], else: editor_opts

    {:ok, editor} = MingaEditor.start_link(editor_opts)

    # Send ready event to trigger initial render
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, @sync_timeout)
    Process.put({:last_frame_snapshot, port}, snapshot)

    # Drain any deferred messages queued by the :ready handler (e.g.
    # :setup_highlight, :debounced_render). Without this, a background
    # render can produce a spurious batch_end that satisfies the next
    # send_key's frame waiter before the key press is actually processed.
    _ = sync_editor(editor)
    _ = sync_port(port)

    Map.merge(ctx, %{
      editor: editor,
      buffer: buffer,
      port: port,
      width: width,
      height: height,
      events_registry: events_registry
    })
  end

  @doc "Starts a headless editor with a pre-existing buffer."
  @spec start_editor_with_buffer(pid(), keyword()) :: editor_ctx()
  def start_editor_with_buffer(buffer, opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    clipboard = Keyword.get(opts, :clipboard, :none)
    id = :erlang.unique_integer([:positive])

    events_registry =
      Keyword.get_lazy(opts, :events_registry, fn -> start_events_registry(id) end)

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)

    # Inject clipboard mode directly on the buffer so the Editor never
    # reads the global Config.Options for clipboard. Each test is isolated.
    BufferProcess.set_option(buffer, :clipboard, clipboard)

    editing_model = Keyword.get(opts, :editing_model, :vim)

    editor_opts = [
      name: :"headless_editor_#{id}",
      backend: :headless,
      port_manager: port,
      buffer: buffer,
      width: width,
      height: height,
      editing_model: editing_model,
      events_registry: events_registry,
      suppress_tool_prompts: true
    ]

    editor_opts =
      if Keyword.has_key?(opts, :options_server),
        do: [{:options_server, Keyword.get(opts, :options_server)} | editor_opts],
        else: editor_opts

    project_root = Keyword.get(opts, :project_root)

    editor_opts =
      if project_root, do: [{:project_root, project_root} | editor_opts], else: editor_opts

    {:ok, editor} = MingaEditor.start_link(editor_opts)

    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, @sync_timeout)
    Process.put({:last_frame_snapshot, port}, snapshot)

    # Drain deferred messages from :ready (see start_editor/2 comment).
    _ = sync_editor(editor)
    _ = sync_port(port)

    %{
      editor: editor,
      buffer: buffer,
      port: port,
      width: width,
      height: height,
      events_registry: events_registry
    }
  end

  # ── Highlight injection helpers ─────────────────────────────────────────────
  @doc """
  Injects highlight state into the editor and waits for it to be fully processed.
  Flushes any pending messages (like `:setup_highlight` from the `:ready` handler)
  before injecting, then syncs again to ensure the highlight state is applied
  before the test continues.
  """
  @spec inject_highlights(editor_ctx(), [String.t()], non_neg_integer(), [map()]) :: editor_ctx()
  def inject_highlights(ctx, capture_names, version \\ 1, spans) do
    # Flush pending messages (e.g. :setup_highlight from :ready)
    _ = sync_editor(ctx.editor)

    # Ensure the active buffer has a registered parser buffer_id so the
    # highlight event handlers can route the message correctly. Previously
    # this used a hardcoded buffer_id=0 with a fallback to active buffer,
    # but that fallback was removed (it could misroute spans to the wrong
    # buffer after a buffer switch).
    #
    # For test buffers that don't have a recognized filetype (no tree-sitter
    # grammar), setup_highlight won't assign a buffer_id. We use
    # :sys.replace_state to directly assign one, which is safe in tests.
    buffer_id = ensure_test_buffer_id(ctx.editor)

    send(ctx.editor, {:minga_input, {:highlight_names, buffer_id, capture_names}})
    send(ctx.editor, {:minga_input, {:highlight_spans, buffer_id, version, spans}})
    # Sync: ensure both messages have been processed before returning
    _ = sync_editor(ctx.editor)
    ctx
  end

  # Ensures the active buffer has a registered parser buffer_id.
  # Returns the buffer_id (existing or newly assigned).
  @spec ensure_test_buffer_id(pid()) :: non_neg_integer()
  defp ensure_test_buffer_id(editor) do
    state = get_editor_state(editor)
    buf = state.workspace.buffers.active

    if buf == nil do
      0
    else
      hl = state.workspace.highlight

      case Map.fetch(hl.buffer_ids, buf) do
        {:ok, id} ->
          id

        :error ->
          # Assign a buffer_id directly via :sys.replace_state
          id = hl.next_buffer_id

          :sys.replace_state(editor, fn st ->
            h = st.workspace.highlight

            put_in(st.workspace.highlight, %{
              h
              | buffer_ids: Map.put(h.buffer_ids, buf, id),
                reverse_buffer_ids: Map.put(h.reverse_buffer_ids, id, buf),
                next_buffer_id: id + 1
            })
          end)

          id
      end
    end
  end

  # ── Key sending helpers ──────────────────────────────────────────────────────
  @doc """
  Sends a key press and waits for the next rendered frame.
  Stores the captured frame snapshot in the process dictionary so
  `assert_screen_snapshot` can use the race-free captured state
  instead of reading the (possibly overwritten) HeadlessPort grid.
  """
  @spec send_key(editor_ctx(), non_neg_integer(), non_neg_integer()) :: :ok
  def send_key(%{editor: editor, port: port}, codepoint, mods \\ 0) do
    # Drain any pending async messages (timers, highlight events, etc.)
    # before registering the frame waiter. This prevents a pending render
    # from satisfying our waiter instead of the intended key's render.
    _ = sync_editor(editor)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, @sync_timeout)
    # Store snapshot keyed by port pid so concurrent tests don't collide
    Process.put({:last_frame_snapshot, port}, snapshot)
    :ok
  end

  @doc """
  Sends a key and waits for the editor GenServer to process it.
  Uses a public GenServer call as a synchronization barrier instead of waiting
  for a render frame. Safe for both editor/buffer state reads AND
  port/screen state reads: because the editor sends the render cast to
  the port before processing the barrier call, BEAM message ordering guarantees
  the render reaches the port's mailbox ahead of any subsequent `screen_cursor`
  or `modeline` call from the test process.

  This is the preferred sync primitive for navigation tests. Use
  `send_key/3` only when you need the captured frame snapshot for
  `assert_screen_snapshot`. Returns the editor state after processing.
  """
  @spec send_key_sync(editor_ctx(), non_neg_integer(), non_neg_integer()) :: map()
  def send_key_sync(%{editor: editor, port: port}, codepoint, mods \\ 0) do
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    # Clear any stale frame snapshot so assert_screen_snapshot falls back
    # to reading the live (post-render) grid from HeadlessPort.
    Process.delete({:last_frame_snapshot, port})
    get_editor_state(editor)
  end

  @doc """
  Sends a vim-style key sequence and returns the editor state after
  all keys are processed. Uses a public GenServer call as a barrier after
  each key to ensure re-sent messages (like passthrough from file tree
  or which-key timeouts) are fully processed before the next key.
  """
  @spec send_keys_sync(editor_ctx(), String.t()) :: map()
  def send_keys_sync(%{editor: editor, port: port} = _ctx, sequence) do
    parse_key_sequence(sequence)
    |> Enum.each(fn {cp, mods} ->
      send(editor, {:minga_input, {:key_press, cp, mods}})
      sync_editor(editor)
    end)

    # Clear any stale frame snapshot so assert_screen_snapshot falls back
    # to reading the live (post-render) grid from HeadlessPort.
    Process.delete({:last_frame_snapshot, port})
    get_editor_state(editor)
  end

  @doc """
  Syncs the port so its grid reflects the latest render from the editor.

  After `send_keys_sync` returns, the editor has finished processing all
  keys and sent the render cast to the port. But the port processes that
  cast asynchronously. This function reads a port snapshot as a barrier,
  ensuring the port has processed all pending render commands
  before the test reads the screen.

  Call this before `assert_screen_snapshot` when using `send_keys_sync`.
  Not needed after `send_key` (which captures a frame snapshot directly).
  """
  @spec sync_screen(editor_ctx()) :: :ok
  def sync_screen(%{port: port}) do
    sync_port(port)
    :ok
  end

  @doc "Sends each character in the string as a key press, waiting after each."
  @spec type_text(editor_ctx(), String.t()) :: :ok
  def type_text(ctx, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(ctx, char) end)

    :ok
  end

  @doc """
  Sends a vim-style key sequence. Supports:
  - `<Esc>` — escape (27)
  - `<CR>` or `<Enter>` — enter (13)
  - `<BS>` — backspace (127)
  - `<C-x>` — ctrl+x
  - `<Space>` or `<SPC>` — space (32)
  - Regular characters sent as-is
  """
  @spec send_keys(editor_ctx(), String.t()) :: :ok
  def send_keys(ctx, sequence) do
    parse_key_sequence(sequence)
    |> Enum.each(fn {cp, mods} -> send_key(ctx, cp, mods) end)

    :ok
  end

  # ── Screen query helpers ─────────────────────────────────────────────────────

  # All screen helpers read from the last captured frame snapshot stored
  # by send_key/send_mouse/start_editor. This is race-free: the snapshot
  # is immutable data in the test process, unaffected by subsequent async
  # renders. Falls back to the live HeadlessPort grid only when no
  # snapshot exists (should not happen in well-structured tests).

  @doc "Returns the rendered text for a specific row."
  @spec screen_row(editor_ctx(), non_neg_integer()) :: String.t()
  def screen_row(%{port: port}, row) do
    case Process.get({:last_frame_snapshot, port}) do
      %{grid: grid} ->
        grid
        |> Enum.at(row, [])
        |> Enum.map_join(& &1.char)
        |> String.trim_trailing()

      nil ->
        HeadlessPort.get_row_text(port, row)
    end
  end

  @doc "Returns all screen rows as a list of strings."
  @spec screen_text(editor_ctx()) :: [String.t()]
  def screen_text(%{port: port}) do
    case Process.get({:last_frame_snapshot, port}) do
      %{grid: grid} ->
        Enum.map(grid, fn row ->
          row |> Enum.map_join(& &1.char) |> String.trim_trailing()
        end)

      nil ->
        HeadlessPort.get_screen_text(port)
    end
  end

  @doc "Returns the modeline row text (second to last row)."
  @spec modeline(editor_ctx()) :: String.t()
  def modeline(%{height: height} = ctx) do
    screen_row(ctx, height - 2)
  end

  @doc "Returns the minibuffer row text (last row)."
  @spec minibuffer(editor_ctx()) :: String.t()
  def minibuffer(%{height: height} = ctx) do
    screen_row(ctx, height - 1)
  end

  @doc "Returns the cursor position on screen."
  @spec screen_cursor(editor_ctx()) :: {non_neg_integer(), non_neg_integer()}
  def screen_cursor(%{port: port}) do
    case Process.get({:last_frame_snapshot, port}) do
      %{cursor: cursor} -> cursor
      nil -> HeadlessPort.get_cursor(port)
    end
  end

  @doc "Returns the current cursor shape."
  @spec cursor_shape(editor_ctx()) :: MingaEditor.Frontend.Protocol.cursor_shape()
  def cursor_shape(%{port: port}) do
    case Process.get({:last_frame_snapshot, port}) do
      %{cursor_shape: shape} -> shape
      nil -> HeadlessPort.get_cursor_shape(port)
    end
  end

  @doc "Returns the buffer content."
  @spec buffer_content(editor_ctx()) :: String.t()
  def buffer_content(%{buffer: buffer}) do
    BufferProcess.content(buffer)
  end

  @spec get_editor_state(pid()) :: MingaEditor.State.t()
  defp get_editor_state(editor), do: :sys.get_state(editor, @sync_timeout)

  @spec sync_editor(pid()) :: atom()
  defp sync_editor(editor), do: GenServer.call(editor, :api_mode, @sync_timeout)

  @spec sync_port(pid()) :: HeadlessPort.screen()
  defp sync_port(port), do: HeadlessPort.get_screen(port)

  @doc "Returns the current editor mode."
  @spec editor_mode(editor_ctx()) :: atom()
  def editor_mode(%{editor: editor}) do
    Minga.Editing.mode(get_editor_state(editor))
  end

  @doc "Returns the buffer cursor position."
  @spec buffer_cursor(editor_ctx()) :: {non_neg_integer(), non_neg_integer()}
  def buffer_cursor(%{buffer: buffer}) do
    BufferProcess.cursor(buffer)
  end

  @doc "Returns the full editor state after synchronizing with the editor process. Prefer narrower helpers when possible."
  @spec editor_state(editor_ctx()) :: MingaEditor.State.t()
  def editor_state(%{editor: editor}) do
    get_editor_state(editor)
  end

  @doc "Returns MessageStore entries after synchronizing with the editor process."
  @spec message_store_entries(editor_ctx()) :: [map()]
  def message_store_entries(%{editor: editor}) do
    get_editor_state(editor).message_store.entries
  end

  @doc "Returns the number of open buffers."
  @spec buffer_count(editor_ctx()) :: non_neg_integer()
  def buffer_count(%{editor: editor}) do
    length(get_editor_state(editor).workspace.buffers.list)
  end

  @doc "Returns the active buffer index (0-based)."
  @spec active_buffer_index(editor_ctx()) :: non_neg_integer()
  def active_buffer_index(%{editor: editor}) do
    get_editor_state(editor).workspace.buffers.active_index
  end

  @doc "Returns the active buffer pid."
  @spec active_buffer(editor_ctx()) :: pid() | nil
  def active_buffer(%{editor: editor}) do
    get_editor_state(editor).workspace.buffers.active
  end

  @doc "Returns the content of the active buffer."
  @spec active_content(editor_ctx()) :: String.t()
  def active_content(ctx) do
    case active_buffer(ctx) do
      nil -> ""
      buf -> BufferProcess.content(buf)
    end
  end

  @doc "Returns whether the window tree contains a split."
  @spec has_split?(editor_ctx()) :: boolean()
  def has_split?(%{editor: editor}) do
    MingaEditor.State.Windows.split?(get_editor_state(editor).workspace.windows)
  end

  @doc "Returns the number of windows."
  @spec window_count(editor_ctx()) :: non_neg_integer()
  def window_count(%{editor: editor}) do
    map_size(get_editor_state(editor).workspace.windows.map)
  end

  @doc "Returns the active window id."
  @spec active_window_id(editor_ctx()) :: pos_integer()
  def active_window_id(%{editor: editor}) do
    get_editor_state(editor).workspace.windows.active
  end

  @doc "Returns true if a picker is currently open."
  @spec picker_open?(editor_ctx()) :: boolean()
  def picker_open?(%{editor: editor}) do
    MingaEditor.State.ModalOverlay.match(get_editor_state(editor).shell_state.modal, :picker)
  end

  @doc "Returns the active picker state, or nil."
  @spec picker_state(editor_ctx()) :: MingaEditor.UI.Picker.t() | nil
  def picker_state(%{editor: editor}) do
    case get_editor_state(editor).shell_state.modal do
      {:picker, %{picker_ui: %{picker: picker}}} -> picker
      _ -> nil
    end
  end

  # ── State query helpers ──────────────────────────────────────────────────
  # :sys.get_state is valid as a synchronization barrier (ensuring messages
  # are processed), but tests should not pattern-match on returned state
  # fields. Helpers here return booleans that answer "is this happening?"
  # without exposing the state path. For visible text (status messages,
  # prompts), prefer screen helpers like minibuffer/1 and screen_row/2.

  @doc "Returns true if a search pattern is active."
  @spec search_active?(editor_ctx()) :: boolean()
  def search_active?(%{editor: editor}) do
    get_editor_state(editor).workspace.search.last_pattern != nil
  end

  @doc "Returns true if the file tree is open."
  @spec file_tree_open?(editor_ctx()) :: boolean()
  def file_tree_open?(%{editor: editor}) do
    editor
    |> get_editor_state()
    |> MingaEditor.State.file_tree_state()
    |> MingaEditor.State.FileTree.open?()
  end

  @doc "Returns true if the completion menu is visible."
  @spec completion_visible?(editor_ctx()) :: boolean()
  def completion_visible?(%{editor: editor}) do
    MingaEditor.State.ModalOverlay.match(get_editor_state(editor).shell_state.modal, :completion)
  end

  @doc "Returns true if a file conflict prompt is open."
  @spec conflict_open?(editor_ctx()) :: boolean()
  def conflict_open?(%{editor: editor}) do
    MingaEditor.State.ModalOverlay.match(get_editor_state(editor).shell_state.modal, :conflict)
  end

  @doc "Returns the pending quit mode (:quit | :quit_all | nil)."
  @spec pending_quit(editor_ctx()) :: :quit | :quit_all | nil
  def pending_quit(%{editor: editor}) do
    get_editor_state(editor).pending_quit
  end

  @doc "Returns the current status/command message."
  @spec status_msg(editor_ctx()) :: String.t() | nil
  def status_msg(%{editor: editor}) do
    MingaEditor.State.status_msg(get_editor_state(editor))
  end

  @doc "Returns the tab bar labels."
  @spec tab_labels(editor_ctx()) :: [String.t()]
  def tab_labels(%{editor: editor}) do
    Enum.map(get_editor_state(editor).shell_state.tab_bar.tabs, & &1.label)
  end

  @doc "Returns the active workspace ID."
  @spec active_workspace_id(editor_ctx()) :: non_neg_integer()
  def active_workspace_id(%{editor: editor}) do
    MingaEditor.State.TabBar.active_workspace_id(get_editor_state(editor).shell_state.tab_bar)
  end

  @doc "Returns visible file tabs for the given workspace ID."
  @spec visible_file_tabs(editor_ctx(), non_neg_integer()) :: [map()]
  def visible_file_tabs(%{editor: editor}, workspace_id) do
    MingaEditor.State.TabBar.visible_file_tabs(
      get_editor_state(editor).shell_state.tab_bar,
      workspace_id
    )
  end

  @doc "Returns the picker payload (ModalOverlay.Picker) when a picker is open, or nil."
  @spec modal_picker(editor_ctx()) :: MingaEditor.State.ModalOverlay.Picker.t() | nil
  def modal_picker(%{editor: editor}) do
    case get_editor_state(editor).shell_state.modal do
      {:picker, payload} -> payload
      _ -> nil
    end
  end

  @doc """
  Like `modal_picker/1` but raises with a clear message when no picker is
  open. Use this in tests where the next step assumes the payload exists,
  so the failure surfaces as "picker not open" instead of `nil.picker_ui`.
  """
  @spec modal_picker!(editor_ctx()) :: MingaEditor.State.ModalOverlay.Picker.t()
  def modal_picker!(ctx) do
    case modal_picker(ctx) do
      nil ->
        modal = get_editor_state(ctx.editor).shell_state.modal
        raise "expected picker payload, but modal was: #{inspect(modal)}"

      payload ->
        payload
    end
  end

  @doc "Returns the cell at a given screen row and col."
  @spec screen_cell(editor_ctx(), non_neg_integer(), non_neg_integer()) :: map()
  def screen_cell(%{port: port}, row, col) do
    HeadlessPort.get_cell(port, row, col)
  end

  # ── Assertion helpers ────────────────────────────────────────────────────────
  @doc "Asserts that a screen row contains the expected text."
  defmacro assert_row_contains(ctx, row, expected) do
    quote do
      row_text = screen_row(unquote(ctx), unquote(row))

      assert String.contains?(row_text, unquote(expected)),
             "Expected row #{unquote(row)} to contain #{inspect(unquote(expected))}, got: #{inspect(row_text)}"
    end
  end

  @doc "Asserts the modeline contains the expected text."
  defmacro assert_modeline_contains(ctx, expected) do
    quote do
      ml = modeline(unquote(ctx))

      assert String.contains?(ml, unquote(expected)),
             "Expected modeline to contain #{inspect(unquote(expected))}, got: #{inspect(ml)}"
    end
  end

  @doc "Asserts the minibuffer contains the expected text."
  defmacro assert_minibuffer_contains(ctx, expected) do
    quote do
      mb = minibuffer(unquote(ctx))

      assert String.contains?(mb, unquote(expected)),
             "Expected minibuffer to contain #{inspect(unquote(expected))}, got: #{inspect(mb)}"
    end
  end

  @doc "Asserts the modeline shows the expected mode badge."
  defmacro assert_mode(ctx, mode) do
    quote do
      badge =
        case unquote(mode) do
          :normal -> "NORMAL"
          :insert -> "INSERT"
          :visual -> "VISUAL"
          :command -> "COMMAND"
        end

      ml = modeline(unquote(ctx))

      assert String.contains?(ml, badge),
             "Expected modeline to show #{badge} mode, got: #{inspect(ml)}"
    end
  end

  @doc """
  Asserts the current screen matches a stored snapshot baseline.
  On first run (no baseline), writes the snapshot and passes with a log
  message. On subsequent runs, diffs the current screen against the
  baseline. Any difference fails the test.
  Run with `UPDATE_SNAPSHOTS=1 mix test` to overwrite all baselines.
  ## Example
      ctx = start_editor("hello world")
      send_keys_sync(ctx, "llx")
      assert_screen_snapshot(ctx, "after_delete_char")
  """
  defmacro assert_screen_snapshot(ctx, snapshot_name) do
    quote do
      ctx = unquote(ctx)
      name = unquote(snapshot_name)
      # If a preceding `send_key` captured a frame snapshot, use it.
      # Otherwise (after `send_key_sync`/`send_keys_sync`, which clear
      # the stale snapshot), fall back to reading the live grid from
      # HeadlessPort. The fallback is safe because BEAM message ordering
      # guarantees the render cast reached the port before the sync
      # barrier returned.
      {rows, snap_cursor, snap_shape} =
        case Process.get({:last_frame_snapshot, ctx.port}) do
          %{grid: grid, cursor: c, cursor_shape: s} ->
            r =
              Enum.map(grid, fn row ->
                row |> Enum.map_join(& &1.char) |> String.trim_trailing()
              end)

            {r, c, s}

          nil ->
            {screen_text(ctx), screen_cursor(ctx), cursor_shape(ctx)}
        end

      mode = editor_mode(ctx)

      metadata = %{
        cursor: snap_cursor,
        cursor_shape: snap_shape,
        mode: mode,
        width: ctx.width,
        height: ctx.height
      }

      normalized_rows = Snapshot.normalize_volatile_rows(rows, ctx.width)
      current = Snapshot.serialize(normalized_rows, metadata)
      path = Snapshot.snapshot_path(__MODULE__, name)

      if Snapshot.update_mode?() do
        Snapshot.write!(path, current)
      else
        case Snapshot.compare(current, path) do
          :match ->
            :ok

          {:no_baseline, baseline_path} ->
            Snapshot.write!(baseline_path, current)
            require Logger
            Logger.warning("New snapshot written: #{baseline_path}. Review and commit.")

          {:mismatch, diff} ->
            flunk("""
            Screen snapshot mismatch for "#{name}"
            Snapshot file: #{path}
            Run UPDATE_SNAPSHOTS=1 mix test to accept the new output.
            Diff (- expected, + actual):
            #{diff}
            """)
        end
      end
    end
  end

  @doc """
  Polls the editor state until the given function returns a truthy value.
  Retries up to `max_attempts` times with `interval_ms` between attempts.
  Returns the final state on success, or raises with the given message.
  Useful for waiting on async state transitions (file opens, picker
  selection, highlight clears) that may not settle within a single frame.
  """
  @spec wait_until(editor_ctx(), (map() -> boolean()), keyword()) :: map()
  def wait_until(%{editor: editor} = _ctx, condition, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 20)
    interval = Keyword.get(opts, :interval_ms, 10)
    message = Keyword.get(opts, :message, "Condition not met after polling")
    do_wait_until(editor, condition, max, interval, message)
  end

  defp do_wait_until(editor, condition, remaining, interval, message) when remaining > 0 do
    state = get_editor_state(editor)

    if condition.(state) do
      state
    else
      receive do
      after
        interval ->
          do_wait_until(editor, condition, remaining - 1, interval, message)
      end
    end
  end

  defp do_wait_until(editor, _condition, _remaining, _interval, message) do
    state = get_editor_state(editor)

    raise ExUnit.AssertionError,
      message: "#{message}\nFinal state mode: #{Minga.Editing.mode(state)}"
  end

  @doc """
  Polls until a screen-based condition is true.

  Unlike `wait_until`, this syncs both the editor GenServer AND the
  HeadlessPort before each check. This ensures render commands have been
  flushed to the grid before `screen_row`/`screen_text` are called.

  The condition function takes no arguments; use screen query helpers
  (`screen_row`, `screen_text`) inside it to inspect rendered output.

  Uses a larger default polling budget (50×20ms = 1s) than `wait_until`
  because layout-settling operations (file tree + agent panel) may need
  multiple render cycles on loaded CI runners.
  """
  @spec wait_until_screen(editor_ctx(), (-> boolean()), keyword()) :: :ok
  def wait_until_screen(%{editor: editor, port: port} = _ctx, condition, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 50)
    interval = Keyword.get(opts, :interval_ms, 20)
    message = Keyword.get(opts, :message, "Screen condition not met after polling")
    do_wait_screen(editor, port, condition, max, interval, message)
  end

  defp do_wait_screen(editor, port, condition, remaining, interval, message) when remaining > 0 do
    sync_editor(editor)
    sync_port(port)

    if condition.() do
      :ok
    else
      receive do
      after
        interval ->
          do_wait_screen(editor, port, condition, remaining - 1, interval, message)
      end
    end
  end

  defp do_wait_screen(editor, port, _condition, _remaining, _interval, message) do
    # Sync both processes so any post-failure inspection sees stable state
    state = get_editor_state(editor)
    sync_port(port)

    raise ExUnit.AssertionError,
      message: "#{message}\nFinal state mode: #{Minga.Editing.mode(state)}"
  end

  # ── Mouse and resize helpers ─────────────────────────────────────────────────

  @doc """
  Sends a mouse event to the editor and waits for the next rendered frame.
  `button` is an atom like `:left`, `:right`, `:middle`, `:wheel_up`, `:wheel_down`.
  `event_type` is `:press`, `:release`, or `:drag`.
  """
  @spec send_mouse(
          editor_ctx(),
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: :ok
  def send_mouse(
        %{editor: editor, port: port},
        row,
        col,
        button,
        mods \\ 0,
        event_type \\ :press,
        click_count \\ 1
      ) do
    _ = sync_editor(editor)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:mouse_event, row, col, button, mods, event_type, click_count}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, @sync_timeout)
    Process.put({:last_frame_snapshot, port}, snapshot)
    :ok
  end

  @doc """
  Sends a resize event to the editor and waits for the next rendered frame.
  Updates the HeadlessPort grid dimensions first, then triggers the editor resize.
  """
  @spec send_resize(editor_ctx(), pos_integer(), pos_integer()) :: editor_ctx()
  def send_resize(%{editor: editor, port: port} = ctx, new_width, new_height) do
    _ = sync_editor(editor)
    HeadlessPort.resize(port, new_width, new_height)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:resize, new_width, new_height}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, @sync_timeout)
    Process.put({:last_frame_snapshot, port}, snapshot)
    %{ctx | width: new_width, height: new_height}
  end

  @doc "Returns true if any screen row contains the given text."
  @spec screen_contains?(editor_ctx(), String.t()) :: boolean()
  def screen_contains?(ctx, text) do
    screen_text(ctx)
    |> Enum.any?(fn row -> String.contains?(row, text) end)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec start_events_registry(pos_integer()) :: Minga.Events.registry()
  defp start_events_registry(id) do
    name = :"minga_events_#{id}"
    start_supervised!({Minga.Events, name: name})
    name
  end

  @ctrl 0x02
  @spec parse_key_sequence(String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  defp parse_key_sequence(seq), do: do_parse_keys(seq, [])
  defp do_parse_keys("", acc), do: Enum.reverse(acc)
  defp do_parse_keys("<Esc>" <> rest, acc), do: do_parse_keys(rest, [{27, 0} | acc])
  defp do_parse_keys("<CR>" <> rest, acc), do: do_parse_keys(rest, [{13, 0} | acc])
  defp do_parse_keys("<Enter>" <> rest, acc), do: do_parse_keys(rest, [{13, 0} | acc])
  defp do_parse_keys("<BS>" <> rest, acc), do: do_parse_keys(rest, [{127, 0} | acc])
  defp do_parse_keys("<Space>" <> rest, acc), do: do_parse_keys(rest, [{32, 0} | acc])
  defp do_parse_keys("<SPC>" <> rest, acc), do: do_parse_keys(rest, [{32, 0} | acc])

  defp do_parse_keys("<C-" <> rest, acc) do
    case String.split(rest, ">", parts: 2) do
      [key, remainder] ->
        <<cp::utf8>> = String.downcase(key)
        do_parse_keys(remainder, [{cp, @ctrl} | acc])

      _ ->
        do_parse_keys(rest, acc)
    end
  end

  defp do_parse_keys(<<cp::utf8, rest::binary>>, acc) do
    do_parse_keys(rest, [{cp, 0} | acc])
  end
end
