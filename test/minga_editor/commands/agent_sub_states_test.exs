defmodule MingaEditor.Commands.AgentSubStatesTest do
  @moduledoc "Tests for agent prompt sub-state transitions."

  # async: false because these tests temporarily mutate the global Minga.Project singleton registration/state, change the cwd via File.cd!/2, and exercise project file discovery that touches filesystem and global process state.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Viewport

  @moduletag :tmp_dir

  describe "trigger_slash_completion/1" do
    test "does not reopen slash completion from a later prompt line" do
      state = prompt_state("/mo\nsecond line", {1, 0})
      state = AgentCommands.input_char(state, "/")
      state = AgentSubStates.trigger_slash_completion(state)

      assert AgentAccess.panel(state).mention_completion == nil
      assert BufferProcess.content(AgentAccess.panel(state).prompt_buffer) == "/mo\n/second line"
    end
  end

  describe "trigger_mention/1" do
    test "prefers cached project files over late disk files", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "cached_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "mix.exs"), "")
      File.write!(Path.join(root, "cached.ex"), "cached")
      File.write!(Path.join(root, "late.ex"), "late")

      with_project_state(root, ["cached.ex"], fn ->
        state = prompt_state("draft", {0, 0})
        state = AgentSubStates.trigger_mention(state)
        candidates = AgentAccess.panel(state).mention_completion.candidates

        assert "cached.ex" in candidates
        refute "late.ex" in candidates
      end)
    end

    test "falls back to disk files when the project cache is empty", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "empty_cache_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "mix.exs"), "")
      File.write!(Path.join(root, "disk.ex"), "disk")

      with_project_state(root, [], fn ->
        state = prompt_state("draft", {0, 0})
        state = AgentSubStates.trigger_mention(state)
        candidates = AgentAccess.panel(state).mention_completion.candidates

        assert "disk.ex" in candidates
      end)
    end

    test "falls back to cwd discovery when Project is unavailable", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project_unavailable_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      File.write!(Path.join(cwd, "cwd.ex"), "cwd")

      without_project(fn ->
        File.cd!(cwd, fn ->
          state = prompt_state("draft", {0, 0})
          state = AgentSubStates.trigger_mention(state)
          candidates = AgentAccess.panel(state).mention_completion.candidates

          assert "cwd.ex" in candidates
        end)
      end)
    end
  end

  defp prompt_state(text, cursor) do
    prompt_buffer =
      start_supervised!(
        Supervisor.child_spec(
          {BufferProcess, [content: text]},
          id: {:prompt_buffer, System.unique_integer([:positive])}
        )
      )

    BufferProcess.move_to(prompt_buffer, cursor)

    panel = %{UIState.new().panel | prompt_buffer: prompt_buffer, input_focused: true}
    agent_ui = %{UIState.new() | panel: panel}

    %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        agent_ui: agent_ui
      }
    }
  end

  defp with_project_state(root, cached_files, fun) when is_list(cached_files) do
    pid = project_pid!()
    original_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn state ->
      %{state | current_root: root, cached_files: cached_files, rebuilding?: false}
    end)

    try do
      fun.()
    after
      maybe_restore_project_registration(pid)
      :sys.replace_state(pid, fn _ -> original_state end)
    end
  end

  defp project_pid! do
    case Process.whereis(Minga.Project) do
      nil -> start_supervised!({Minga.Project, subscribe: false})
      pid -> pid
    end
  end

  defp maybe_restore_project_registration(pid) do
    if Process.whereis(Minga.Project) == nil do
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      true = Process.register(pid, Minga.Project)
    end
  end

  defp without_project(fun) do
    case Process.whereis(Minga.Project) do
      nil ->
        fun.()

      pid ->
        true = :erlang.unregister(Minga.Project)

        try do
          fun.()
        after
          # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
          true = Process.register(pid, Minga.Project)
        end
    end
  end
end
