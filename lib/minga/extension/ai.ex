defmodule Minga.Extension.AI do
  @moduledoc """
  Sanctioned text-generation helper for extensions.

  Wraps provider/config resolution and streaming so extensions generate
  text without importing core LLM internals (`ReqLLM`, `MingaAgent.*`).
  The user's configured model is used by default.

  Two entry points:

    * `stream/2` — async; streams chunks to `reply_to` and never blocks the
      caller. Use this for UI that fills in as text arrives.
    * `complete/2` — convenience one-shot that blocks the calling process
      until the full text is ready. Never call it from the editor loop.

  Public types stay plain (maps, strings, tagged tuples); no provider
  structs leak across this boundary.
  """

  alias MingaAgent.Config
  alias MingaAgent.ProviderResolver

  @default_max_tokens 1024

  @typedoc ~S(A chat message. `role` is "system", "user", or "assistant".)
  @type message :: %{role: String.t(), content: String.t()}

  @typedoc """
  Options:
    * `:system` — system prompt prepended to the messages
    * `:max_tokens` — generation cap (default #{@default_max_tokens})
    * `:model` — override the configured model (default: user's model)
    * `:reply_to` — where `stream/2` sends events (default: `self()`)
  """
  @type opts :: keyword()

  @type error :: :empty_response | {:provider_error, term()}

  @typedoc "Events delivered to `reply_to` by `stream/2`, tagged with the call's `ref`."
  @type event :: {:chunk, String.t()} | {:done, String.t()} | {:error, error()}

  @doc """
  Generates text asynchronously, streaming chunks to `reply_to`.

  Returns `{:ok, ref}` immediately. The caller then receives, in order:
  `{:minga_ai, ref, {:chunk, text}}` for each delta, then a single
  `{:minga_ai, ref, {:done, full_text}}` (or `{:error, reason}`). Provider
  failures are reported through that error event, not the return value.
  """
  @spec stream([message()], opts()) :: {:ok, reference()}
  def stream(messages, opts \\ []) when is_list(messages) do
    reply_to = Keyword.get(opts, :reply_to, self())
    {model, req_messages, stream_opts, client} = prepare(messages, opts)
    ref = make_ref()

    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      run_stream(client, model, req_messages, stream_opts, reply_to, ref)
    end)

    {:ok, ref}
  end

  @doc """
  Generates text and blocks the calling process until it is complete.

  Returns `{:ok, full_text}` or `{:error, reason}`. Safe to call from an
  extension's own process; never from the editor loop.
  """
  @spec complete([message()], opts()) :: {:ok, String.t()} | {:error, error()}
  def complete(messages, opts \\ []) when is_list(messages) do
    {model, req_messages, stream_opts, client} = prepare(messages, opts)

    with {:ok, stream_response} <- request(client, model, req_messages, stream_opts) do
      collect_text(stream_response)
    end
  end

  @spec prepare([message()], opts()) :: {String.t(), [message()], keyword(), function()}
  defp prepare(messages, opts) do
    model = resolve_model(opts)
    config = Config.resolve()
    client = Keyword.get(opts, :client, &ReqLLM.stream_text/3)

    stream_opts =
      [max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)]
      |> maybe_add_base_url(config)

    {model, prepend_system(messages, opts), stream_opts, client}
  end

  @spec resolve_model(opts()) :: String.t()
  defp resolve_model(opts) do
    Keyword.get(opts, :model) || ProviderResolver.configured_model() || Config.default_model()
  end

  @spec prepend_system([message()], opts()) :: [message()]
  defp prepend_system(messages, opts) do
    case Keyword.get(opts, :system) do
      system when is_binary(system) and system != "" ->
        [%{role: "system", content: system} | messages]

      _ ->
        messages
    end
  end

  @spec run_stream(function(), String.t(), [message()], keyword(), pid(), reference()) :: :ok
  defp run_stream(client, model, messages, stream_opts, reply_to, ref) do
    case request(client, model, messages, stream_opts) do
      {:ok, stream_response} ->
        full =
          stream_response
          |> ReqLLM.StreamResponse.tokens()
          |> Enum.reduce("", fn delta, acc ->
            send(reply_to, {:minga_ai, ref, {:chunk, delta}})
            acc <> delta
          end)

        case String.trim(full) do
          "" -> send(reply_to, {:minga_ai, ref, {:error, :empty_response}})
          text -> send(reply_to, {:minga_ai, ref, {:done, text}})
        end

      {:error, reason} ->
        send(reply_to, {:minga_ai, ref, {:error, reason}})
    end

    :ok
  end

  @spec collect_text(ReqLLM.StreamResponse.t()) :: {:ok, String.t()} | {:error, error()}
  defp collect_text(stream_response) do
    case String.trim(ReqLLM.StreamResponse.text(stream_response) || "") do
      "" -> {:error, :empty_response}
      text -> {:ok, text}
    end
  rescue
    e -> {:error, {:provider_error, Exception.message(e)}}
  end

  @spec request(function(), String.t(), [message()], keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, error()}
  defp request(client, model, messages, stream_opts) do
    case client.(model, messages, stream_opts) do
      {:ok, stream_response} -> {:ok, stream_response}
      {:error, reason} -> {:error, {:provider_error, reason}}
    end
  rescue
    e -> {:error, {:provider_error, Exception.message(e)}}
  end

  @spec maybe_add_base_url(keyword(), Config.t()) :: keyword()
  defp maybe_add_base_url(opts, config) do
    case non_empty(config.api_base_url_override) || non_empty(config.api_base_url) do
      nil -> opts
      url -> Keyword.put(opts, :base_url, url)
    end
  end

  @spec non_empty(String.t() | nil) :: String.t() | nil
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(s) when is_binary(s), do: s
end
