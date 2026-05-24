defmodule Minga.Test.NeovimOracle do
  @moduledoc """
  Runs vim conformance scenarios against Neovim and returns the captured editor state.

  The oracle receives plain scenario data from Elixir, writes it to a temporary JSON file, runs `nvim --headless --clean -l test/conformance/oracle.lua`, and parses one JSON result per line. Scenario authors should not need to edit Lua when adding coverage. Add a scenario map in `test/conformance/*_test.exs` with `:name`, `:type`, `:content`, `:cursor`, and `:compare`. Motion, operator, and text_object scenarios also include `:keys`. Window scenarios use `:commands` (Neovim ex-commands) and `:minga_keys` (Minga key sequences) instead. The `:compare` field accepts a single target (`:content`, `:cursor`, `:mode`, `:register`, `:register_type`), `:both`, `:window_state`, or a list of any combination. Tagged known divergences carry a `:known_divergence` map with the exact failing fields, current Minga actual values for those fields, and a scenario-specific reason.
  """

  @type cursor :: %{required(:line) => non_neg_integer(), required(:col) => non_neg_integer()}
  @type scenario_type :: :motion | :operator | :text_object | :search | :window | :mark
  @type compare_field :: :content | :cursor | :mode | :register | :register_type
  @type window_compare_field :: :window_count | :active_window | :cursors | :buffers | :layout
  @type compare_target ::
          compare_field() | :both | :window_state | [compare_field() | window_compare_field()]
  @type divergence :: %{
          required(:reason) => String.t(),
          required(:failures) => [compare_field()],
          required(:actual) => map()
        }
  @type scenario :: %{
          required(:name) => String.t(),
          required(:type) => scenario_type(),
          required(:content) => String.t(),
          required(:cursor) => cursor(),
          optional(:keys) => String.t(),
          optional(:commands) => [String.t()],
          optional(:minga_keys) => [String.t()],
          required(:compare) => compare_target(),
          optional(:tags) => [atom()],
          optional(:known_divergence) => divergence()
        }
  @type window_info :: %{
          required(:buffer_first_line) => String.t(),
          required(:line) => non_neg_integer(),
          required(:col) => non_neg_integer(),
          required(:active) => boolean(),
          required(:row_pos) => non_neg_integer(),
          required(:col_pos) => non_neg_integer(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer()
        }
  @type result :: %{
          required(:name) => String.t(),
          required(:ok) => boolean(),
          optional(:line) => non_neg_integer(),
          optional(:col) => non_neg_integer(),
          optional(:content) => String.t(),
          optional(:mode) => String.t(),
          optional(:register) => String.t(),
          optional(:register_type) => String.t(),
          optional(:window_count) => non_neg_integer(),
          optional(:windows) => [window_info()],
          optional(:error) => String.t()
        }
  @type error ::
          :nvim_not_found
          | {:nvim_failed, integer(), String.t()}
          | {:nvim_timeout, pos_integer()}
          | {:invalid_output, String.t()}

  @oracle_path Path.expand("../conformance/oracle.lua", __DIR__)

  @default_timeout 15_000

  @doc "Runs all scenarios in one Neovim invocation and returns results keyed by scenario name."
  @spec run([scenario()]) :: {:ok, %{String.t() => result()}} | {:error, error()}
  def run(scenarios) when is_list(scenarios) do
    run(scenarios, @default_timeout)
  end

  @doc false
  @spec run([scenario()], pos_integer()) :: {:ok, %{String.t() => result()}} | {:error, error()}
  def run(scenarios, timeout_ms) when is_list(scenarios) and timeout_ms > 0 do
    with {:ok, nvim} <- nvim_executable() do
      run_with_executable(nvim, scenarios, timeout_ms)
    end
  end

  @doc false
  @spec run_with_executable(String.t(), [scenario()], pos_integer()) ::
          {:ok, %{String.t() => result()}} | {:error, error()}
  def run_with_executable(nvim, scenarios, timeout_ms)
      when is_binary(nvim) and is_list(scenarios) and timeout_ms > 0 do
    with {:ok, path} <- write_scenarios(scenarios) do
      try do
        with {:ok, output} <- invoke_nvim(nvim, path, timeout_ms) do
          parse_output(output)
        end
      after
        File.rm(path)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @spec nvim_executable() :: {:ok, String.t()} | {:error, :nvim_not_found}
  defp nvim_executable do
    case System.find_executable("nvim") do
      nil -> {:error, :nvim_not_found}
      path -> {:ok, path}
    end
  end

  @spec write_scenarios([scenario()]) :: {:ok, String.t()} | {:error, File.posix()}
  defp write_scenarios(scenarios) do
    path =
      Path.join(System.tmp_dir!(), "minga-conformance-#{System.unique_integer([:positive])}.json")

    case File.write(path, JSON.encode!(Enum.map(scenarios, &stringify_scenario/1))) do
      :ok -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  @spec stringify_scenario(scenario()) :: map()
  defp stringify_scenario(%{type: :window} = scenario) do
    %{
      name: scenario.name,
      type: "window",
      content: scenario.content,
      cursor: scenario.cursor,
      commands: scenario.commands
    }
  end

  defp stringify_scenario(scenario) do
    base = %{
      name: scenario.name,
      type: Atom.to_string(scenario.type),
      content: scenario.content,
      cursor: scenario.cursor
    }

    base
    |> then(fn m -> if scenario[:keys], do: Map.put(m, :keys, scenario.keys), else: m end)
    |> then(fn m ->
      if scenario[:commands], do: Map.put(m, :commands, scenario.commands), else: m
    end)
  end

  @spec invoke_nvim(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()}
          | {:error, {:nvim_failed, integer(), String.t()}}
          | {:error, {:nvim_timeout, pos_integer()}}
  defp invoke_nvim(nvim, scenario_path, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {:ok,
           System.cmd(nvim, ["--headless", "--clean", "-l", @oracle_path, scenario_path],
             stderr_to_stdout: true
           )}
        catch
          kind, reason -> {:exit, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, {output, status}}} ->
        case status do
          0 -> {:ok, output}
          code -> {:error, {:nvim_failed, code, output}}
        end

      {:ok, {:exit, reason}} ->
        {:error, {:nvim_failed, -1, inspect(reason)}}

      {:exit, reason} ->
        {:error, {:nvim_failed, -1, inspect(reason)}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, {:nvim_timeout, timeout_ms}}
    end
  end

  @doc false
  @spec parse_output(String.t()) ::
          {:ok, %{String.t() => result()}} | {:error, {:invalid_output, String.t()}}
  def parse_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, &parse_result_line/2)
  end

  @doc false
  @spec parse_result_line(String.t(), {:ok, map()}) ::
          {:cont, {:ok, map()}} | {:halt, {:error, {:invalid_output, String.t()}}}
  def parse_result_line(line, {:ok, acc}) do
    case JSON.decode(line) do
      {:ok, %{"name" => name} = result} ->
        {:cont, {:ok, Map.put(acc, name, normalize_result(result))}}

      _ ->
        {:halt, {:error, {:invalid_output, line}}}
    end
  end

  @spec normalize_result(map()) :: result()
  defp normalize_result(%{"windows" => windows} = result) do
    result
    |> Map.delete("windows")
    |> Enum.map(fn {key, value} -> {result_key(key), value} end)
    |> Map.new()
    |> Map.put(:windows, Enum.map(windows, &normalize_window_info/1))
  end

  defp normalize_result(result) do
    result
    |> Enum.map(fn {key, value} -> {result_key(key), value} end)
    |> Map.new()
  end

  @spec normalize_window_info(map()) :: window_info()
  defp normalize_window_info(win) do
    %{
      buffer_first_line: Map.fetch!(win, "buffer_first_line"),
      line: Map.fetch!(win, "line"),
      col: Map.fetch!(win, "col"),
      active: Map.fetch!(win, "active"),
      row_pos: Map.fetch!(win, "row_pos"),
      col_pos: Map.fetch!(win, "col_pos"),
      width: Map.fetch!(win, "width"),
      height: Map.fetch!(win, "height")
    }
  end

  @spec result_key(String.t()) :: atom()
  defp result_key("name"), do: :name
  defp result_key("ok"), do: :ok
  defp result_key("line"), do: :line
  defp result_key("col"), do: :col
  defp result_key("content"), do: :content
  defp result_key("mode"), do: :mode
  defp result_key("register"), do: :register
  defp result_key("register_type"), do: :register_type
  defp result_key("window_count"), do: :window_count
  defp result_key("error"), do: :error
end
