defmodule Minga.Test.NeovimOracle do
  @moduledoc """
  Runs vim-grammar conformance scenarios against Neovim and returns the captured editor state.

  The oracle receives plain scenario data from Elixir, writes it to a temporary JSON file, runs `nvim --headless --clean -l test/conformance/oracle.lua`, and parses one JSON result per line. Scenario authors should not need to edit Lua when adding coverage. Add a scenario map in `test/conformance/*_test.exs` with `:name`, `:type`, `:content`, `:cursor`, `:keys`, and `:compare`. The `:compare` field can be a single target (`:content`, `:cursor`, `:mode`, `:register`, or `:register_type`), `:both`, or a list of targets. Tagged known divergences carry a `:known_divergence` map with the exact failing fields, current Minga actual values for those fields, and a scenario-specific reason.
  """

  @type cursor :: %{required(:line) => non_neg_integer(), required(:col) => non_neg_integer()}
  @type scenario_type :: :motion | :operator | :text_object
  @type compare_field :: :content | :cursor | :mode | :register | :register_type
  @type compare_target :: compare_field() | :both | [compare_field()]
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
          required(:keys) => String.t(),
          required(:compare) => compare_target(),
          optional(:tags) => [atom()],
          optional(:known_divergence) => divergence()
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
  defp stringify_scenario(scenario) do
    %{
      name: scenario.name,
      type: Atom.to_string(scenario.type),
      content: scenario.content,
      cursor: scenario.cursor,
      keys: scenario.keys,
      compare: stringify_compare(scenario.compare),
      tags: Enum.map(Map.get(scenario, :tags, []), &Atom.to_string/1),
      known_divergence: stringify_known_divergence(Map.get(scenario, :known_divergence))
    }
  end

  @spec stringify_compare(compare_target()) :: String.t() | [String.t()]
  defp stringify_compare(:both), do: "both"
  defp stringify_compare(compare) when is_atom(compare), do: Atom.to_string(compare)
  defp stringify_compare(compare) when is_list(compare), do: Enum.map(compare, &Atom.to_string/1)

  @spec stringify_known_divergence(divergence() | nil) :: map() | nil
  defp stringify_known_divergence(nil), do: nil

  defp stringify_known_divergence(%{} = divergence) do
    %{
      reason: divergence.reason,
      failures: Enum.map(divergence.failures, &Atom.to_string/1),
      actual: stringify_actual(divergence.actual)
    }
  end

  @spec stringify_actual(map()) :: map()
  defp stringify_actual(actual) do
    Enum.into(actual, %{}, fn {key, value} -> {Atom.to_string(key), value} end)
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
  defp normalize_result(result) do
    result
    |> Enum.map(fn {key, value} -> {result_key(key), value} end)
    |> Map.new()
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
  defp result_key("error"), do: :error
end
