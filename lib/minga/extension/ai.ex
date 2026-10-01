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
  alias MingaAgent.Credentials
  alias MingaAgent.ModelResolver

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
  @typep prepared_request :: {LLMDB.Model.t(), [message()], keyword(), function()}

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
    ref = make_ref()

    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      messages
      |> prepare(opts)
      |> run_stream(reply_to, ref)
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
    with {:ok, {model, req_messages, stream_opts, client}} <- prepare(messages, opts),
         {:ok, stream_response} <- request(client, model, req_messages, stream_opts) do
      collect_text(stream_response)
    end
  end

  @spec prepare([message()], opts()) :: {:ok, prepared_request()} | {:error, error()}
  defp prepare(messages, opts) do
    config = Keyword.get_lazy(opts, :config, &Config.resolve/0)
    credentials_opts = Keyword.get(opts, :credentials_opts, [])
    resolver_opts = resolver_opts(config, credentials_opts)

    with {:ok, selection} <- ModelResolver.resolve(resolve_model(opts, config), resolver_opts),
         {:ok, credential_opts} <-
           Credentials.request_options(selection.credential, credentials_opts) do
      request_opts =
        Keyword.put_new(
          credential_opts,
          :max_tokens,
          Keyword.get(opts, :max_tokens, @default_max_tokens)
        )

      {:ok,
       {selection.request_model, prepend_system(messages, opts), request_opts,
        Keyword.get(opts, :client, &ReqLLM.stream_text/3)}}
    else
      {:error, reason} -> {:error, {:provider_error, reason}}
    end
  end

  @spec resolver_opts(Config.t(), keyword()) :: keyword()
  defp resolver_opts(config, credentials_opts),
    do: [config: config, credential_snapshot: Credentials.snapshot(credentials_opts)]

  @spec resolve_model(opts(), Config.t()) :: ModelResolver.intent()
  defp resolve_model(opts, config) do
    Keyword.get(opts, :model) || config.selection_intent || config.model
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

  @spec run_stream({:ok, prepared_request()} | {:error, error()}, pid(), reference()) :: :ok
  defp run_stream({:ok, {model, messages, stream_opts, client}}, reply_to, ref) do
    client
    |> request(model, messages, stream_opts)
    |> deliver_stream_result(reply_to, ref)

    :ok
  end

  defp run_stream({:error, reason}, reply_to, ref) do
    deliver_stream_result({:error, reason}, reply_to, ref)
  end

  @spec deliver_stream_result(
          {:ok, ReqLLM.StreamResponse.t()} | {:error, error()},
          pid(),
          reference()
        ) :: :ok
  defp deliver_stream_result({:ok, stream_response}, reply_to, ref) do
    stream_response
    |> consume_stream(reply_to, ref)
    |> deliver_consumed_stream(reply_to, ref)
  end

  defp deliver_stream_result({:error, reason}, reply_to, ref) do
    send(reply_to, {:minga_ai, ref, {:error, reason}})
    :ok
  end

  @spec deliver_consumed_stream({:ok, String.t()} | {:error, error()}, pid(), reference()) :: :ok
  defp deliver_consumed_stream({:ok, full}, reply_to, ref) do
    full
    |> stream_done_event()
    |> then(&send(reply_to, {:minga_ai, ref, &1}))

    :ok
  end

  defp deliver_consumed_stream({:error, reason}, reply_to, ref) do
    send(reply_to, {:minga_ai, ref, {:error, reason}})
    :ok
  end

  @spec stream_done_event(String.t()) :: {:done, String.t()} | {:error, :empty_response}
  defp stream_done_event(full) do
    case String.trim(full) do
      "" -> {:error, :empty_response}
      text -> {:done, text}
    end
  end

  @spec consume_stream(ReqLLM.StreamResponse.t(), pid(), reference()) ::
          {:ok, String.t()} | {:error, error()}
  defp consume_stream(stream_response, reply_to, ref) do
    full =
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce("", fn delta, acc ->
        send(reply_to, {:minga_ai, ref, {:chunk, delta}})
        acc <> delta
      end)

    {:ok, full}
  rescue
    e -> {:error, {:provider_error, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:provider_error, {kind, reason}}}
  end

  @spec collect_text(ReqLLM.StreamResponse.t()) :: {:ok, String.t()} | {:error, error()}
  defp collect_text(stream_response) do
    case stream_response |> ReqLLM.StreamResponse.text() |> String.trim() do
      "" -> {:error, :empty_response}
      text -> {:ok, text}
    end
  rescue
    e -> {:error, {:provider_error, Exception.message(e)}}
  end

  @spec request(function(), LLMDB.Model.t(), [message()], keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, error()}
  defp request(client, model, messages, stream_opts) do
    case client.(model, messages, stream_opts) do
      {:ok, stream_response} -> {:ok, stream_response}
      {:error, reason} -> {:error, {:provider_error, reason}}
    end
  rescue
    e -> {:error, {:provider_error, Exception.message(e)}}
  end
end
