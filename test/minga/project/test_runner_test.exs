defmodule Minga.Project.TestRunnerTest do
  use ExUnit.Case, async: true

  alias Minga.Project.TestRunner
  alias Minga.Project.TestRunner.Runner

  # Creates a temp project directory with the given files/dirs
  defp with_project(files, dirs, fun) do
    tmp = Path.join(System.tmp_dir!(), "minga_test_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      for dir <- dirs do
        File.mkdir_p!(Path.join(tmp, dir))
      end

      for file <- files do
        path = Path.join(tmp, file)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "")
      end

      fun.(tmp)
    after
      File.rm_rf!(tmp)
    end
  end

  # ── Detection ────────────────────────────────────────────────────────────

  describe "detect/2 Elixir" do
    test "detects ExUnit when mix.exs exists" do
      with_project(["mix.exs"], [], fn root ->
        assert {:ok, %{framework: :exunit}} = TestRunner.detect(:elixir, root)
      end)
    end

    test "returns :none when mix.exs is missing" do
      with_project([], [], fn root ->
        assert :none = TestRunner.detect(:elixir, root)
      end)
    end
  end

  describe "detect/2 Ruby" do
    test "detects RSpec when spec/ directory exists" do
      with_project([], ["spec"], fn root ->
        assert {:ok, %{framework: :rspec}} = TestRunner.detect(:ruby, root)
      end)
    end

    test "detects Minitest when test/ directory exists (no spec/)" do
      with_project([], ["test"], fn root ->
        assert {:ok, %{framework: :minitest}} = TestRunner.detect(:ruby, root)
      end)
    end

    test "prefers RSpec when both spec/ and test/ exist" do
      with_project([], ["spec", "test"], fn root ->
        assert {:ok, %{framework: :rspec}} = TestRunner.detect(:ruby, root)
      end)
    end

    test "returns :none when neither spec/ nor test/ exist" do
      with_project([], [], fn root ->
        assert :none = TestRunner.detect(:ruby, root)
      end)
    end
  end

  describe "detect/2 TypeScript" do
    test "detects Vitest when package.json mentions vitest" do
      with_project([], [], fn root ->
        File.write!(Path.join(root, "package.json"), ~s({"devDependencies": {"vitest": "^1.0"}}))
        assert {:ok, %{framework: :vitest}} = TestRunner.detect(:typescript, root)
      end)
    end

    test "detects Jest when package.json mentions jest (no vitest)" do
      with_project([], [], fn root ->
        File.write!(Path.join(root, "package.json"), ~s({"devDependencies": {"jest": "^29.0"}}))
        assert {:ok, %{framework: :jest}} = TestRunner.detect(:typescript, root)
      end)
    end

    test "detects npm test when package.json has test script (no vitest/jest)" do
      with_project([], [], fn root ->
        File.write!(Path.join(root, "package.json"), ~s({"scripts": {"test": "mocha"}}))
        assert {:ok, %{framework: :npm_test}} = TestRunner.detect(:typescript, root)
      end)
    end

    test "prefers Vitest over Jest" do
      with_project([], [], fn root ->
        File.write!(
          Path.join(root, "package.json"),
          ~s({"devDependencies": {"vitest": "^1.0", "jest": "^29.0"}})
        )

        assert {:ok, %{framework: :vitest}} = TestRunner.detect(:typescript, root)
      end)
    end

    test "returns :none when package.json is missing" do
      with_project([], [], fn root ->
        assert :none = TestRunner.detect(:typescript, root)
      end)
    end

    test "works for javascript filetype" do
      with_project([], [], fn root ->
        File.write!(Path.join(root, "package.json"), ~s({"devDependencies": {"jest": "^29.0"}}))
        assert {:ok, %{framework: :jest}} = TestRunner.detect(:javascript, root)
      end)
    end

    test "works for typescript_react filetype" do
      with_project([], [], fn root ->
        File.write!(Path.join(root, "package.json"), ~s({"devDependencies": {"vitest": "^1.0"}}))
        assert {:ok, %{framework: :vitest}} = TestRunner.detect(:typescript_react, root)
      end)
    end
  end

  describe "detect/2 C/C++" do
    test "detects CTest when CMakeLists.txt exists" do
      with_project(["CMakeLists.txt"], [], fn root ->
        assert {:ok, %{framework: :ctest}} = TestRunner.detect(:c, root)
      end)
    end

    test "detects Make when Makefile exists (no CMakeLists.txt)" do
      with_project(["Makefile"], [], fn root ->
        assert {:ok, %{framework: :make_test}} = TestRunner.detect(:c, root)
      end)
    end

    test "prefers CTest over Make" do
      with_project(["CMakeLists.txt", "Makefile"], [], fn root ->
        assert {:ok, %{framework: :ctest}} = TestRunner.detect(:c, root)
      end)
    end

    test "works for cpp filetype" do
      with_project(["CMakeLists.txt"], [], fn root ->
        assert {:ok, %{framework: :ctest}} = TestRunner.detect(:cpp, root)
      end)
    end

    test "returns :none when neither exists" do
      with_project([], [], fn root ->
        assert :none = TestRunner.detect(:c, root)
      end)
    end
  end

  describe "detect/2 Swift" do
    test "detects Swift PM when Package.swift exists" do
      with_project(["Package.swift"], [], fn root ->
        assert {:ok, %{framework: :swift_pm}} = TestRunner.detect(:swift, root)
      end)
    end

    test "returns :none when Package.swift is missing" do
      with_project([], [], fn root ->
        assert :none = TestRunner.detect(:swift, root)
      end)
    end
  end

  describe "detect/2 unsupported" do
    test "returns :none for unknown filetypes" do
      with_project([], [], fn root ->
        assert :none = TestRunner.detect(:text, root)
        assert :none = TestRunner.detect(:markdown, root)
      end)
    end
  end

  describe "detect_project_filetype/1" do
    test "detects Elixir project" do
      with_project(["mix.exs"], [], fn root ->
        assert TestRunner.detect_project_filetype(root) == :elixir
      end)
    end

    test "detects Ruby project" do
      with_project(["Gemfile"], [], fn root ->
        assert TestRunner.detect_project_filetype(root) == :ruby
      end)
    end

    test "detects TypeScript project" do
      with_project(["package.json"], [], fn root ->
        assert TestRunner.detect_project_filetype(root) == :typescript
      end)
    end

    test "detects Swift project" do
      with_project(["Package.swift"], [], fn root ->
        assert TestRunner.detect_project_filetype(root) == :swift
      end)
    end

    test "detects C project from CMakeLists.txt" do
      with_project(["CMakeLists.txt"], [], fn root ->
        assert TestRunner.detect_project_filetype(root) == :c
      end)
    end

    test "returns :text for unknown project" do
      with_project([], [], fn root ->
        assert TestRunner.detect_project_filetype(root) == :text
      end)
    end
  end

  # ── Command generation ─────────────────────────────────────────────────

  describe "file_command/2" do
    test "Elixir" do
      runner = %Runner{framework: :exunit, filetype: :elixir, base_command: "mix test"}
      assert TestRunner.file_command(runner, "test/my_test.exs") == "mix test 'test/my_test.exs'"
    end

    test "Ruby RSpec" do
      runner = %Runner{framework: :rspec, filetype: :ruby, base_command: "bundle exec rspec"}

      assert TestRunner.file_command(runner, "spec/models/user_spec.rb") ==
               "bundle exec rspec 'spec/models/user_spec.rb'"
    end

    test "Ruby Minitest" do
      runner = %Runner{
        framework: :minitest,
        filetype: :ruby,
        base_command: "bundle exec ruby -Itest"
      }

      assert TestRunner.file_command(runner, "test/models/user_test.rb") ==
               "bundle exec ruby -Itest 'test/models/user_test.rb'"
    end

    test "Vitest" do
      runner = %Runner{framework: :vitest, filetype: :typescript, base_command: "npx vitest run"}

      assert TestRunner.file_command(runner, "src/utils.test.ts") ==
               "npx vitest run 'src/utils.test.ts'"
    end

    test "Jest" do
      runner = %Runner{framework: :jest, filetype: :typescript, base_command: "npx jest"}

      assert TestRunner.file_command(runner, "src/utils.test.ts") ==
               "npx jest 'src/utils.test.ts'"
    end

    test "npm test ignores file path" do
      runner = %Runner{framework: :npm_test, filetype: :typescript, base_command: "npm test"}
      assert TestRunner.file_command(runner, "src/utils.test.ts") == "npm test"
    end

    test "CTest ignores file path" do
      runner = %Runner{framework: :ctest, filetype: :c, base_command: "ctest --test-dir build"}
      assert TestRunner.file_command(runner, "test/test_buffer.c") == "ctest --test-dir build"
    end

    test "Make test ignores file path" do
      runner = %Runner{framework: :make_test, filetype: :c, base_command: "make test"}
      assert TestRunner.file_command(runner, "test/test_buffer.c") == "make test"
    end

    test "Swift PM uses filter" do
      runner = %Runner{framework: :swift_pm, filetype: :swift, base_command: "swift test"}

      assert TestRunner.file_command(runner, "Tests/BufferTests.swift") ==
               "swift test --filter 'Buffer'"
    end

    test "escapes paths with spaces" do
      runner = %Runner{framework: :exunit, filetype: :elixir, base_command: "mix test"}
      assert TestRunner.file_command(runner, "test/my test.exs") == "mix test 'test/my test.exs'"
    end

    test "escapes paths with single quotes" do
      runner = %Runner{framework: :exunit, filetype: :elixir, base_command: "mix test"}

      assert TestRunner.file_command(runner, "test/it's_a_test.exs") ==
               "mix test 'test/it'\\''s_a_test.exs'"
    end
  end

  describe "all_command/1" do
    test "returns the base command for all frameworks" do
      assert TestRunner.all_command(%Runner{
               framework: :exunit,
               filetype: :elixir,
               base_command: "mix test"
             }) == "mix test"

      assert TestRunner.all_command(%Runner{
               framework: :rspec,
               filetype: :ruby,
               base_command: "bundle exec rspec"
             }) ==
               "bundle exec rspec"

      assert TestRunner.all_command(%Runner{
               framework: :vitest,
               filetype: :typescript,
               base_command: "npx vitest run"
             }) ==
               "npx vitest run"
    end
  end

  describe "at_point_command/3" do
    test "Elixir supports line-specific tests" do
      runner = %Runner{framework: :exunit, filetype: :elixir, base_command: "mix test"}

      assert TestRunner.at_point_command(runner, "test/my_test.exs", 42) ==
               "mix test 'test/my_test.exs':42"
    end

    test "Ruby RSpec supports line-specific tests" do
      runner = %Runner{framework: :rspec, filetype: :ruby, base_command: "bundle exec rspec"}

      assert TestRunner.at_point_command(runner, "spec/user_spec.rb", 10) ==
               "bundle exec rspec 'spec/user_spec.rb':10"
    end

    test "Minitest does not support line-specific tests" do
      runner = %Runner{
        framework: :minitest,
        filetype: :ruby,
        base_command: "bundle exec ruby -Itest"
      }

      assert TestRunner.at_point_command(runner, "test/user_test.rb", 10) == nil
    end

    test "Vitest does not support line-specific tests" do
      runner = %Runner{framework: :vitest, filetype: :typescript, base_command: "npx vitest run"}
      assert TestRunner.at_point_command(runner, "src/utils.test.ts", 10) == nil
    end

    test "Jest does not support line-specific tests" do
      runner = %Runner{framework: :jest, filetype: :typescript, base_command: "npx jest"}
      assert TestRunner.at_point_command(runner, "src/utils.test.ts", 10) == nil
    end

    test "CTest does not support line-specific tests" do
      runner = %Runner{framework: :ctest, filetype: :c, base_command: "ctest --test-dir build"}
      assert TestRunner.at_point_command(runner, "test/test_buffer.c", 10) == nil
    end

    test "Swift PM does not support line-specific tests" do
      runner = %Runner{framework: :swift_pm, filetype: :swift, base_command: "swift test"}
      assert TestRunner.at_point_command(runner, "Tests/BufferTests.swift", 10) == nil
    end
  end
end
