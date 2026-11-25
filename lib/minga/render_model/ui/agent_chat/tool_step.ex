defmodule Minga.RenderModel.UI.AgentChat.ToolStep do
  @moduledoc """
  One sentence and one state for a tool call in the conversation.

  The conversation shows each tool call as a single line: a state glyph and a plain sentence such as "Read native.ex", "Running `mix test`" or "Stopped while editing chrome_state.ex" (`docs/design/surfaces.md`, Conversation and composer). The BEAM writes the sentence and picks the state here, once, so the macOS and terminal frontends draw the same words and never map a tool status to a word of their own.

  The state is one of the shared state tokens (`Minga.Design.Tokens.state_ids/0`): a running call is working, a finished call is done, a failed call (or an approval that expired) is failed, and a call you denied or stopped is stopped. The sentence never repeats the state word except where it says what was interrupted.
  """

  alias Minga.RenderModel.UI.AgentChat.ToolArgSummary

  @typedoc "A resolved tool-call outcome, as `Minga.RenderModel.UI.AgentChat.ToolCallView` carries it."
  @type status :: :running | :complete | :error | :denied | :cancelled | :approval_expired

  @typedoc "The shared state a tool step is drawn in."
  @type state :: :working | :done | :failed | :stopped

  # The longest target a sentence quotes; the frontends clip the whole line to their width.
  @target_limit 96

  # {gerund, past tense, infinitive} for each tool the conversation names in words.
  @verbs %{
    "read_file" => {"Reading", "Read", "read"},
    "write_file" => {"Writing", "Wrote", "write"},
    "edit_file" => {"Editing", "Edited", "edit"},
    "multi_edit_file" => {"Editing", "Edited", "edit"},
    "apply_diff" => {"Applying a diff to", "Applied a diff to", "apply a diff to"},
    "delete_file" => {"Deleting", "Deleted", "delete"},
    "list_directory" => {"Listing", "Listed", "list"},
    "find" => {"Finding", "Found", "find"},
    "grep" => {"Searching for", "Searched for", "search for"},
    "shell" => {"Running", "Ran", "run"},
    "bash" => {"Running", "Ran", "run"},
    "git_stage" => {"Staging", "Staged", "stage"},
    "git_commit" => {"Committing", "Committed", "commit"},
    "subagent" => {"Starting", "Started", "start"},
    "ask_user" => {"Asking you a question", "Asked you a question", "ask you a question"}
  }

  @doc "The state a tool call with this status is drawn in."
  @spec state(status()) :: state()
  def state(:running), do: :working
  def state(:complete), do: :done
  def state(:error), do: :failed
  def state(:approval_expired), do: :failed
  def state(:denied), do: :stopped
  def state(:cancelled), do: :stopped

  @doc """
  The one-line sentence for a tool call: its name, arguments and status.

  Shell commands are quoted in backticks; any other target is the argument summary. A multi-line argument keeps its first line, and a long target is cut with an ellipsis.
  """
  @spec sentence(String.t(), map(), status()) :: String.t()
  def sentence(name, args, status) when is_binary(name) and is_map(args) do
    name = String.trim(name)
    {gerund, past, infinitive} = verbs(name)
    target = target(name, args)
    phrase(status, gerund, past, infinitive, target)
  end

  @spec phrase(status(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  defp phrase(:running, gerund, _past, _infinitive, target), do: join(gerund, target)
  defp phrase(:complete, _gerund, past, _infinitive, target), do: join(past, target)

  defp phrase(:error, _gerund, _past, infinitive, target),
    do: join("Could not " <> infinitive, target)

  defp phrase(:approval_expired, gerund, _past, _infinitive, target),
    do: "Approval expired for " <> lower(join(gerund, target))

  defp phrase(:denied, gerund, _past, _infinitive, target),
    do: "You denied " <> lower(join(gerund, target))

  defp phrase(:cancelled, gerund, _past, _infinitive, target),
    do: "Stopped while " <> lower(join(gerund, target))

  @spec verbs(String.t()) :: {String.t(), String.t(), String.t()}
  defp verbs(name) do
    case Map.fetch(@verbs, name) do
      {:ok, verbs} -> verbs
      :error -> {"Running " <> label(name), "Ran " <> label(name), "run " <> label(name)}
    end
  end

  # An unknown tool is named by its words: `lsp_diagnostics` reads "lsp diagnostics".
  @spec label(String.t()) :: String.t()
  defp label(""), do: "a tool"
  defp label(name), do: String.replace(name, "_", " ")

  @spec target(String.t(), map()) :: String.t()
  # A question names no target; the verb says it all.
  defp target("ask_user", _args), do: ""

  defp target(name, args) when name in ["shell", "bash"] do
    case ToolArgSummary.summarize(name, args) |> first_line() do
      "" -> ""
      command -> "`" <> clip(command) <> "`"
    end
  end

  defp target(name, args), do: ToolArgSummary.summarize(name, args) |> first_line() |> clip()

  @spec first_line(String.t()) :: String.t()
  defp first_line(text) do
    text
    |> String.split(["\r\n", "\n", "\r"], parts: 2)
    |> hd()
    |> String.trim()
  end

  @spec clip(String.t()) :: String.t()
  defp clip(text) do
    if String.length(text) > @target_limit,
      do: String.slice(text, 0, @target_limit - 1) <> "…",
      else: text
  end

  @spec join(String.t(), String.t()) :: String.t()
  defp join(verb, ""), do: verb
  defp join(verb, target), do: verb <> " " <> target

  # "Reading native.ex" becomes "reading native.ex" after a leading clause.
  @spec lower(String.t()) :: String.t()
  defp lower(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower(""), do: ""
end
