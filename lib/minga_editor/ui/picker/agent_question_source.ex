defmodule MingaEditor.UI.Picker.AgentQuestionSource do
  @moduledoc "Opens the displayed Agent clarification in the shared picker and prompt surfaces."

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Core.Unicode
  alias MingaAgent.Question
  alias MingaEditor.Agent.PendingQuestion
  alias MingaEditor.PickerUI
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.{Context, Item, Source}

  # One preview row stays reachable when the terminal picker has little vertical space.
  @preview_columns 32
  @typep selection :: :write | Question.response()
  @typep question_page :: {tuple(), non_neg_integer()}
  @typep choice_page :: {non_neg_integer(), tuple(), non_neg_integer(), question_page()}

  @doc "Opens the pending clarification in the current Agent workspace from a keyboard command."
  @spec open(State.t()) :: State.t()
  def open(state) do
    case TraditionalState.agent(state.shell_runtime.state).pending_question do
      %PendingQuestion{offer: offer} -> open(state, offer)
      nil -> NoticeWorkflow.publish(state, "No Agent question is waiting for an answer.")
    end
  end

  @doc "Opens only the clarification identified by the displayed offer."
  @spec open(State.t(), pos_integer()) :: State.t()
  def open(state, offer) do
    case current_question(state, offer) do
      %PendingQuestion{} = pending ->
        pages = pending.question.prompt |> String.replace("\t", " ") |> preview_pages()
        open_page(state, pending, pages, 0)

      nil ->
        stale(state)
    end
  end

  @impl MingaEditor.UI.Picker.Source
  @spec title() :: String.t()
  def title, do: "Answer Agent question"

  @impl MingaEditor.UI.Picker.Source
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{pending: pending, pages: pages, page: page}}}) do
    %PendingQuestion{offer: offer, question: %Question{choices: choices}} = pending
    prompt = elem(pages, page)

    answers =
      choices
      |> Enum.with_index(fn choice, index ->
        choice_item(offer, choice, index, {pages, page}, prompt)
      end)

    page_items(offer, pages, page, prompt, :question) ++
      answers ++
      [
        item(offer, :write, "Type an answer…", prompt),
        item(offer, :cancel, "Cancel question", prompt)
      ]
  end

  def candidates(%Context{
        picker_ui: %{context: %{pending: %PendingQuestion{offer: offer}, choice: choice}}
      }) do
    {index, pages, page, back} = choice
    preview = elem(pages, page)

    page_items(offer, pages, page, preview, {:choice, index, back}) ++
      [
        item(offer, {:choice, index}, "Use choice #{index + 1}", preview),
        %Item{id: {offer, :back}, label: "Back to question", meta: %{prompt: preview, back: back}}
      ]
  end

  def candidates(_context), do: []

  @impl MingaEditor.UI.Picker.Source
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl MingaEditor.UI.Picker.Source
  @spec preview(Item.t(), Source.preview_context()) :: [[Source.preview_segment()]]
  def preview(%Item{meta: %{prompt: prompt}}, context) do
    fg = Map.get(context.intent.frame.theme, :fg, 0xCCCCCC)
    [[{prompt, fg, false}]]
  end

  @impl MingaEditor.UI.Picker.Source
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(%Item{id: {offer, :write}}, state) do
    case current_question(state, offer) do
      %PendingQuestion{} ->
        PromptUI.open(state, MingaEditor.UI.Prompt.AgentQuestion, context: %{offer: offer})

      nil ->
        stale(state)
    end
  end

  def on_select(%Item{id: {offer, {:page, page}}, meta: %{pages: pages}}, state) do
    case current_question(state, offer) do
      %PendingQuestion{} = pending -> open_page(state, pending, pages, page)
      nil -> stale(state)
    end
  end

  def on_select(%Item{id: {offer, {:inspect_choice, index}}, meta: %{back: back}}, state) do
    with %PendingQuestion{} = pending <- current_question(state, offer),
         {:ok, label} <- Enum.fetch(pending.question.choices, index) do
      open_choice(state, pending, {index, preview_pages(label), 0, back})
    else
      _stale -> stale(state)
    end
  end

  def on_select(
        %Item{
          id: {offer, {:choice_page, index, page}},
          meta: %{pages: pages, source: {:choice, index, back}}
        },
        state
      ) do
    case current_question(state, offer) do
      %PendingQuestion{} = pending -> open_choice(state, pending, {index, pages, page, back})
      nil -> stale(state)
    end
  end

  def on_select(%Item{id: {offer, :back}, meta: %{back: {pages, page}}}, state) do
    case current_question(state, offer) do
      %PendingQuestion{} = pending -> open_page(state, pending, pages, page)
      nil -> stale(state)
    end
  end

  def on_select(%Item{id: {offer, response}}, state), do: submit(state, offer, response)

  @doc "Submits a response only while its displayed offer remains current."
  @spec submit(State.t(), pos_integer(), Question.response()) :: State.t()
  def submit(state, offer, response) do
    case current_question(state, offer) do
      %PendingQuestion{} = pending ->
        MingaEditor.Agent.QuestionResponse.submit(state, pending, response)

      nil ->
        stale(state)
    end
  end

  @spec current_question(State.t(), pos_integer()) :: PendingQuestion.t() | nil
  defp current_question(state, offer) do
    case TraditionalState.agent(state.shell_runtime.state).pending_question do
      %PendingQuestion{offer: ^offer} = pending -> pending
      _absent_or_stale -> nil
    end
  end

  @spec open_page(State.t(), PendingQuestion.t(), tuple(), non_neg_integer()) :: State.t()
  defp open_page(state, pending, pages, page),
    do: PickerUI.open(state, __MODULE__, %{pending: pending, pages: pages, page: page})

  @spec open_choice(State.t(), PendingQuestion.t(), choice_page()) :: State.t()
  defp open_choice(state, pending, choice),
    do: PickerUI.open(state, __MODULE__, %{pending: pending, choice: choice})

  @spec preview_pages(String.t()) :: tuple()
  defp preview_pages(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.flat_map(&Stream.unfold(&1, fn rest -> next_preview_page(rest) end))
    |> List.to_tuple()
  end

  @spec next_preview_page(String.t() | nil) :: {String.t(), String.t() | nil} | nil
  defp next_preview_page(nil), do: nil

  defp next_preview_page(rest) do
    prefix = Unicode.truncate_display_width(rest, @preview_columns)
    size = byte_size(prefix)
    <<_::binary-size(^size), suffix::binary>> = rest
    {prefix, if(suffix == "", do: nil, else: suffix)}
  end

  @spec page_items(
          pos_integer(),
          tuple(),
          non_neg_integer(),
          String.t(),
          :question | {:choice, non_neg_integer(), question_page()}
        ) :: [Item.t()]
  defp page_items(offer, pages, page, prompt, source) do
    last = tuple_size(pages) - 1
    section = page_section(source)

    for {label, index} <- [
          {"Previous #{section} page", page - 1},
          {"Next #{section} page", page + 1}
        ],
        index in 0..last do
      %Item{
        id: {offer, page_target(source, index)},
        label: label,
        description: "Page #{page + 1} of #{last + 1}",
        meta: %{pages: pages, prompt: prompt, source: source}
      }
    end
  end

  @spec page_section(:question | {:choice, non_neg_integer(), question_page()}) :: String.t()
  defp page_section(:question), do: "question"
  defp page_section({:choice, _index, _back}), do: "choice"

  @spec page_target(:question | {:choice, non_neg_integer(), question_page()}, non_neg_integer()) ::
          tuple()
  defp page_target(:question, page), do: {:page, page}
  defp page_target({:choice, index, _back}, page), do: {:choice_page, index, page}

  @spec choice_item(pos_integer(), String.t(), non_neg_integer(), question_page(), String.t()) ::
          Item.t()
  defp choice_item(offer, choice, index, back, prompt) do
    if Unicode.display_width(choice) <= @preview_columns do
      item(offer, {:choice, index}, choice, prompt)
    else
      %Item{
        id: {offer, {:inspect_choice, index}},
        label: "Inspect choice #{index + 1}…",
        description: Unicode.truncate_display_width(choice, @preview_columns),
        meta: %{back: back, prompt: prompt}
      }
    end
  end

  @spec item(pos_integer(), selection(), String.t(), String.t()) :: Item.t()
  defp item(offer, response, label, prompt),
    do: %Item{id: {offer, response}, label: label, meta: %{prompt: prompt}}

  @spec stale(State.t()) :: State.t()
  defp stale(state),
    do: NoticeWorkflow.publish(state, "That Agent question is no longer available.")
end
