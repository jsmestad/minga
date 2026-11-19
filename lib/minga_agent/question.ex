defmodule MingaAgent.Question do
  @moduledoc "A bounded clarification request from a model tool call."

  @prompt_limit 4_096
  @choice_limit 256
  @choice_count 8
  @answer_limit 4_096

  @type t :: %__MODULE__{prompt: String.t(), choices: [String.t()]}
  @type response :: {:choice, non_neg_integer()} | {:text, String.t()} | :cancel
  @type outcome :: {:answered, String.t()} | :cancelled

  @enforce_keys [:prompt, :choices]
  defstruct [:prompt, :choices]

  @doc "Validates a model question and its optional, ordered choice labels."
  @spec new(term(), term()) :: {:ok, t()} | {:error, :invalid_question}
  def new(prompt, choices) do
    if valid_text?(prompt, @prompt_limit) and valid_choices?(choices) do
      {:ok, %__MODULE__{prompt: prompt, choices: choices}}
    else
      {:error, :invalid_question}
    end
  end

  @doc "Validates an answer against the exact displayed question."
  @spec resolve(t(), response()) :: {:ok, outcome()} | {:error, :invalid_answer}
  def resolve(%__MODULE__{}, :cancel), do: {:ok, :cancelled}

  def resolve(%__MODULE__{}, {:text, answer}) do
    if valid_text?(answer, @answer_limit),
      do: {:ok, {:answered, answer}},
      else: {:error, :invalid_answer}
  end

  def resolve(%__MODULE__{choices: choices}, {:choice, index})
      when is_integer(index) and index >= 0 and index < @choice_count do
    case Enum.fetch(choices, index) do
      {:ok, label} -> {:ok, {:answered, label}}
      :error -> {:error, :invalid_answer}
    end
  end

  def resolve(%__MODULE__{}, _response), do: {:error, :invalid_answer}

  @spec valid_choices?(term()) :: boolean()
  defp valid_choices?(choices) when is_list(choices) do
    Enum.count_until(choices, @choice_count + 1) <= @choice_count and
      Enum.all?(choices, &valid_choice?/1) and Enum.uniq(choices) == choices
  end

  defp valid_choices?(_choices), do: false

  @spec valid_choice?(term()) :: boolean()
  defp valid_choice?(choice),
    do: valid_text?(choice, @choice_limit) and not String.match?(choice, ~r/[\t\n\p{Zl}\p{Zp}]/u)

  @spec valid_text?(term(), pos_integer()) :: boolean()
  defp valid_text?(text, limit) when is_binary(text) and byte_size(text) <= limit do
    String.valid?(text) and String.trim(text) != "" and
      not String.match?(text, ~r/[\x{0}-\x{8}\x{B}-\x{1F}\x{7F}-\x{9F}]/u)
  end

  defp valid_text?(_text, _limit), do: false
end
