defmodule Minga.Editor.Commands.Testing do
  @moduledoc """
  Test runner commands: run tests for file, at point, all, rerun, and
  view output.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec test_file(state()) :: state()
  def test_file(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    run_test_command(state, buf, :file)
  end

  def test_file(state), do: EditorState.set_status(state, "No active buffer")

  @spec test_all(state()) :: state()
  def test_all(state), do: run_test_command(state, nil, :all)

  @spec test_at_point(state()) :: state()
  def test_at_point(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    run_test_command(state, buf, :at_point)
  end

  def test_at_point(state), do: EditorState.set_status(state, "No active buffer")

  @spec test_rerun(state()) :: state()
  def test_rerun(%{last_test_command: {command, project_root}} = state) do
    Minga.CommandOutput.run("*test*", command, cwd: project_root)
    show_output(state)
  end

  def test_rerun(state), do: EditorState.set_status(state, "No previous test command")

  @spec test_output(state()) :: state()
  def test_output(state), do: show_output(state)

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec run_test_command(state(), pid() | nil, :file | :all | :at_point) :: state()
  defp run_test_command(state, buf, kind) do
    filetype = if buf, do: Buffer.filetype(buf), else: detect_project_filetype()
    project_root = Minga.Project.root() || "."

    case Minga.Project.detect_test_runner(filetype, project_root) do
      {:ok, runner} ->
        command = build_test_command(runner, buf, kind)
        execute_test(state, command, project_root)

      :none ->
        EditorState.set_status(state, "No test runner configured for #{filetype}")
    end
  end

  @spec build_test_command(
          Minga.Project.TestRunner.Runner.t(),
          pid() | nil,
          :file | :all | :at_point
        ) ::
          String.t() | nil
  defp build_test_command(runner, _buf, :all) do
    Minga.Project.test_all_command(runner)
  end

  defp build_test_command(runner, buf, :file) when is_pid(buf) do
    case Buffer.file_path(buf) do
      nil -> nil
      path -> Minga.Project.test_file_command(runner, path)
    end
  end

  defp build_test_command(runner, buf, :at_point) when is_pid(buf) do
    file_path = Buffer.file_path(buf)
    {cursor_line, _col} = Buffer.cursor(buf)

    if file_path do
      Minga.Project.test_at_point_command(runner, file_path, cursor_line + 1)
    else
      nil
    end
  end

  defp build_test_command(_runner, _buf, _kind), do: nil

  @spec execute_test(state(), String.t() | nil, String.t()) :: state()
  defp execute_test(state, nil, _project_root) do
    EditorState.set_status(state, "Cannot determine test command")
  end

  defp execute_test(state, command, project_root) do
    state = %{state | last_test_command: {command, project_root}}
    Minga.CommandOutput.run("*test*", command, cwd: project_root)
    show_output(state)
  end

  @spec show_output(state()) :: state()
  defp show_output(state) do
    case Minga.CommandOutput.buffer("*test*") do
      nil ->
        EditorState.set_status(state, "No test output")

      buf_pid ->
        BufferManagement.execute(state, {:open_special_buffer, "*test*", buf_pid})
    end
  end

  @spec detect_project_filetype() :: atom()
  defp detect_project_filetype do
    Minga.Project.TestRunner.detect_project_filetype(Minga.Project.root() || ".")
  end

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :test_file,
        description: "Run tests for current file",
        requires_buffer: true,
        execute: &test_file/1
      },
      %Minga.Command{
        name: :test_all,
        description: "Run all tests",
        requires_buffer: true,
        execute: &test_all/1
      },
      %Minga.Command{
        name: :test_at_point,
        description: "Run test at cursor",
        requires_buffer: true,
        execute: &test_at_point/1
      },
      %Minga.Command{
        name: :test_rerun,
        description: "Rerun last test",
        requires_buffer: true,
        execute: &test_rerun/1
      },
      %Minga.Command{
        name: :test_output,
        description: "Show test output",
        requires_buffer: true,
        execute: &test_output/1
      }
    ]
  end
end
