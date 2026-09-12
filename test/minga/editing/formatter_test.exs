defmodule Minga.Editing.FormatterTest do
  # Runs formatter commands as real OS processes and mutates the global Options server.
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias Minga.Config.Options
  alias Minga.Editing.Formatter
  alias Minga.Editing.Formatter.Failure
  alias Minga.Editing.Formatter.Result

  @fixture Path.expand("../../fixtures/formatter_stream_fixture", __DIR__)

  setup do
    case Options.start_link() do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        Options.reset()
        Options.set(:clipboard, :none)
    end

    on_exit(fn ->
      Options.reset()
      Options.set(:clipboard, :none)
    end)

    :ok
  end

  describe "format/2" do
    test "passes content through a command and returns output" do
      assert {:ok, %Result{content: "hello\n", diagnostics: ""}} =
               Formatter.format("hello\n", "cat")
    end

    test "returns error for non-zero exit code" do
      assert {:error, %Failure{exit_code: 1, stdout: "", stderr: ""}} =
               Formatter.format("input", "false")
    end

    test "returns error for nonexistent command" do
      assert {:error, %Failure{exit_code: 127, stdout: "", stderr: detail}} =
               Formatter.format("input", "nonexistent_command_xyz_123")

      assert detail =~ "not found"
    end

    test "handles multi-argument commands" do
      assert {:ok, %Result{content: output, diagnostics: ""}} =
               Formatter.format("hello world\n", "tr a-z A-Z")

      assert output == "HELLO WORLD\n"
    end

    test "keeps successful stdout and stderr separate in both write orders" do
      for order <- ["stdout-first", "stderr-first"] do
        assert {:ok,
                %Result{
                  content: "formatted:original\n",
                  diagnostics: "formatter warning: optional setting ignored\n"
                }} = Formatter.format("original\n", fixture_command(order, "success"))
      end
    end

    test "redirects every command in a compound formatter into its corresponding stream" do
      command = "printf 'prefix:'; printf 'compound warning\\n' >&2; cat"

      assert {:ok, %Result{content: "prefix:original\n", diagnostics: "compound warning\n"}} =
               Formatter.format("original\n", command)
    end

    test "preserves empty successful stdout as the formatted document" do
      assert {:ok, %Result{content: "", diagnostics: "formatter warning: empty result\n"}} =
               Formatter.format("original\n", fixture_command("stderr-first", "empty"))
    end

    test "uses separate diagnostics for a failing exit" do
      assert {:error, %Failure{} = failure} =
               Formatter.format("original\n", fixture_command("stdout-first", "failure"))

      assert failure.exit_code == 7
      assert failure.stdout == "partial formatter output\n"
      assert failure.stderr == "formatter failed: invalid source\n"

      assert Failure.message(failure) ==
               "Formatter exited with code 7: formatter failed: invalid source\nstdout: partial formatter output"
    end

    test "drains stdout and stderr larger than a pipe buffer in both write orders" do
      for order <- ["stdout-first", "stderr-first"] do
        assert {:ok, %Result{} = result} =
                 Formatter.format("original\n", fixture_command(order, "large"))

        assert result.content == String.duplicate("o", 131_072)
        assert result.diagnostics == String.duplicate("e", 131_072)
      end
    end

    test "removes its temporary workspace after success and failure" do
      before = formatter_workspaces()

      assert {:ok, %Result{}} =
               Formatter.format("original\n", fixture_command("stdout-first", "success"))

      assert formatter_workspaces() == before

      assert {:error, %Failure{}} =
               Formatter.format("original\n", fixture_command("stderr-first", "failure"))

      assert formatter_workspaces() == before
    end

    test "removes its temporary workspace when the caller is brutally canceled" do
      before = formatter_workspaces()

      task =
        Task.async(fn ->
          Formatter.format("original\n", System.find_executable("sleep") <> " 30")
        end)

      assert {:ok, workspaces} = eventually(fn -> new_workspaces(before) end)
      assert workspaces != []

      Task.shutdown(task, :brutal_kill)

      assert {:ok, []} = eventually(fn -> removed_workspaces(before) end)
    end
  end

  describe "resolve_formatter/2" do
    test "replaces {file} placeholder with file path" do
      spec = Formatter.resolve_formatter(:go, "main.go")
      assert spec == "gofmt"
    end

    test "user config overrides default formatter" do
      Options.set_for_filetype(:elixir, :formatter, "custom-fmt {file}")
      spec = Formatter.resolve_formatter(:elixir, "test.ex")
      assert spec == "custom-fmt test.ex"
    end

    test "user config with no {file} placeholder is returned as-is" do
      Options.set_for_filetype(:ruby, :formatter, "rubocop --stdin")
      spec = Formatter.resolve_formatter(:ruby, "test.rb")
      assert spec == "rubocop --stdin"
    end
  end

  describe "default_formatters/0" do
  end

  describe "apply_save_transforms/2" do
    test "trims trailing whitespace when enabled" do
      Options.set_for_filetype(:elixir, :trim_trailing_whitespace, true)

      input = "hello   \nworld  \n"
      result = Formatter.apply_save_transforms(input, :elixir)
      assert result == "hello\nworld\n"
    end

    test "inserts final newline when enabled and missing" do
      Options.set_for_filetype(:elixir, :insert_final_newline, true)

      result = Formatter.apply_save_transforms("hello", :elixir)
      assert result == "hello\n"
    end

    test "does not double final newline when already present" do
      Options.set_for_filetype(:elixir, :insert_final_newline, true)

      result = Formatter.apply_save_transforms("hello\n", :elixir)
      assert result == "hello\n"
    end

    test "both transforms can apply together" do
      Options.set_for_filetype(:go, :trim_trailing_whitespace, true)
      Options.set_for_filetype(:go, :insert_final_newline, true)

      input = "func main() {   \n}  "
      result = Formatter.apply_save_transforms(input, :go)
      assert result == "func main() {\n}\n"
    end
  end

  @spec fixture_command(String.t(), String.t()) :: String.t()
  defp fixture_command(order, outcome) do
    System.find_executable("elixir") <>
      " " <> Enum.map_join([@fixture, order, outcome], " ", &shell_escape/1)
  end

  @spec shell_escape(String.t()) :: String.t()
  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @spec formatter_workspaces() :: MapSet.t(String.t())
  defp formatter_workspaces do
    System.tmp_dir!()
    |> Path.join("minga_fmt_*")
    |> Path.wildcard()
    |> MapSet.new()
  end

  @spec new_workspaces(MapSet.t(String.t())) :: {:ok, [String.t()]} | :retry
  defp new_workspaces(before) do
    workspaces = formatter_workspaces() |> MapSet.difference(before) |> MapSet.to_list()
    if workspaces == [], do: :retry, else: {:ok, workspaces}
  end

  @spec removed_workspaces(MapSet.t(String.t())) :: {:ok, []} | :retry
  defp removed_workspaces(before) do
    case formatter_workspaces() |> MapSet.difference(before) |> MapSet.to_list() do
      [] -> {:ok, []}
      _workspaces -> :retry
    end
  end

  @spec eventually((-> {:ok, term()} | :retry), non_neg_integer()) :: {:ok, term()} | :timeout
  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: :timeout

  defp eventually(fun, attempts) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      :retry ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end
    end
  end
end
