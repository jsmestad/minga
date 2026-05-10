defmodule Minga.APITest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.API
  alias Minga.Buffer.Server, as: BufferServer

  # ── Test helpers ──────────────────────────────────────────────────────────────

  # A fake "editor" GenServer that responds to API calls with a real buffer.
  defmodule FakeEditor do
    @moduledoc false
    use GenServer

    @spec start_link(pid() | nil) :: GenServer.on_start()
    def start_link(buf_pid) do
      GenServer.start_link(__MODULE__, buf_pid)
    end

    @impl true
    def init(buf_pid), do: {:ok, %{buffer: buf_pid, messages: []}}

    @impl true
    def handle_call(:api_active_buffer, _from, %{buffer: nil} = state) do
      {:reply, {:error, :no_buffer}, state}
    end

    def handle_call(:api_active_buffer, _from, %{buffer: buf} = state) do
      {:reply, {:ok, buf}, state}
    end

    def handle_call(:api_mode, _from, state) do
      {:reply, :normal, state}
    end

    def handle_call(:api_save, _from, %{buffer: nil} = state) do
      {:reply, {:error, :no_buffer}, state}
    end

    def handle_call(:api_save, _from, %{buffer: buf} = state) do
      result = BufferServer.save(buf)
      {:reply, result, state}
    end

    def handle_call({:api_log_message, text}, _from, state) do
      {:reply, :ok, %{state | messages: [text | state.messages]}}
    end

    def handle_call({:api_execute_command, _cmd}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call({:open_file, _path}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call(:get_messages, _from, state) do
      {:reply, Enum.reverse(state.messages), state}
    end
  end

  defp start_buffer(content \\ "hello world") do
    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferServer, content: content, buffer_name: "test.txt"}
      )

    buf
  end

  defp start_fake_editor(buf_pid) do
    {:ok, editor} = FakeEditor.start_link(buf_pid)
    editor
  end

  # ── Buffer-level function tests ──────────────────────────────────────────────

  describe "content/1" do
    test "returns buffer content" do
      buf = start_buffer("hello world")
      editor = start_fake_editor(buf)

      assert {:ok, "hello world"} = API.content(editor)
    end

    test "returns error when no buffer" do
      {:ok, editor} = FakeEditor.start_link(nil)
      assert {:error, :no_buffer} = API.content(editor)
    end
  end

  describe "cursor/1" do
    test "returns cursor position" do
      buf = start_buffer("hello")
      editor = start_fake_editor(buf)

      assert {:ok, {0, 0}} = API.cursor(editor)
    end
  end

  describe "move_to/3" do
    test "moves cursor to specified position" do
      buf = start_buffer("hello\nworld")
      editor = start_fake_editor(buf)

      assert :ok = API.move_to(1, 2, editor)
      assert {:ok, {1, 2}} = API.cursor(editor)
    end

    test "returns error when no buffer" do
      {:ok, editor} = FakeEditor.start_link(nil)
      assert {:error, :no_buffer} = API.move_to(0, 0, editor)
    end
  end

  describe "insert/2" do
    test "inserts text at cursor" do
      buf = start_buffer("")
      editor = start_fake_editor(buf)

      assert :ok = API.insert("hello", editor)
      assert {:ok, "hello"} = API.content(editor)
    end

    test "inserts multi-character text" do
      buf = start_buffer("")
      editor = start_fake_editor(buf)

      API.insert("abc", editor)
      assert {:ok, "abc"} = API.content(editor)
    end

    test "inserts newlines" do
      buf = start_buffer("")
      editor = start_fake_editor(buf)

      API.insert("a\nb", editor)
      assert {:ok, "a\nb"} = API.content(editor)
    end

    test "returns error when no buffer" do
      {:ok, editor} = FakeEditor.start_link(nil)
      assert {:error, :no_buffer} = API.insert("text", editor)
    end
  end

  describe "line_count/1" do
    test "returns number of lines" do
      buf = start_buffer("line1\nline2\nline3")
      editor = start_fake_editor(buf)

      assert {:ok, 3} = API.line_count(editor)
    end

    test "single line buffer returns 1" do
      buf = start_buffer("hello")
      editor = start_fake_editor(buf)

      assert {:ok, 1} = API.line_count(editor)
    end
  end

  # ── Editor-level function tests ──────────────────────────────────────────────

  describe "mode/1" do
    test "returns current mode" do
      buf = start_buffer()
      editor = start_fake_editor(buf)

      assert :normal = API.mode(editor)
    end
  end

  describe "message/2" do
    test "logs message and returns :ok" do
      buf = start_buffer()
      editor = start_fake_editor(buf)

      assert :ok = API.message("test message", editor)

      messages = GenServer.call(editor, :get_messages)
      assert messages == ["test message"]
    end
  end

  describe "execute/2" do
    test "executes command and returns :ok" do
      buf = start_buffer()
      editor = start_fake_editor(buf)

      assert :ok = API.execute(:undo, editor)
    end
  end

  describe "open/2" do
    test "opens a file and returns :ok" do
      buf = start_buffer()
      editor = start_fake_editor(buf)

      assert :ok = API.open("lib/minga.ex", editor)
    end
  end

  describe "save/1" do
    test "returns error when no buffer" do
      {:ok, editor} = FakeEditor.start_link(nil)
      assert {:error, :no_buffer} = API.save(editor)
    end
  end
end
