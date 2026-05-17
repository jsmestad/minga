defmodule Minga.Test.ConformanceCase do
  @moduledoc """
  ExUnit case template for comparing Minga vim grammar scenarios against Neovim.

  A conformance test module defines `@scenarios`, exposes `scenarios/0`, and generates one test per data entry. `setup_all` batches those scenarios into one Neovim oracle invocation so adding a new scenario only requires adding data to the test module. Scenario data can compare `:content`, `:cursor`, `:mode`, `:register`, and `:register_type` in any combination, and tagged known divergences must declare the exact failing fields plus the current Minga result for those fields.
  """

  use ExUnit.CaseTemplate

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.EditorCase
  alias Minga.Test.NeovimOracle
  alias MingaEditor.State.Registers

  @type scenario :: NeovimOracle.scenario()
  @type oracle_results :: %{String.t() => NeovimOracle.result()} | :nvim_not_found
  @type minga_result :: %{
          required(:line) => non_neg_integer(),
          required(:col) => non_neg_integer(),
          required(:content) => String.t(),
          required(:mode) => String.t(),
          required(:register) => String.t(),
          required(:register_type) => String.t()
        }

  using do
    quote do
      import Minga.Test.ConformanceCase
      import Minga.Test.EditorCase

      @moduletag :conformance
      @moduletag timeout: 30_000

      if System.find_executable("nvim") == nil do
        @moduletag skip: "nvim not found; install Neovim to run vim conformance tests"
      end

      setup_all do
        case Minga.Test.NeovimOracle.run(__MODULE__.scenarios()) do
          {:ok, results} -> {:ok, oracle_results: results}
          {:error, :nvim_not_found} -> {:ok, oracle_results: :nvim_not_found}
          {:error, reason} -> flunk("Neovim oracle failed: #{inspect(reason)}")
        end
      end
    end
  end

  @doc "Runs one scenario in Minga and compares it with the cached Neovim oracle result."
  @spec assert_conforms(scenario(), oracle_results()) :: :ok
  def assert_conforms(_scenario, :nvim_not_found), do: :ok

  def assert_conforms(scenario, oracle_results) when is_map(oracle_results) do
    expected = Map.fetch!(oracle_results, scenario.name)

    case expected.ok do
      true -> compare_or_record_divergence(scenario, expected, run_minga(scenario))
      false -> flunk("Neovim oracle errored for #{scenario.name}: #{expected.error}")
    end
  end

  @doc false
  @spec compare_results(scenario(), NeovimOracle.result(), minga_result()) :: :ok
  def compare_results(scenario, expected, actual) do
    compare_or_record_divergence(scenario, expected, actual)
  end

  @doc "Returns true when a scenario has the requested tag."
  @spec tagged?(scenario(), atom()) :: boolean()
  def tagged?(scenario, tag) when is_atom(tag) do
    tag in Map.get(scenario, :tags, [])
  end

  @spec run_minga(scenario()) :: minga_result()
  defp run_minga(scenario) do
    ctx = EditorCase.start_editor(scenario.content, width: 120, height: 40)
    :ok = BufferProcess.move_to(ctx.buffer, {scenario.cursor.line, scenario.cursor.col})
    EditorCase.send_keys_sync(ctx, scenario.keys)
    state = EditorCase.editor_state(ctx)
    {line, col} = EditorCase.buffer_cursor(ctx)
    register = MingaEditor.Editing.registers(state)

    {register_text, register_type} =
      case Registers.get(register, "") do
        {text, type} -> {text, register_type_label(type)}
        nil -> {"", "v"}
      end

    %{
      line: line,
      col: col,
      content: EditorCase.buffer_content(ctx),
      mode: mode_label(EditorCase.editor_mode(ctx)),
      register: register_text,
      register_type: register_type
    }
  end

  @spec compare_or_record_divergence(scenario(), NeovimOracle.result(), minga_result()) :: :ok
  defp compare_or_record_divergence(scenario, expected, actual) do
    failures = failures(scenario.compare, expected, actual)

    if tagged?(scenario, :known_divergence) do
      log_known_divergence(scenario, failures, expected, actual)
      :ok
    else
      assert_no_failures(scenario, failures, expected, actual)
    end
  end

  @spec compare_fields(NeovimOracle.compare_target()) :: [NeovimOracle.compare_field()]
  defp compare_fields(:content), do: [:content]
  defp compare_fields(:cursor), do: [:cursor]
  defp compare_fields(:mode), do: [:mode]
  defp compare_fields(:register), do: [:register]
  defp compare_fields(:register_type), do: [:register_type]
  defp compare_fields(:both), do: [:content, :cursor]
  defp compare_fields(fields) when is_list(fields), do: fields

  @spec failures(NeovimOracle.compare_target(), NeovimOracle.result(), minga_result()) :: [atom()]
  defp failures(compare, expected, actual) do
    compare
    |> compare_fields()
    |> Enum.flat_map(&field_failure(&1, expected, actual))
  end

  @spec field_failure(NeovimOracle.compare_field(), NeovimOracle.result(), minga_result()) ::
          [atom()]
  defp field_failure(:content, expected, actual) do
    if expected.content == actual.content, do: [], else: [:content]
  end

  defp field_failure(:cursor, expected, actual) do
    if {expected.line, expected.col} == {actual.line, actual.col}, do: [], else: [:cursor]
  end

  defp field_failure(:mode, expected, actual) do
    if expected.mode == actual.mode, do: [], else: [:mode]
  end

  defp field_failure(:register, expected, actual) do
    if expected.register == actual.register, do: [], else: [:register]
  end

  defp field_failure(:register_type, expected, actual) do
    if expected.register_type == actual.register_type, do: [], else: [:register_type]
  end

  @spec assert_no_failures(scenario(), [atom()], NeovimOracle.result(), minga_result()) :: :ok
  defp assert_no_failures(_scenario, [], _expected, _actual), do: :ok

  defp assert_no_failures(scenario, failures, expected, actual) do
    flunk(divergence_message(scenario, failures, expected, actual, nil, nil))
  end

  @spec log_known_divergence(scenario(), [atom()], NeovimOracle.result(), minga_result()) :: :ok
  defp log_known_divergence(scenario, failures, expected, actual) do
    known = Map.get(scenario, :known_divergence)

    if known == nil do
      flunk(
        "Tagged :known_divergence scenario #{scenario.name} is missing known_divergence data."
      )
    else
      expected_failures = MapSet.new(Map.fetch!(known, :failures))
      reason = Map.fetch!(known, :reason)
      expected_actual = Map.fetch!(known, :actual)

      unless actual_covers_failures?(expected_actual, MapSet.to_list(expected_failures)) do
        flunk(
          "Known divergence #{scenario.name} must record actual Minga values for every failing field."
        )
      end

      actual_failures = MapSet.new(failures)

      if MapSet.equal?(actual_failures, MapSet.new()) do
        flunk(
          "Known divergence now matches Neovim: #{scenario.name}. Remove the :known_divergence tag and the divergence data."
        )
      else
        if actual_failures != expected_failures do
          flunk(divergence_message(scenario, failures, expected, actual, reason, expected_actual))
        else
          if actual_matches?(actual, expected_actual) do
            maybe_log(
              divergence_message(scenario, failures, expected, actual, reason, expected_actual)
            )

            :ok
          else
            flunk(
              divergence_message(scenario, failures, expected, actual, reason, expected_actual)
            )
          end
        end
      end
    end
  end

  @spec actual_covers_failures?(map(), [atom()]) :: boolean()
  defp actual_covers_failures?(expected_actual, failures) when is_map(expected_actual) do
    failures
    |> Enum.flat_map(&actual_keys_for_failure/1)
    |> Enum.all?(&Map.has_key?(expected_actual, &1))
  end

  @spec actual_keys_for_failure(atom()) :: [atom()]
  defp actual_keys_for_failure(:content), do: [:content]
  defp actual_keys_for_failure(:cursor), do: [:line, :col]
  defp actual_keys_for_failure(:mode), do: [:mode]
  defp actual_keys_for_failure(:register), do: [:register]
  defp actual_keys_for_failure(:register_type), do: [:register_type]

  @spec actual_matches?(minga_result(), map()) :: boolean()
  defp actual_matches?(actual, expected_actual) when is_map(expected_actual) do
    Enum.all?(expected_actual, fn {key, value} -> Map.get(actual, key) == value end)
  end

  @spec maybe_log(String.t()) :: :ok
  defp maybe_log(message) do
    if System.get_env("MINGA_CONFORMANCE_LOG_DIVERGENCES") == "1" do
      IO.puts(message)
    end

    :ok
  end

  @spec divergence_message(
          scenario(),
          [atom()],
          NeovimOracle.result(),
          minga_result(),
          String.t() | nil,
          map() | nil
        ) :: String.t()
  defp divergence_message(scenario, failures, expected, actual, reason, expected_actual) do
    expected_actual_block =
      case expected_actual do
        nil -> ""
        map -> "\nExpected Minga result:\n" <> format_actual(map)
      end

    """
    Vim conformance divergence: #{scenario.name}
    Keys: #{inspect(scenario.keys)}
    Compare: #{inspect(scenario.compare)}
    Failed: #{Enum.join(Enum.map(failures, &Atom.to_string/1), ", ")}
    Reason: #{reason || Map.get(scenario, :reason, "")}

    Neovim expected:
      cursor: {#{expected.line}, #{expected.col}}
      mode: #{expected.mode}
      register: #{inspect(expected.register)} (#{expected.register_type})
      content:
    #{indent(expected.content)}

    Minga actual:
      cursor: {#{actual.line}, #{actual.col}}
      mode: #{actual.mode}
      register: #{inspect(actual.register)} (#{actual.register_type})
      content:
    #{indent(actual.content)}#{expected_actual_block}
    """
  end

  @spec format_actual(map()) :: String.t()
  defp format_actual(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> "  #{key}: #{inspect(value)}" end)
  end

  @spec indent(String.t()) :: String.t()
  defp indent(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &"    #{&1}")
  end

  @spec mode_label(atom()) :: String.t()
  defp mode_label(:normal), do: "n"
  defp mode_label(:insert), do: "i"
  defp mode_label(:visual), do: "v"
  defp mode_label(:visual_line), do: "V"
  defp mode_label(:visual_block), do: <<22>>
  defp mode_label(other), do: Atom.to_string(other)

  @spec register_type_label(Registers.reg_type()) :: String.t()
  defp register_type_label(:charwise), do: "v"
  defp register_type_label(:linewise), do: "V"
  defp register_type_label(other), do: Atom.to_string(other)
end
