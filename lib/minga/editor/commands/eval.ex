defmodule Minga.Editor.Commands.Eval do
  @moduledoc """
  Eval command: evaluates Elixir expressions from the `M-:` prompt.

  Evaluation runs in a supervised `Task` under `Minga.Buffer.Supervisor`
  with a 5-second timeout. Results and errors are displayed on the status
  line and logged to the `*Messages*` buffer.
  """

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @eval_timeout 5_000
  @max_status_length 120

  @spec execute(state(), Mode.command(), keyword()) :: state()
  def execute(state, command, opts \\ [])

  def execute(state, {:eval_expression, input}, opts) do
    timeout = Keyword.get(opts, :timeout, @eval_timeout)
    editor_pid = self()

    task =
      Task.Supervisor.async_nolink(
        Minga.Eval.TaskSupervisor,
        fn -> eval_in_sandbox(input, editor_pid) end
      )

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        result_str = inspect(result, pretty: true, limit: 50)
        display = truncate(result_str, @max_status_length)

        state
        |> then(&EditorState.set_status(&1, display))
        |> log_to_messages("Eval: #{input}\n  => #{result_str}")

      {:ok, {:error, kind, error, stacktrace}} ->
        formatted = Exception.format(kind, error, stacktrace)
        display = truncate(format_error_oneline(kind, error), @max_status_length)

        state
        |> then(&EditorState.set_status(&1, display))
        |> log_to_messages("Eval error: #{input}\n#{formatted}")

      nil ->
        timeout_display = "#{div(timeout, 1000)}s"

        state
        |> then(&EditorState.set_status(&1, "Eval timed out (#{timeout_display})"))
        |> log_to_messages("Eval timeout: #{input}")
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec eval_in_sandbox(String.t(), pid()) ::
          {:ok, term()} | {:error, atom(), term(), Exception.stacktrace()}
  defp eval_in_sandbox(input, editor_pid) do
    env = %{__ENV__ | file: "eval", line: 1}
    {result, _bindings} = Code.eval_string(input, [editor: editor_pid], env)
    {:ok, result}
  rescue
    e -> {:error, :error, e, __STACKTRACE__}
  catch
    kind, value -> {:error, kind, value, __STACKTRACE__}
  end

  @spec format_error_oneline(atom(), term()) :: String.t()
  defp format_error_oneline(:error, %{__struct__: mod} = error) do
    "** (#{inspect(mod)}) #{Exception.message(error)}"
  end

  defp format_error_oneline(kind, value) do
    "** (#{kind}) #{inspect(value)}"
  end

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(str, max_len) do
    # Take only the first line for status display
    first_line = str |> String.split("\n", parts: 2) |> hd()

    if String.length(first_line) > max_len do
      String.slice(first_line, 0, max_len - 3) <> "..."
    else
      first_line
    end
  end

  @spec log_to_messages(state(), String.t()) :: state()
  defp log_to_messages(%{workspace: %{buffers: %{messages: nil}}} = state, _text), do: state

  defp log_to_messages(%{workspace: %{buffers: %{messages: buf}}} = state, text) do
    time = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    Buffer.append(buf, "[#{time}] #{text}\n")

    # Trim to max lines (same as Editor.log_message/2)
    line_count = Buffer.line_count(buf)

    if line_count > 1000 do
      excess = line_count - 1000
      content = Buffer.content(buf)
      lines = String.split(content, "\n")
      trimmed = lines |> Enum.drop(excess) |> Enum.join("\n")

      :sys.replace_state(buf, fn s ->
        %{s | document: Document.new(trimmed)}
      end)
    end

    state
  end
end
