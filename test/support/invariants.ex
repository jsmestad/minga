defmodule Minga.Test.Invariants do
  @moduledoc """
  Editor invariant assertions for chaos/fuzz testing.

  Each function checks a single invariant and returns `:ok` or raises
  with a descriptive message. `assert_all!/1` runs them all.
  """

  alias Minga.Buffer.Server, as: BufferServer

  @valid_modes [
    :normal,
    :insert,
    :visual,
    :operator_pending,
    :command,
    :eval,
    :replace,
    :search,
    :search_prompt,
    :substitute_confirm,
    :extension_confirm
  ]

  @doc "Collects editor state into a result map for postcondition checking."
  @spec collect_result(map()) :: map()
  def collect_result(%{editor: editor}) do
    state =
      try do
        :sys.get_state(editor)
      catch
        :exit, _ -> nil
      end

    if is_nil(state) do
      %{alive?: false, mode: nil, cursor: nil, line_count: 0, content: nil, lines: []}
    else
      collect_from_state(state)
    end
  end

  defp collect_from_state(state) do
    mode = Minga.Editor.Editing.mode(state)
    buf = state.workspace.buffers.active

    if is_pid(buf) do
      {cursor_line, cursor_col} = BufferServer.cursor(buf)
      content = BufferServer.content(buf)
      lines = String.split(content, "\n")

      %{
        alive?: true,
        mode: mode,
        cursor: {cursor_line, cursor_col},
        line_count: length(lines),
        content: content,
        lines: lines
      }
    else
      # No active buffer (e.g., all buffers closed).
      %{alive?: true, mode: mode, cursor: {0, 0}, line_count: 1, content: "", lines: [""]}
    end
  catch
    :exit, _ ->
      %{
        alive?: true,
        mode: Minga.Editor.Editing.mode(state),
        cursor: {0, 0},
        line_count: 1,
        content: "",
        lines: [""]
      }
  end

  @doc "Asserts all invariants hold. Returns `:ok` or raises."
  @spec assert_all!(map()) :: :ok
  def assert_all!(result) do
    assert_alive!(result)
    assert_valid_mode!(result)
    assert_cursor_in_bounds!(result)
    assert_valid_content!(result)
    :ok
  end

  @doc "Asserts the editor GenServer is alive."
  @spec assert_alive!(map()) :: :ok
  def assert_alive!(%{alive?: true}), do: :ok

  def assert_alive!(%{alive?: false}) do
    raise "INVARIANT VIOLATED: Editor GenServer crashed"
  end

  @doc "Asserts the current mode is one of the valid Mode.mode() atoms."
  @spec assert_valid_mode!(map()) :: :ok
  def assert_valid_mode!(%{mode: mode}) when mode in @valid_modes, do: :ok

  def assert_valid_mode!(%{mode: mode}) do
    raise "INVARIANT VIOLATED: Invalid mode #{inspect(mode)}, expected one of #{inspect(@valid_modes)}"
  end

  @doc "Asserts the cursor is within buffer bounds."
  @spec assert_cursor_in_bounds!(map()) :: :ok
  def assert_cursor_in_bounds!(%{cursor: {line, col}, lines: lines, line_count: line_count}) do
    if line < 0 or line >= line_count do
      raise "INVARIANT VIOLATED: Cursor line #{line} out of bounds (0..#{line_count - 1})"
    end

    line_text = Enum.at(lines, line, "")
    max_col = byte_size(line_text)

    if col < 0 or col > max_col do
      raise "INVARIANT VIOLATED: Cursor col #{col} out of bounds (0..#{max_col}) on line #{line} (#{inspect(line_text)})"
    end

    :ok
  end

  @doc "Asserts buffer content is a valid UTF-8 binary."
  @spec assert_valid_content!(map()) :: :ok
  def assert_valid_content!(%{content: content}) when is_binary(content) do
    if String.valid?(content) do
      :ok
    else
      raise "INVARIANT VIOLATED: Buffer content is not valid UTF-8"
    end
  end

  def assert_valid_content!(%{content: nil}) do
    raise "INVARIANT VIOLATED: Buffer content is nil (editor likely crashed)"
  end
end
