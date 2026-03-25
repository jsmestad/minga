defmodule Minga.Project.TestRunner do
  @moduledoc """
  Detects test frameworks and generates test commands for each language.

  Detection (`detect/2`) examines the filesystem for framework markers
  (files, directories, package.json entries). Command generation
  (`file_command/2`, `all_command/1`, `at_point_command/3`) is pure:
  given a `Runner` struct, it returns the shell command string with
  properly escaped file paths.

  ## Supported Frameworks

  | Language | Frameworks |
  |---|---|
  | Elixir | ExUnit (`mix test`) |
  | Ruby | RSpec, Minitest |
  | TypeScript/JS | Vitest, Jest, npm test |
  | C/C++ | CTest, Make |
  | Swift | Swift Package Manager |
  """

  defmodule Runner do
    @moduledoc "Describes a detected test framework and its base command."

    @type t :: %__MODULE__{
            framework: atom(),
            filetype: atom(),
            base_command: String.t()
          }

    @enforce_keys [:framework, :filetype, :base_command]
    defstruct [:framework, :filetype, :base_command]
  end

  @type runner :: Runner.t()

  @doc """
  Detects the test framework for the given filetype and project root.

  Returns `{:ok, runner}` with the detected framework, or `:none` if
  no test framework could be detected.
  """
  @spec detect(atom(), String.t()) :: {:ok, runner()} | :none
  def detect(filetype, project_root) when is_atom(filetype) and is_binary(project_root) do
    do_detect(filetype, project_root)
  end

  @doc """
  Returns the shell command to run tests for a specific file.
  """
  @spec file_command(runner(), String.t()) :: String.t()
  def file_command(runner, file_path) when is_map(runner) and is_binary(file_path) do
    build_file_command(runner, file_path)
  end

  @doc """
  Returns the shell command to run all tests in the project.
  """
  @spec all_command(runner()) :: String.t()
  def all_command(runner) when is_map(runner) do
    runner.base_command
  end

  @doc """
  Returns the shell command to run a test at a specific line, or nil
  if the framework doesn't support line-specific test execution.
  """
  @spec at_point_command(runner(), String.t(), non_neg_integer()) :: String.t() | nil
  def at_point_command(runner, file_path, line)
      when is_map(runner) and is_binary(file_path) and is_integer(line) do
    build_at_point_command(runner, file_path, line)
  end

  # ── Elixir ─────────────────────────────────────────────────────────────────

  @spec do_detect(atom(), String.t()) :: {:ok, runner()} | :none
  defp do_detect(:elixir, project_root) do
    if File.exists?(Path.join(project_root, "mix.exs")) do
      {:ok, %Runner{framework: :exunit, filetype: :elixir, base_command: "mix test"}}
    else
      :none
    end
  end

  # ── Ruby ───────────────────────────────────────────────────────────────────

  defp do_detect(:ruby, project_root) do
    detect_ruby_framework(project_root)
  end

  # ── TypeScript / JavaScript ────────────────────────────────────────────────

  defp do_detect(filetype, project_root)
       when filetype in [:typescript, :typescript_react, :javascript, :javascript_react] do
    detect_ts_framework(filetype, project_root)
  end

  # ── C / C++ ────────────────────────────────────────────────────────────────

  defp do_detect(filetype, project_root) when filetype in [:c, :cpp] do
    detect_c_framework(filetype, project_root)
  end

  # ── Swift ──────────────────────────────────────────────────────────────────

  defp do_detect(:swift, project_root) do
    if File.exists?(Path.join(project_root, "Package.swift")) do
      {:ok, %Runner{framework: :swift_pm, filetype: :swift, base_command: "swift test"}}
    else
      :none
    end
  end

  defp do_detect(_filetype, _project_root), do: :none

  @doc """
  Guesses the project's primary filetype from root markers.

  Used as a fallback when `SPC m t a` is invoked without an active
  buffer that has a known filetype.
  """
  @spec detect_project_filetype(String.t()) :: atom()
  def detect_project_filetype(project_root) when is_binary(project_root) do
    do_detect_project_filetype(project_root)
  end

  @spec do_detect_project_filetype(String.t()) :: atom()
  defp do_detect_project_filetype(root) do
    markers = [
      {"mix.exs", :elixir},
      {"Gemfile", :ruby},
      {"package.json", :typescript},
      {"Package.swift", :swift},
      {"CMakeLists.txt", :c},
      {"Makefile", :c}
    ]

    Enum.find_value(markers, :text, fn {file, filetype} ->
      if File.exists?(Path.join(root, file)), do: filetype
    end)
  end

  # ── File commands ──────────────────────────────────────────────────────────

  @spec build_file_command(runner(), String.t()) :: String.t()
  defp build_file_command(%Runner{framework: :exunit}, file_path) do
    "mix test #{shell_escape(file_path)}"
  end

  defp build_file_command(%Runner{framework: :rspec}, file_path) do
    "bundle exec rspec #{shell_escape(file_path)}"
  end

  defp build_file_command(%Runner{framework: :minitest}, file_path) do
    "bundle exec ruby -Itest #{shell_escape(file_path)}"
  end

  defp build_file_command(%Runner{framework: :vitest}, file_path) do
    "npx vitest run #{shell_escape(file_path)}"
  end

  defp build_file_command(%Runner{framework: :jest}, file_path) do
    "npx jest #{shell_escape(file_path)}"
  end

  defp build_file_command(%Runner{framework: :npm_test}, _file_path) do
    "npm test"
  end

  defp build_file_command(%Runner{framework: :ctest}, _file_path) do
    "ctest --test-dir build"
  end

  defp build_file_command(%Runner{framework: :make_test}, _file_path) do
    "make test"
  end

  defp build_file_command(%Runner{framework: :swift_pm}, file_path) do
    # Extract module name from file path for filtering
    module = file_path |> Path.basename(".swift") |> String.replace("Tests", "")
    "swift test --filter #{shell_escape(module)}"
  end

  # ── At-point commands ──────────────────────────────────────────────────────

  @spec build_at_point_command(runner(), String.t(), non_neg_integer()) :: String.t() | nil
  defp build_at_point_command(%Runner{framework: :exunit}, file_path, line) do
    "mix test #{shell_escape(file_path)}:#{line}"
  end

  defp build_at_point_command(%Runner{framework: :rspec}, file_path, line) do
    "bundle exec rspec #{shell_escape(file_path)}:#{line}"
  end

  # Minitest doesn't support line-specific execution
  defp build_at_point_command(%Runner{framework: :minitest}, _file_path, _line), do: nil

  # JS/TS test runners don't have standard line-specific execution
  defp build_at_point_command(%Runner{framework: fw}, _file_path, _line)
       when fw in [:vitest, :jest, :npm_test],
       do: nil

  # C/C++ build systems don't support line-specific execution
  defp build_at_point_command(%Runner{framework: fw}, _file_path, _line)
       when fw in [:ctest, :make_test],
       do: nil

  # Swift doesn't support line-specific execution
  defp build_at_point_command(%Runner{framework: :swift_pm}, _file_path, _line), do: nil

  # ── Ruby detection ─────────────────────────────────────────────────────────

  @spec detect_ruby_framework(String.t()) :: {:ok, runner()} | :none
  defp detect_ruby_framework(project_root) do
    has_spec_dir = File.dir?(Path.join(project_root, "spec"))
    has_test_dir = File.dir?(Path.join(project_root, "test"))

    case {has_spec_dir, has_test_dir} do
      {true, _} ->
        {:ok, %Runner{framework: :rspec, filetype: :ruby, base_command: "bundle exec rspec"}}

      {false, true} ->
        {:ok,
         %Runner{framework: :minitest, filetype: :ruby, base_command: "bundle exec ruby -Itest"}}

      {false, false} ->
        :none
    end
  end

  # ── TypeScript detection ───────────────────────────────────────────────────

  @spec detect_ts_framework(atom(), String.t()) :: {:ok, runner()} | :none
  defp detect_ts_framework(filetype, project_root) do
    pkg_json_path = Path.join(project_root, "package.json")

    if File.exists?(pkg_json_path) do
      detect_ts_from_package_json(filetype, pkg_json_path)
    else
      :none
    end
  end

  @spec detect_ts_from_package_json(atom(), String.t()) :: {:ok, runner()} | :none
  defp detect_ts_from_package_json(filetype, pkg_json_path) do
    case File.read(pkg_json_path) do
      {:ok, contents} ->
        detect_ts_from_contents(filetype, contents)

      {:error, _} ->
        :none
    end
  end

  @spec detect_ts_from_contents(atom(), String.t()) :: {:ok, runner()} | :none
  defp detect_ts_from_contents(filetype, contents) do
    has_vitest = String.contains?(contents, "\"vitest\"")
    has_jest = String.contains?(contents, "\"jest\"")
    has_test_script = String.contains?(contents, "\"test\"")

    case {has_vitest, has_jest, has_test_script} do
      {true, _, _} ->
        {:ok, %Runner{framework: :vitest, filetype: filetype, base_command: "npx vitest run"}}

      {false, true, _} ->
        {:ok, %Runner{framework: :jest, filetype: filetype, base_command: "npx jest"}}

      {false, false, true} ->
        {:ok, %Runner{framework: :npm_test, filetype: filetype, base_command: "npm test"}}

      {false, false, false} ->
        :none
    end
  end

  # ── C/C++ detection ────────────────────────────────────────────────────────

  @spec detect_c_framework(atom(), String.t()) :: {:ok, runner()} | :none
  defp detect_c_framework(filetype, project_root) do
    has_cmake = File.exists?(Path.join(project_root, "CMakeLists.txt"))
    has_makefile = File.exists?(Path.join(project_root, "Makefile"))

    case {has_cmake, has_makefile} do
      {true, _} ->
        {:ok,
         %Runner{framework: :ctest, filetype: filetype, base_command: "ctest --test-dir build"}}

      {false, true} ->
        {:ok, %Runner{framework: :make_test, filetype: filetype, base_command: "make test"}}

      {false, false} ->
        :none
    end
  end

  # ── Shell escaping ─────────────────────────────────────────────────────────

  @doc false
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
