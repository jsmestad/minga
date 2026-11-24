defmodule MingaEditor.Agent.ReviewHighlightWorkflow do
  @moduledoc """
  Starts and installs the tree-sitter parses for the staged Diff Review.

  `request/2` runs on the Editor before each render submission. It never parses: it plans the wanted parses through `MingaEditor.Agent.ReviewHighlights`, starts each missing parse in a supervised task, and returns at once. Each task sends `{:agent_review_highlight, key, result}` back to the Editor, whose `complete/3` installs the result and reports whether a new frame is needed. Until a result arrives the review renders with flat diff colors.
  """

  alias Minga.Parser.Manager, as: ParserManager
  alias MingaEditor.Agent.ReviewHighlights
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState

  @parse_timeout_ms 2_000

  @typedoc "Parser entry point with the shape of `Minga.Parser.Manager.highlight_source/3`."
  @type highlighter :: (String.t(), String.t(), keyword() -> term())

  @typedoc "Overrides for the parser entry point and task supervisor."
  @type opt :: {:highlighter, highlighter()} | {:supervisor, GenServer.server()}

  @doc "Starts parses the current review still needs. Returns the state unchanged when nothing changed."
  @spec request(EditorState.t(), [opt()]) :: EditorState.t()
  def request(state, opts \\ [])

  def request(%EditorState{workspace: %{agent_ui: %UIState{} = ui}} = state, opts) do
    case ReviewHighlights.plan(ui.view.review_highlights, review(ui.view.preview)) do
      :unchanged ->
        state

      {:planned, highlights, requests} ->
        highlights = Enum.reduce(requests, highlights, &start_parse(&1, &2, opts))

        TraditionalWorkflow.install_agent_ui(
          state,
          UIState.replace_review_highlights(ui, highlights)
        )
    end
  end

  def request(%EditorState{} = state, _opts), do: state

  @doc "Installs one parse result. Returns `:stale` when the review no longer wants it."
  @spec complete(EditorState.t(), ReviewHighlights.key(), ReviewHighlights.result()) ::
          {:accepted, EditorState.t()} | :stale
  def complete(%EditorState{workspace: %{agent_ui: %UIState{} = ui}} = state, key, result) do
    case ReviewHighlights.complete(ui.view.review_highlights, key, result) do
      {:accepted, highlights} ->
        ui = UIState.replace_review_highlights(ui, highlights)
        {:accepted, TraditionalWorkflow.install_agent_ui(state, ui)}

      :stale ->
        :stale
    end
  end

  def complete(%EditorState{}, _key, _result), do: :stale

  @spec review(Preview.t()) :: MingaEditor.Agent.DiffReview.t() | nil
  defp review(%Preview{content: {:diff, review}}), do: review
  defp review(%Preview{}), do: nil

  @spec start_parse(ReviewHighlights.request(), ReviewHighlights.t(), [opt()]) ::
          ReviewHighlights.t()
  defp start_parse({key, language, source}, highlights, opts) do
    editor = self()
    highlighter = Keyword.get(opts, :highlighter, &ParserManager.highlight_source/3)
    supervisor = Keyword.get(opts, :supervisor, Minga.Eval.TaskSupervisor)

    parse = fn ->
      result = parse(highlighter, language, source)
      send(editor, {:agent_review_highlight, key, result})
    end

    case Task.Supervisor.start_child(supervisor, parse) do
      {:ok, _pid} -> highlights
      {:error, _reason} -> unavailable(highlights, key)
    end
  catch
    :exit, _reason -> unavailable(highlights, key)
  end

  @spec parse(highlighter(), String.t(), String.t()) :: ReviewHighlights.result()
  defp parse(highlighter, language, source) do
    language
    |> highlighter.(source, timeout: @parse_timeout_ms)
    |> ReviewHighlights.pack_result()
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  @spec unavailable(ReviewHighlights.t(), ReviewHighlights.key()) :: ReviewHighlights.t()
  defp unavailable(highlights, key) do
    case ReviewHighlights.complete(highlights, key, :unavailable) do
      {:accepted, highlights} -> highlights
      :stale -> highlights
    end
  end
end
