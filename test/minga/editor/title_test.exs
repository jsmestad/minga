defmodule Minga.Editor.TitleTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Title
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode

  defp state_with(opts \\ []) do
    path = Keyword.get(opts, :path, "/home/user/project/lib/editor.ex")
    dirty = Keyword.get(opts, :dirty, false)
    name = Keyword.get(opts, :name, nil)
    mode = Keyword.get(opts, :mode, :normal)

    {:ok, buf} =
      BufferServer.start_link(
        content: "hello",
        file_path: path,
        buffer_name: name
      )

    if dirty do
      BufferServer.insert_char(buf, "x")
    end

    %{
      buffers: %{active: buf},
      mode: mode
    }
  end

  describe "format/2" do
    test "default format produces expected title" do
      state = state_with()
      result = Title.format(state, "{filename} {dirty}({directory}) - Minga")
      assert result == "editor.ex (lib) - Minga"
    end

    test "dirty buffer shows [+] indicator" do
      state = state_with(dirty: true)
      result = Title.format(state, "{filename} {dirty}- Minga")
      assert result == "editor.ex [+] - Minga"
    end

    test "clean buffer has no dirty indicator" do
      state = state_with(dirty: false)
      result = Title.format(state, "{filename} {dirty}- Minga")
      assert result == "editor.ex - Minga"
    end

    test "filepath placeholder shows full path" do
      state = state_with(path: "/home/user/project/lib/editor.ex")
      result = Title.format(state, "{filepath}")
      assert result == "/home/user/project/lib/editor.ex"
    end

    test "directory placeholder shows parent dir" do
      state = state_with(path: "/home/user/project/lib/editor.ex")
      result = Title.format(state, "{directory}")
      assert result == "lib"
    end

    test "mode placeholder shows current mode" do
      state = state_with(mode: :insert)
      result = Title.format(state, "{filename} [{mode}]")
      assert result == "editor.ex [INSERT]"
    end

    test "buffer with no path uses scratch name" do
      state = state_with(path: nil)
      result = Title.format(state, "{filename} - Minga")
      assert result == "*scratch* - Minga"
    end

    test "named buffer uses buffer name" do
      state = state_with(path: nil, name: "*messages*")
      result = Title.format(state, "{bufname} - Minga")
      assert result == "*messages* - Minga"
    end

    test "custom format with only filename" do
      state = state_with()
      result = Title.format(state, "{filename}")
      assert result == "editor.ex"
    end

    test "no active buffer falls back to scratch" do
      state = %{buffers: %{active: nil}, mode: :normal}
      result = Title.format(state, "{filename} - Minga")
      assert result == "*scratch* - Minga"
    end
  end

  describe "format/2 with EditorState (content-aware)" do
    test "agent chat window shows Agent in title, not *scratch*" do
      {:ok, agent_buf} = BufferServer.start_link(content: "")
      {:ok, scratch_buf} = BufferServer.start_link(content: "scratch")
      agent_window = Window.new_agent_chat(1, agent_buf, 24, 80)

      state = %EditorState{
        port_manager: self(),
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state(),
        buffers: %Buffers{active: scratch_buf, list: []},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => agent_window},
          active: 1,
          next_id: 2
        },
        focus_stack: Minga.Input.default_stack()
      }

      result = Title.format(state, "{filename} ({directory}) - Minga")

      assert String.contains?(result, "Agent")

      refute String.contains?(result, "*scratch*"),
             "agent-mode title must not show *scratch*"
    end

    test "buffer window shows filename in title" do
      {:ok, buf} =
        BufferServer.start_link(
          content: "hello",
          file_path: "/home/user/project/lib/editor.ex"
        )

      window = Window.new(1, buf, 24, 80)

      state = %EditorState{
        port_manager: self(),
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state(),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => window},
          active: 1,
          next_id: 2
        },
        focus_stack: Minga.Input.default_stack()
      }

      result = Title.format(state, "{filename} ({directory}) - Minga")

      assert result == "editor.ex (lib) - Minga"
    end
  end
end
