defmodule MingaAgent.Session.ModelSwitch do
  @moduledoc """
  Pure compatibility, budget, and capability validation for model switching.

  Given a source selection (or nil for a first selection), a destination selection,
  and the current continuation state, this module determines whether the switch is
  safe and what kind of transition is required.

  This module is Layer 0: it takes values in and returns values out. It does not
  call GenServers, subscribe to events, or perform side effects.
  """

  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Policy
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.Request

  @typedoc "The kind of transition a model switch requires."
  @type compatibility ::
          :exact
          | {:handoff, :retain}
          | {:handoff, :reject}

  @typedoc "Capability that the source has but the destination lacks."
  @type capability_gap :: :tools | :images | :tool_result_images | :streaming

  @typedoc "Budget assessment detail."
  @type budget_detail :: %{
          estimated_tokens: non_neg_integer(),
          destination_context: pos_integer(),
          destination_reserve: pos_integer(),
          available: integer()
        }

  @typedoc "Full validation result for a model switch."
  @type validation ::
          {:ok, compatibility()}
          | {:error, :busy | :budget_exceeded | {:capability_gap, [capability_gap()]} | term()}

  @doc """
  Validates whether a model switch from `source` to `destination` is safe given the current continuation.

  Returns `{:ok, compatibility}` when the switch can proceed, or `{:error, reason}` when it cannot.
  The compatibility classification tells the caller which continuation transition to use.
  """
  @spec validate(ModelSelection.t() | nil, ModelSelection.t(), Continuation.t()) :: validation()
  def validate(source, %ModelSelection{} = destination, %Continuation{} = continuation) do
    with :ok <- check_idle(continuation),
         :ok <- check_capabilities(source, destination, continuation),
         :ok <- check_budget(destination, continuation) do
      {:ok, classify(source, destination)}
    end
  end

  @doc """
  Classifies the transition kind between two selections.

  Returns `:exact` when the route is identical (no continuation change needed),
  `{:handoff, :retain}` when the same provider/endpoint/credential permits file retention,
  or `{:handoff, :reject}` when provider-owned state cannot transfer.
  """
  @spec classify(ModelSelection.t() | nil, ModelSelection.t()) :: compatibility()
  def classify(nil, %ModelSelection{}), do: {:handoff, :reject}

  def classify(
        %ModelSelection{route: route},
        %ModelSelection{route: route}
      ),
      do: :exact

  def classify(
        %ModelSelection{
          route: %{request_provider: provider, execution: %{base_url: endpoint}},
          credential: credential
        },
        %ModelSelection{
          route: %{request_provider: provider, execution: %{base_url: endpoint}},
          credential: credential
        }
      ),
      do: {:handoff, :retain}

  def classify(%ModelSelection{}, %ModelSelection{}), do: {:handoff, :reject}

  @doc """
  Checks whether the continuation state permits a model change.

  Returns `:ok` at an idle boundary, or `{:error, :busy}` when a request is active,
  tool effects are pending, or a dispatch assessment is in progress.
  """
  @spec check_idle(Continuation.t()) :: :ok | {:error, :busy}
  def check_idle(%Continuation{active_request: %Request{}}), do: {:error, :busy}
  def check_idle(%Continuation{tool_checkpoint: %{}}), do: {:error, :busy}
  def check_idle(%Continuation{dispatch: {_owner, _dispatch}}), do: {:error, :busy}
  def check_idle(%Continuation{}), do: :ok

  @doc """
  Checks whether the destination's context window can hold the current conversation.

  Uses a conservative character-to-token estimate. Returns `:fits` when the history
  fits comfortably, `{:tight, detail}` when it fits but leaves less than 20% headroom,
  or `{:exceeds, detail}` when it cannot fit.
  """
  @spec check_budget(ModelSelection.t(), Continuation.t()) ::
          :ok | {:error, :budget_exceeded}
  def check_budget(%ModelSelection{policy: %Policy{limits: limits}}, %Continuation{
        messages: messages
      }) do
    case limits.context do
      nil ->
        :ok

      context when is_integer(context) ->
        estimated = estimate_tokens(messages)
        reserve = limits.request_output
        available = context - reserve

        if estimated <= available do
          :ok
        else
          {:error, :budget_exceeded}
        end
    end
  end

  @doc """
  Estimates the token count of a list of messages using a conservative character ratio.

  Uses ~4 characters per token as a rough estimate. This is intentionally conservative
  to avoid false negatives; the real token count may be lower.
  """
  @spec estimate_tokens([ReqLLM.Message.t()]) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.reduce(0, fn message, acc ->
      acc + message_char_count(message)
    end)
    |> div(4)
  end

  @doc """
  Returns budget assessment detail for the destination model and current conversation.

  This provides the full detail for error messages and UI feedback without
  making a pass/fail decision.
  """
  @spec budget_detail(ModelSelection.t(), Continuation.t()) :: budget_detail() | nil
  def budget_detail(%ModelSelection{policy: %Policy{limits: limits}}, %Continuation{
        messages: messages
      }) do
    case limits.context do
      nil ->
        nil

      context when is_integer(context) ->
        estimated = estimate_tokens(messages)
        reserve = limits.request_output

        %{
          estimated_tokens: estimated,
          destination_context: context,
          destination_reserve: reserve,
          available: context - reserve
        }
    end
  end

  @doc """
  Detects capability gaps between source and destination selections.

  Returns the list of capabilities that the conversation history uses (via the source
  selection) but the destination does not support.
  """
  @spec capability_gaps(ModelSelection.t() | nil, ModelSelection.t()) :: [capability_gap()]
  def capability_gaps(nil, _destination), do: []

  def capability_gaps(%ModelSelection{} = source, %ModelSelection{} = destination) do
    []
    |> maybe_gap(:tools, ModelSelection.tools?(source), ModelSelection.tools?(destination))
    |> maybe_gap(:images, ModelSelection.images?(source), ModelSelection.images?(destination))
    |> maybe_gap(
      :tool_result_images,
      ModelSelection.tool_result_images?(source),
      ModelSelection.tool_result_images?(destination)
    )
    |> maybe_gap(
      :streaming,
      source.policy.capabilities.streaming == true,
      destination.policy.capabilities.streaming == true
    )
  end

  @doc """
  Formats a human-readable budget rejection message.
  """
  @spec budget_exceeded_message(budget_detail()) :: String.t()
  def budget_exceeded_message(%{
        estimated_tokens: estimated,
        destination_context: context,
        destination_reserve: reserve
      }) do
    available = context - reserve

    "The conversation history (~#{format_count(estimated)} tokens) exceeds the destination model's usable context (~#{format_count(available)} tokens, #{format_count(context)} context minus #{format_count(reserve)} output reserve). Start a new conversation or choose a model with a larger context window."
  end

  @doc """
  Formats a human-readable capability gap message.
  """
  @spec capability_gap_message([capability_gap()]) :: String.t()
  def capability_gap_message(gaps) when is_list(gaps) and gaps != [] do
    names = Enum.map(gaps, &capability_name/1)
    joined = join_names(names)

    "The destination model does not support #{joined}, which this conversation uses. The switch would lose those capabilities."
  end

  # Private helpers

  @spec check_capabilities(ModelSelection.t() | nil, ModelSelection.t(), Continuation.t()) ::
          :ok | {:error, {:capability_gap, [capability_gap()]}}
  defp check_capabilities(nil, _destination, _continuation), do: :ok

  defp check_capabilities(source, destination, continuation) do
    gaps = capability_gaps(source, destination)

    if gaps == [] or conversation_empty?(continuation) do
      :ok
    else
      used_gaps = Enum.filter(gaps, &capability_used_in_history?(&1, continuation))

      if used_gaps == [] do
        :ok
      else
        {:error, {:capability_gap, used_gaps}}
      end
    end
  end

  @spec capability_used_in_history?(capability_gap(), Continuation.t()) :: boolean()
  defp capability_used_in_history?(:tools, %Continuation{messages: messages}) do
    Enum.any?(messages, fn
      %{role: :assistant, tool_calls: [_ | _]} -> true
      %{role: :tool} -> true
      _message -> false
    end)
  end

  defp capability_used_in_history?(:images, %Continuation{messages: messages}) do
    Enum.any?(messages, fn
      %{content: content} when is_list(content) ->
        Enum.any?(content, fn
          %{type: :image} -> true
          %{type: :image_url} -> true
          _part -> false
        end)

      _message ->
        false
    end)
  end

  defp capability_used_in_history?(:tool_result_images, continuation),
    do: capability_used_in_history?(:images, continuation)

  defp capability_used_in_history?(:streaming, _continuation), do: false

  @spec conversation_empty?(Continuation.t()) :: boolean()
  defp conversation_empty?(%Continuation{boundaries: []}), do: true
  defp conversation_empty?(%Continuation{}), do: false

  @spec message_char_count(ReqLLM.Message.t()) :: non_neg_integer()
  defp message_char_count(%{content: content}) when is_list(content) do
    Enum.reduce(content, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + byte_size(text)
      %{text: text}, acc when is_binary(text) -> acc + byte_size(text)
      _part, acc -> acc + 100
    end)
  end

  defp message_char_count(%{content: content}) when is_binary(content), do: byte_size(content)
  defp message_char_count(_message), do: 0

  @spec maybe_gap([capability_gap()], capability_gap(), boolean(), boolean()) :: [
          capability_gap()
        ]
  defp maybe_gap(gaps, capability, true, false), do: [capability | gaps]
  defp maybe_gap(gaps, _capability, _source, _destination), do: gaps

  @spec capability_name(capability_gap()) :: String.t()
  defp capability_name(:tools), do: "tool use"
  defp capability_name(:images), do: "image input"
  defp capability_name(:tool_result_images), do: "image tool results"
  defp capability_name(:streaming), do: "streaming"

  @spec join_names([String.t()]) :: String.t()
  defp join_names([name]), do: name
  defp join_names([first, second]), do: "#{first} and #{second}"

  defp join_names(names) do
    {last, rest} = List.pop_at(names, -1)
    Enum.join(rest, ", ") <> " and " <> last
  end

  @spec format_count(integer()) :: String.t()
  defp format_count(count) when count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M"
  end

  defp format_count(count) when count >= 1_000 do
    "#{Float.round(count / 1_000, 1)}K"
  end

  defp format_count(count), do: Integer.to_string(count)
end
