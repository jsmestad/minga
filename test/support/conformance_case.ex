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
  alias MingaEditor.WindowTree

  @type scenario :: NeovimOracle.scenario()
  @type oracle_results :: %{String.t() => NeovimOracle.result()} | :nvim_not_found
  @type minga_result :: %{
          required(:line) => non_neg_integer(),
          required(:col) => non_neg_integer(),
          required(:content) => String.t(),
          required(:mode) => String.t(),
          required(:register) => String.t(),
          required(:register_type) => String.t(),
          optional(:registers) => %{String.t() => %{content: String.t(), type: String.t()}}
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

    case {scenario.type, Map.get(scenario, :register_setup)} do
      {:macro, setup} when is_map(setup) ->
        :sys.replace_state(ctx.editor, fn st ->
          macro_rec = st.workspace.editing.macro_recorder

          populated =
            Enum.reduce(setup, macro_rec, fn {name, content}, acc ->
              keys = for <<cp::utf8 <- content>>, do: {cp, 0}
              %{acc | registers: Map.put(acc.registers, name, keys)}
            end)

          put_in(st.workspace.editing.macro_recorder, populated)
        end)

      {_, setup} when is_map(setup) ->
        state = EditorCase.editor_state(ctx)
        reg_state = MingaEditor.Editing.registers(state)

        populated =
          Enum.reduce(setup, reg_state, fn {name, content}, acc ->
            Registers.put(acc, name, content)
          end)

        :sys.replace_state(ctx.editor, fn st ->
          put_in(st.workspace.editing.reg, populated)
        end)

      _ ->
        :ok
    end

    :ok = BufferProcess.move_to(ctx.buffer, {scenario.cursor.line, scenario.cursor.col})
    run_minga_keys(ctx, scenario)
    state = EditorCase.editor_state(ctx)
    {line, col} = EditorCase.buffer_cursor(ctx)
    reg_state = MingaEditor.Editing.registers(state)

    {register_text, register_type} =
      case Registers.get(reg_state, "") do
        {text, type} -> {text, register_type_label(type)}
        nil -> {"", "v"}
      end

    base = %{
      line: line,
      col: col,
      content: EditorCase.buffer_content(ctx),
      mode: mode_label(EditorCase.editor_mode(ctx)),
      register: register_text,
      register_type: register_type
    }

    case Map.get(scenario, :capture_registers) do
      nil ->
        base

      names ->
        named = Map.new(names, fn name ->
          case Registers.get(reg_state, name) do
            {text, type} -> {name, %{content: text, type: register_type_label(type)}}
            nil -> {name, %{content: "", type: "v"}}
          end
        end)

        Map.put(base, :registers, named)
    end
  end

  @spec run_minga_keys(map(), scenario()) :: :ok
  defp run_minga_keys(ctx, %{commands: commands}) when is_list(commands) do
    Enum.each(commands, &EditorCase.send_keys_sync(ctx, &1))
  end

  defp run_minga_keys(ctx, %{keys: keys}) do
    EditorCase.send_keys_sync(ctx, keys)
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
  defp compare_fields(:registers), do: [:registers]
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

  defp field_failure(:registers, expected, actual) do
    if Map.get(expected, :registers) == Map.get(actual, :registers), do: [], else: [:registers]
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
  defp actual_keys_for_failure(:registers), do: [:registers]

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
    Keys: #{inspect(scenario[:keys] || scenario[:commands])}
    Compare: #{inspect(scenario.compare)}
    Failed: #{Enum.join(Enum.map(failures, &Atom.to_string/1), ", ")}
    Reason: #{reason || Map.get(scenario, :reason, "")}

    Neovim expected:
      cursor: {#{expected.line}, #{expected.col}}
      mode: #{expected.mode}
      register: #{inspect(expected.register)} (#{expected.register_type})#{format_registers(Map.get(expected, :registers))}
      content:
    #{indent(expected.content)}

    Minga actual:
      cursor: {#{actual.line}, #{actual.col}}
      mode: #{actual.mode}
      register: #{inspect(actual.register)} (#{actual.register_type})#{format_registers(Map.get(actual, :registers))}
      content:
    #{indent(actual.content)}#{expected_actual_block}
    """
  end

  @spec format_registers(%{String.t() => %{content: String.t(), type: String.t()}} | nil) ::
          String.t()
  defp format_registers(nil), do: ""

  defp format_registers(regs) when is_map(regs) do
    entries =
      regs
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join(", ", fn {name, %{content: content, type: type}} ->
        "\"#{name}\"=#{inspect(content)} (#{type})"
      end)

    "\n    registers: #{entries}"
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

  # ── Window conformance ─────────────────────────────────────────────────────

  @type minga_window_info :: %{
          required(:buffer_first_line) => String.t(),
          required(:line) => non_neg_integer(),
          required(:col) => non_neg_integer(),
          required(:active) => boolean(),
          required(:row_pos) => non_neg_integer(),
          required(:col_pos) => non_neg_integer()
        }
  @type minga_window_result :: %{
          required(:window_count) => non_neg_integer(),
          required(:windows) => [minga_window_info()]
        }

  @doc "Runs one window scenario in Minga and compares with the cached Neovim oracle result."
  @spec assert_window_conforms(scenario(), oracle_results()) :: :ok
  def assert_window_conforms(_scenario, :nvim_not_found), do: :ok

  def assert_window_conforms(scenario, oracle_results) when is_map(oracle_results) do
    expected = Map.fetch!(oracle_results, scenario.name)

    case expected.ok do
      true ->
        actual = run_minga_window(scenario)
        compare_window_state(scenario, expected, actual)

      false ->
        flunk("Neovim oracle errored for #{scenario.name}: #{expected.error}")
    end
  end

  @spec run_minga_window(scenario()) :: minga_window_result()
  defp run_minga_window(scenario) do
    ctx = EditorCase.start_editor(scenario.content, width: 120, height: 40)
    :ok = BufferProcess.move_to(ctx.buffer, {scenario.cursor.line, scenario.cursor.col})

    Enum.each(scenario.minga_keys, fn key_seq ->
      EditorCase.send_keys_sync(ctx, key_seq)
    end)

    window_state(ctx)
  end

  @doc "Captures the current window state from a Minga editor context."
  @spec window_state(EditorCase.editor_ctx()) :: minga_window_result()
  def window_state(ctx) do
    state = EditorCase.editor_state(ctx)
    windows = state.workspace.windows
    tree = windows.tree
    active_id = windows.active

    # Subtract 2 rows for modeline and minibuffer, matching Editor.Layout
    screen_rect = {0, 0, ctx.width, ctx.height - 2}

    window_list =
      case tree do
        nil ->
          case Map.get(windows.map, active_id) do
            nil -> []
            win -> [window_to_info(win, active_id, screen_rect)]
          end

        _tree ->
          layouts = WindowTree.layout(tree, screen_rect)

          Enum.map(layouts, fn {id, {row, col_pos, _w, _h}} ->
            win = Map.fetch!(windows.map, id)
            window_to_info(win, active_id, {row, col_pos})
          end)
      end

    %{
      window_count: length(window_list),
      windows: window_list
    }
  end

  @spec window_to_info(
          MingaEditor.Window.t(),
          MingaEditor.Window.id(),
          {non_neg_integer(), non_neg_integer()} | WindowTree.rect()
        ) :: minga_window_info()
  defp window_to_info(win, active_id, position) do
    first_line =
      win.buffer
      |> BufferProcess.content()
      |> String.split("\n", parts: 2)
      |> hd()

    cursor =
      if win.id == active_id do
        BufferProcess.cursor(win.buffer)
      else
        win.cursor
      end

    {row_pos, col_pos} =
      case position do
        {r, c, _w, _h} -> {r, c}
        {r, c} -> {r, c}
      end

    %{
      buffer_first_line: first_line,
      line: elem(cursor, 0),
      col: elem(cursor, 1),
      active: win.id == active_id,
      row_pos: row_pos,
      col_pos: col_pos
    }
  end

  @spec compare_window_state(scenario(), NeovimOracle.result(), minga_window_result()) :: :ok
  defp compare_window_state(scenario, expected, actual) do
    failures = window_failures(scenario.compare, expected, actual)

    if tagged?(scenario, :known_divergence) do
      if failures == [] do
        flunk(
          "Known divergence now matches Neovim: #{scenario.name}. Remove the :known_divergence tag and the divergence data."
        )
      else
        known = Map.get(scenario, :known_divergence)

        if known == nil do
          flunk(
            "Tagged :known_divergence scenario #{scenario.name} is missing known_divergence data."
          )
        else
          expected_failures = MapSet.new(Map.fetch!(known, :failures))
          actual_failures = MapSet.new(failures)

          if actual_failures != expected_failures do
            flunk(window_divergence_message(scenario, failures, expected, actual))
          else
            maybe_log(window_divergence_message(scenario, failures, expected, actual))
            :ok
          end
        end
      end
    else
      if failures == [] do
        :ok
      else
        flunk(window_divergence_message(scenario, failures, expected, actual))
      end
    end
  end

  @spec window_compare_fields(NeovimOracle.compare_target()) :: [atom()]
  defp window_compare_fields(:window_state),
    do: [:window_count, :active_window, :cursors, :buffers, :layout]

  defp window_compare_fields(fields) when is_list(fields), do: fields

  @spec window_failures(
          NeovimOracle.compare_target(),
          NeovimOracle.result(),
          minga_window_result()
        ) ::
          [atom()]
  defp window_failures(compare, expected, actual) do
    compare
    |> window_compare_fields()
    |> Enum.flat_map(&window_field_failure(&1, expected, actual))
  end

  @spec window_field_failure(atom(), NeovimOracle.result(), minga_window_result()) :: [atom()]
  defp window_field_failure(:window_count, expected, actual) do
    if expected.window_count == actual.window_count, do: [], else: [:window_count]
  end

  defp window_field_failure(:active_window, expected, actual) do
    if expected.window_count != actual.window_count do
      [:active_window]
    else
      nvim_sorted = Enum.sort_by(expected.windows, &{&1.row_pos, &1.col_pos})
      minga_sorted = Enum.sort_by(actual.windows, &{&1.row_pos, &1.col_pos})
      nvim_active_index = Enum.find_index(nvim_sorted, & &1.active)
      minga_active_index = Enum.find_index(minga_sorted, & &1.active)

      if nvim_active_index == minga_active_index, do: [], else: [:active_window]
    end
  end

  defp window_field_failure(:cursors, expected, actual) do
    if expected.window_count != actual.window_count do
      [:cursors]
    else
      nvim_cursors =
        expected.windows
        |> Enum.sort_by(&{&1.row_pos, &1.col_pos})
        |> Enum.map(&{&1.line, &1.col})

      minga_cursors =
        actual.windows
        |> Enum.sort_by(&{&1.row_pos, &1.col_pos})
        |> Enum.map(&{&1.line, &1.col})

      if nvim_cursors == minga_cursors, do: [], else: [:cursors]
    end
  end

  defp window_field_failure(:buffers, expected, actual) do
    if expected.window_count != actual.window_count do
      [:buffers]
    else
      nvim_buffers =
        expected.windows
        |> Enum.sort_by(&{&1.row_pos, &1.col_pos})
        |> Enum.map(& &1.buffer_first_line)

      minga_buffers =
        actual.windows
        |> Enum.sort_by(&{&1.row_pos, &1.col_pos})
        |> Enum.map(& &1.buffer_first_line)

      if nvim_buffers == minga_buffers, do: [], else: [:buffers]
    end
  end

  defp window_field_failure(:layout, expected, actual) do
    if expected.window_count != actual.window_count do
      [:layout]
    else
      nvim_layout =
        expected.windows
        |> Enum.sort_by(&{&1.row_pos, &1.col_pos})
        |> Enum.map(&relative_position/1)

      minga_layout =
        actual.windows
        |> Enum.sort_by(&{&1.row_pos, &1.col_pos})
        |> Enum.map(&relative_position/1)

      if nvim_layout == minga_layout, do: [], else: [:layout]
    end
  end

  @spec relative_position(map()) :: :top_left | :top_right | :bottom_left | :bottom_right
  defp relative_position(%{row_pos: 0, col_pos: 0}), do: :top_left
  defp relative_position(%{row_pos: 0, col_pos: c}) when c > 0, do: :top_right
  defp relative_position(%{row_pos: r, col_pos: 0}) when r > 0, do: :bottom_left
  defp relative_position(%{row_pos: r, col_pos: c}) when r > 0 and c > 0, do: :bottom_right

  @spec window_divergence_message(
          scenario(),
          [atom()],
          NeovimOracle.result(),
          minga_window_result()
        ) :: String.t()
  defp window_divergence_message(scenario, failures, expected, actual) do
    """
    Window conformance divergence: #{scenario.name}
    Commands: #{inspect(Map.get(scenario, :commands, []))}
    Minga keys: #{inspect(Map.get(scenario, :minga_keys, []))}
    Compare: #{inspect(scenario.compare)}
    Failed: #{Enum.join(Enum.map(failures, &Atom.to_string/1), ", ")}

    Neovim expected:
      window_count: #{expected.window_count}
      windows:
    #{format_window_list(expected.windows)}

    Minga actual:
      window_count: #{actual.window_count}
      windows:
    #{format_window_list(actual.windows)}
    """
  end

  @spec format_window_list([map()]) :: String.t()
  defp format_window_list(windows) do
    windows
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {win, i} ->
      active_marker = if win.active, do: " *active*", else: ""

      "    [#{i}] buffer: #{inspect(win.buffer_first_line)}, cursor: {#{win.line}, #{win.col}}#{active_marker}"
    end)
  end
end
