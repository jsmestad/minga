defmodule Minga.Test.EditorCase do
  @moduledoc """
  ExUnit case template for headless editor tests.

  Provides helpers to start an editor with a virtual screen capture,
  send keystrokes, and assert on rendered output.

  ## Usage

      defmodule MyTest do
        use Minga.Test.EditorCase, async: true

        test "shows file content on screen", ctx do
          ctx = start_editor(ctx, "hello world")
          assert_row_contains(ctx, 0, "hello world")
        end
      end
  """

  use ExUnit.CaseTemplate

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor
  alias Minga.Test.HeadlessPort

  using do
    quote do
      import Minga.Test.EditorCase
      alias Minga.Buffer.Server, as: BufferServer
    end
  end

  @typedoc "Test context with editor processes."
  @type editor_ctx :: %{
          editor: pid(),
          buffer: pid(),
          port: pid(),
          width: pos_integer(),
          height: pos_integer()
        }

  # ── Setup helpers ────────────────────────────────────────────────────────────

  @doc """
  Starts an editor with headless port for render capture.

  Returns the context map with `:editor`, `:buffer`, `:port` keys added.

  Options:
    - `:width` — terminal width (default 80)
    - `:height` — terminal height (default 24)
    - `:file_path` — optional file path for the buffer
  """
  @spec start_editor(String.t(), keyword()) :: editor_ctx()
  def start_editor(content, opts \\ []) do
    ctx = %{}
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    file_path = Keyword.get(opts, :file_path)
    id = :erlang.unique_integer([:positive])

    {:ok, port} = HeadlessPort.start_link(width: width, height: height)

    buffer_opts = [content: content]
    buffer_opts = if file_path, do: [{:file_path, file_path} | buffer_opts], else: buffer_opts

    {:ok, buffer} = BufferServer.start_link(buffer_opts)

    {:ok, editor} =
      Editor.start_link(
        name: :"headless_editor_#{id}",
        port_manager: port,
        buffer: buffer,
        width: width,
        height: height
      )

    # Send ready event to trigger initial render
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    :ok = HeadlessPort.collect_frame(ref)

    Map.merge(ctx, %{
      editor: editor,
      buffer: buffer,
      port: port,
      width: width,
      height: height
    })
  end

  # ── Key sending helpers ──────────────────────────────────────────────────────

  @doc "Sends a key press and waits for the next rendered frame."
  @spec send_key(editor_ctx(), non_neg_integer(), non_neg_integer()) :: :ok
  def send_key(%{editor: editor, port: port}, codepoint, mods \\ 0) do
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:key_press, codepoint, mods}})
    :ok = HeadlessPort.collect_frame(ref)
  end

  @doc "Sends each character in the string as a key press, waiting after each."
  @spec type_text(editor_ctx(), String.t()) :: :ok
  def type_text(ctx, text) do
    text
    |> String.to_charlist()
    |> Enum.each(fn char -> send_key(ctx, char) end)

    :ok
  end

  @doc """
  Sends a vim-style key sequence. Supports:
  - `<Esc>` — escape (27)
  - `<CR>` or `<Enter>` — enter (13)
  - `<BS>` — backspace (127)
  - `<C-x>` — ctrl+x
  - `<Space>` or `<SPC>` — space (32)
  - Regular characters sent as-is
  """
  @spec send_keys(editor_ctx(), String.t()) :: :ok
  def send_keys(ctx, sequence) do
    parse_key_sequence(sequence)
    |> Enum.each(fn {cp, mods} -> send_key(ctx, cp, mods) end)

    :ok
  end

  # ── Screen query helpers ─────────────────────────────────────────────────────

  @doc "Returns the rendered text for a specific row."
  @spec screen_row(editor_ctx(), non_neg_integer()) :: String.t()
  def screen_row(%{port: port}, row) do
    HeadlessPort.get_row_text(port, row)
  end

  @doc "Returns all screen rows as a list of strings."
  @spec screen_text(editor_ctx()) :: [String.t()]
  def screen_text(%{port: port}) do
    HeadlessPort.get_screen_text(port)
  end

  @doc "Returns the modeline row text (second to last row)."
  @spec modeline(editor_ctx()) :: String.t()
  def modeline(%{port: port, height: height}) do
    HeadlessPort.get_row_text(port, height - 2)
  end

  @doc "Returns the minibuffer row text (last row)."
  @spec minibuffer(editor_ctx()) :: String.t()
  def minibuffer(%{port: port, height: height}) do
    HeadlessPort.get_row_text(port, height - 1)
  end

  @doc "Returns the cursor position on screen."
  @spec screen_cursor(editor_ctx()) :: {non_neg_integer(), non_neg_integer()}
  def screen_cursor(%{port: port}) do
    HeadlessPort.get_cursor(port)
  end

  @doc "Returns the current cursor shape."
  @spec cursor_shape(editor_ctx()) :: Minga.Port.Protocol.cursor_shape()
  def cursor_shape(%{port: port}) do
    HeadlessPort.get_cursor_shape(port)
  end

  @doc "Returns the buffer content."
  @spec buffer_content(editor_ctx()) :: String.t()
  def buffer_content(%{buffer: buffer}) do
    BufferServer.content(buffer)
  end

  @doc "Returns the buffer cursor position."
  @spec buffer_cursor(editor_ctx()) :: {non_neg_integer(), non_neg_integer()}
  def buffer_cursor(%{buffer: buffer}) do
    BufferServer.cursor(buffer)
  end

  # ── Assertion helpers ────────────────────────────────────────────────────────

  @doc "Asserts that a screen row contains the expected text."
  defmacro assert_row_contains(ctx, row, expected) do
    quote do
      row_text = screen_row(unquote(ctx), unquote(row))

      assert String.contains?(row_text, unquote(expected)),
             "Expected row #{unquote(row)} to contain #{inspect(unquote(expected))}, got: #{inspect(row_text)}"
    end
  end

  @doc "Asserts the modeline contains the expected text."
  defmacro assert_modeline_contains(ctx, expected) do
    quote do
      ml = modeline(unquote(ctx))

      assert String.contains?(ml, unquote(expected)),
             "Expected modeline to contain #{inspect(unquote(expected))}, got: #{inspect(ml)}"
    end
  end

  @doc "Asserts the minibuffer contains the expected text."
  defmacro assert_minibuffer_contains(ctx, expected) do
    quote do
      mb = minibuffer(unquote(ctx))

      assert String.contains?(mb, unquote(expected)),
             "Expected minibuffer to contain #{inspect(unquote(expected))}, got: #{inspect(mb)}"
    end
  end

  @doc "Asserts the modeline shows the expected mode badge."
  defmacro assert_mode(ctx, mode) do
    quote do
      badge =
        case unquote(mode) do
          :normal -> "NORMAL"
          :insert -> "INSERT"
          :visual -> "VISUAL"
          :command -> "COMMAND"
        end

      ml = modeline(unquote(ctx))

      assert String.contains?(ml, badge),
             "Expected modeline to show #{badge} mode, got: #{inspect(ml)}"
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @ctrl 0x02

  @spec parse_key_sequence(String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  defp parse_key_sequence(seq), do: do_parse_keys(seq, [])

  defp do_parse_keys("", acc), do: Enum.reverse(acc)

  defp do_parse_keys("<Esc>" <> rest, acc), do: do_parse_keys(rest, [{27, 0} | acc])
  defp do_parse_keys("<CR>" <> rest, acc), do: do_parse_keys(rest, [{13, 0} | acc])
  defp do_parse_keys("<Enter>" <> rest, acc), do: do_parse_keys(rest, [{13, 0} | acc])
  defp do_parse_keys("<BS>" <> rest, acc), do: do_parse_keys(rest, [{127, 0} | acc])
  defp do_parse_keys("<Space>" <> rest, acc), do: do_parse_keys(rest, [{32, 0} | acc])
  defp do_parse_keys("<SPC>" <> rest, acc), do: do_parse_keys(rest, [{32, 0} | acc])

  defp do_parse_keys("<C-" <> rest, acc) do
    case String.split(rest, ">", parts: 2) do
      [key, remainder] ->
        <<cp::utf8>> = String.downcase(key)
        do_parse_keys(remainder, [{cp, @ctrl} | acc])

      _ ->
        do_parse_keys(rest, acc)
    end
  end

  defp do_parse_keys(<<cp::utf8, rest::binary>>, acc) do
    do_parse_keys(rest, [{cp, 0} | acc])
  end
end
