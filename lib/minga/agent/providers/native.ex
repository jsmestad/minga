defmodule Minga.Agent.Providers.Native do
  @moduledoc """
  Native Elixir agent provider backed by ReqLLM.

  Runs entirely inside the BEAM with no external dependencies. Supports any
  provider that ReqLLM supports (Anthropic, OpenAI, Ollama, Groq, Bedrock,
  etc.) by accepting a model string like `"anthropic:claude-sonnet-4-20250514"`.

  The provider manages conversation history via `ReqLLM.Context`, executes
  tools locally, and emits `Agent.Event` structs to its subscriber (the
  `Agent.Session`) for rendering in the chat panel.

  ## Architecture

  When `send_prompt/2` is called, the provider spawns a linked `Task` to run
  the agent turn loop. The loop:

  1. Calls `ReqLLM.stream_text/3` with the conversation history and tools
  2. Uses `StreamResponse.process_stream/2` with callbacks to emit events
     in real time as chunks arrive
  3. If the response contains tool calls, executes each tool, appends results
     to the conversation context, and loops back to step 1
  4. If no tool calls, the turn is complete

  The task sends events to the GenServer via `send/2`, and the GenServer
  forwards them to the subscriber. This keeps the GenServer responsive for
  abort and state queries while streaming is in progress.
  """

  @behaviour Minga.Agent.Provider

  use GenServer

  alias Minga.Agent.Compaction
  alias Minga.Agent.CostCalculator
  alias Minga.Agent.Credentials
  alias Minga.Agent.Event
  alias Minga.Agent.Instructions
  alias Minga.Agent.ModelCatalog
  alias Minga.Agent.ModelLimits
  alias Minga.Agent.Retry
  alias Minga.Agent.TokenEstimator
  alias Minga.Agent.Tools
  alias Minga.Agent.Tools.Shell
  alias Minga.Config.Options
  alias ReqLLM.Context
  alias ReqLLM.StreamResponse
  alias ReqLLM.ToolCall

  @default_model "anthropic:claude-sonnet-4-20250514"

  @thinking_levels %{
    "off" => 0,
    "low" => 4_096,
    "medium" => 16_384,
    "high" => 32_768
  }

  @thinking_cycle ["off", "low", "medium", "high"]

  @typedoc "Captures the immutable parameters for one agent turn loop invocation."
  @type loop_ctx :: %{
          provider_pid: pid(),
          model: String.t(),
          tools: [ReqLLM.Tool.t()],
          thinking_level: String.t(),
          max_tokens: pos_integer(),
          max_retries: non_neg_integer(),
          llm_client: llm_client()
        }

  @typedoc "Function that performs the LLM streaming call."
  @type llm_client :: (String.t(), [ReqLLM.Message.t()], keyword() ->
                         {:ok, StreamResponse.t()} | {:error, term()})

  @typedoc "Internal state for the native provider."
  @type state :: %{
          subscriber: pid(),
          model: String.t(),
          context: Context.t(),
          tools: [ReqLLM.Tool.t()],
          project_root: String.t(),
          thinking_level: String.t(),
          max_tokens: pos_integer(),
          max_retries: non_neg_integer(),
          llm_client: llm_client(),
          task: Task.t() | nil,
          streaming: boolean()
        }

  # ── Provider callbacks ──────────────────────────────────────────────────────

  @impl Minga.Agent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Minga.Agent.Provider
  @spec send_prompt(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_prompt(pid, text) when is_binary(text) do
    GenServer.call(pid, {:send_prompt, text})
  end

  @impl Minga.Agent.Provider
  @spec abort(GenServer.server()) :: :ok
  def abort(pid) do
    GenServer.call(pid, :abort)
  end

  @impl Minga.Agent.Provider
  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(pid) do
    GenServer.call(pid, :new_session)
  end

  @impl Minga.Agent.Provider
  @spec get_state(GenServer.server()) ::
          {:ok, Minga.Agent.Provider.session_state()} | {:error, term()}
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @impl Minga.Agent.Provider
  @spec set_thinking_level(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_thinking_level(pid, level) when is_binary(level) do
    GenServer.call(pid, {:set_thinking_level, level})
  end

  @impl Minga.Agent.Provider
  @spec cycle_thinking_level(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def cycle_thinking_level(pid) do
    GenServer.call(pid, :cycle_thinking_level)
  end

  @impl Minga.Agent.Provider
  @spec get_available_models(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_available_models(pid) do
    GenServer.call(pid, :get_available_models, 10_000)
  end

  @doc "Manually triggers context compaction."
  @spec compact(GenServer.server()) :: {:ok, String.t()} | {:error, String.t()}
  def compact(pid) do
    GenServer.call(pid, :compact, 30_000)
  end

  @impl Minga.Agent.Provider
  @spec cycle_model(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def cycle_model(pid) do
    GenServer.call(pid, :cycle_model)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    model = Keyword.get(opts, :model, @default_model)
    thinking_level = Keyword.get(opts, :thinking_level, "off")
    project_root = Keyword.get(opts, :project_root) || detect_project_root()

    max_tokens = Keyword.get(opts, :max_tokens) || read_config_max_tokens()
    max_retries = Keyword.get(opts, :max_retries) || read_config_max_retries()
    llm_client = Keyword.get(opts, :llm_client, &ReqLLM.stream_text/3)
    tools = Keyword.get(opts, :tools) || Tools.all(project_root: project_root)
    system_prompt = build_system_prompt(project_root)
    context = Context.new([Context.system(system_prompt)])

    # Resolve API key from credentials (env var or credentials file).
    # If found in the file but not in the env, set the env var so ReqLLM
    # picks it up automatically.
    ensure_api_key_in_env(model)

    state = %{
      subscriber: subscriber,
      model: model,
      context: context,
      tools: tools,
      project_root: project_root,
      thinking_level: thinking_level,
      max_tokens: max_tokens,
      max_retries: max_retries,
      llm_client: llm_client,
      task: nil,
      streaming: false
    }

    Minga.Log.info(:agent, "[Agent.Native] started with model=#{model} root=#{project_root}")

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send_prompt, _text}, _from, %{streaming: true} = state) do
    {:reply, {:error, :already_streaming}, state}
  end

  def handle_call({:send_prompt, text}, _from, state) do
    # Append user message to context
    context = Context.append(state.context, Context.user(text))
    state = %{state | context: context, streaming: true}

    # Notify subscriber that agent is starting
    notify(state.subscriber, %Event.AgentStart{})

    # Spawn the agent turn loop in a linked task
    lctx = %{
      provider_pid: self(),
      model: state.model,
      tools: state.tools,
      thinking_level: state.thinking_level,
      max_tokens: state.max_tokens,
      max_retries: state.max_retries,
      llm_client: state.llm_client
    }

    task =
      Task.async(fn ->
        run_agent_loop(lctx, context)
      end)

    state = %{state | task: task}

    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, %{task: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, state) do
    Task.shutdown(state.task, :brutal_kill)
    state = %{state | task: nil, streaming: false}
    Minga.Log.info(:agent, "[Agent.Native] aborted current operation")
    {:reply, :ok, state}
  end

  def handle_call(:new_session, _from, state) do
    # Kill any running task
    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    system_prompt = build_system_prompt(state.project_root)
    context = Context.new([Context.system(system_prompt)])

    state = %{state | context: context, task: nil, streaming: false}
    Minga.Log.info(:agent, "[Agent.Native] new session started")

    {:reply, :ok, state}
  end

  def handle_call(:get_state, _from, state) do
    system_prompt =
      case state.context.messages do
        [%{role: :system, content: content} | _] when is_binary(content) -> content
        _ -> nil
      end

    session_state = %{
      model: %{
        id: state.model,
        name: state.model,
        provider: "native"
      },
      is_streaming: state.streaming,
      token_usage: nil,
      system_prompt: system_prompt
    }

    {:reply, {:ok, session_state}, state}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    if Map.has_key?(@thinking_levels, level) do
      Minga.Log.info(:agent, "[Agent.Native] thinking level set to #{level}")
      {:reply, :ok, %{state | thinking_level: level}}
    else
      {:reply,
       {:error,
        "unknown thinking level: #{level}. Valid: #{inspect(Map.keys(@thinking_levels))}"}, state}
    end
  end

  def handle_call(:cycle_thinking_level, _from, state) do
    current_index = Enum.find_index(@thinking_cycle, &(&1 == state.thinking_level)) || 0
    next_index = rem(current_index + 1, length(@thinking_cycle))
    next_level = Enum.at(@thinking_cycle, next_index)

    Minga.Log.info(:agent, "[Agent.Native] thinking level cycled to #{next_level}")
    {:reply, {:ok, %{"level" => next_level}}, %{state | thinking_level: next_level}}
  end

  def handle_call(:get_available_models, _from, state) do
    models = ModelCatalog.available_models(state.model)
    {:reply, {:ok, models}, state}
  end

  def handle_call(:compact, _from, %{streaming: true} = state) do
    {:reply, {:error, "Cannot compact while streaming"}, state}
  end

  def handle_call(:compact, _from, state) do
    compact_opts = [
      model: state.model,
      llm_client: summary_client(state.llm_client)
    ]

    case Compaction.compact(state.context, compact_opts) do
      {:compacted, new_context, summary_info} ->
        notify(state.subscriber, %Event.TextDelta{delta: "\n📦 #{summary_info}\n"})
        {:reply, {:ok, summary_info}, %{state | context: new_context}}

      {:ok, _context} ->
        {:reply, {:ok, "Context is already small enough, no compaction needed."}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cycle_model, _from, state) do
    model_list = read_config_model_list()

    if model_list == [] do
      {:reply, {:error, "No model rotation configured. Set :agent_models in your config."}, state}
    else
      {next_model, next_thinking} = parse_model_entry(next_in_cycle(model_list, state.model))

      new_state = %{
        state
        | model: next_model,
          thinking_level: next_thinking || state.thinking_level,
          context: ReqLLM.Context.new(),
          tools: Minga.Agent.Tools.all(project_root: state.project_root),
          system_prompt: build_system_prompt(state.project_root)
      }

      total = length(model_list)
      index = Enum.find_index(model_list, &String.starts_with?(&1, next_model)) || 0

      {:reply, {:ok, %{"model" => next_model, "index" => index + 1, "total" => total}}, new_state}
    end
  end

  @impl GenServer
  def handle_info({:agent_event, event}, state) do
    # Forwarded from the task
    notify(state.subscriber, event)
    {:noreply, state}
  end

  def handle_info({:agent_context_update, context}, state) do
    # Task finished a turn and is sending us the updated context
    {:noreply, %{state | context: context}}
  end

  def handle_info({ref, :ok}, %{task: %Task{ref: ref}} = state) do
    # Task completed normally
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil, streaming: false}}
  end

  def handle_info({ref, {:error, reason}}, %{task: %Task{ref: ref}} = state) do
    # Task completed with an error
    Process.demonitor(ref, [:flush])
    Minga.Log.error(:agent, "[Agent.Native] agent loop error: #{inspect(reason)}")
    notify(state.subscriber, %Event.Error{message: format_error(reason)})
    notify(state.subscriber, %Event.AgentEnd{usage: nil})
    {:noreply, %{state | task: nil, streaming: false}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # Task crashed
    Minga.Log.error(:agent, "[Agent.Native] agent task crashed: #{inspect(reason)}")
    notify(state.subscriber, %Event.Error{message: "Agent task crashed: #{inspect(reason)}"})
    notify(state.subscriber, %Event.AgentEnd{usage: nil})
    {:noreply, %{state | task: nil, streaming: false}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Agent turn loop (runs in a Task) ────────────────────────────────────────

  @spec run_agent_loop(loop_ctx(), Context.t()) :: :ok | {:error, term()}
  defp run_agent_loop(lctx, context) do
    # Check if context needs compaction before the API call
    context = maybe_compact_context(lctx, context)

    stream_opts = build_stream_opts(lctx.model, lctx.tools, lctx.thinking_level, lctx.max_tokens)

    # Emit pre-send token estimate so the context bar updates before the API call
    emit_context_usage(lctx, context)

    on_retry = fn attempt, delay_ms, reason ->
      delay_s = Float.round(delay_ms / 1000, 1)

      send(
        lctx.provider_pid,
        {:agent_event,
         %Event.TextDelta{
           delta:
             "\n⏳ #{reason} — retrying in #{delay_s}s (attempt #{attempt}/#{lctx.max_retries})...\n"
         }}
      )
    end

    result =
      Retry.with_retry(
        fn -> lctx.llm_client.(lctx.model, context.messages, stream_opts) end,
        max_retries: lctx.max_retries,
        on_retry: on_retry
      )

    case result do
      {:ok, stream_response} ->
        process_and_continue(lctx, context, stream_response)

      {:error, reason} ->
        emit_error_and_end(lctx.provider_pid, format_error(reason))
        {:error, reason}
    end
  rescue
    e ->
      emit_error_and_end(lctx.provider_pid, Exception.message(e))
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      emit_error_and_end(lctx.provider_pid, inspect(reason))
      {:error, reason}
  end

  # Processes a stream response and decides whether to continue (tool calls) or finish.
  @spec process_and_continue(loop_ctx(), Context.t(), StreamResponse.t()) ::
          :ok | {:error, term()}
  defp process_and_continue(lctx, context, stream_response) do
    case StreamResponse.process_stream(stream_response,
           on_result: fn text ->
             send(lctx.provider_pid, {:agent_event, %Event.TextDelta{delta: text}})
           end,
           on_thinking: fn text ->
             send(lctx.provider_pid, {:agent_event, %Event.ThinkingDelta{delta: text}})
           end,
           on_tool_call: fn chunk ->
             send(
               lctx.provider_pid,
               {:agent_event,
                %Event.ToolStart{
                  tool_call_id:
                    Map.get(chunk.metadata, :id, "tool_#{:erlang.unique_integer([:positive])}"),
                  name: chunk.name || "unknown",
                  args: chunk.arguments || %{}
                }}
             )
           end
         ) do
      {:ok, response} ->
        tool_calls = extract_tool_calls(response)
        text = extract_text(response)
        usage = extract_usage(response)
        dispatch_result(lctx, context, tool_calls, text, usage)

      {:error, reason} ->
        emit_error_and_end(lctx.provider_pid, format_error(reason))
        {:error, reason}
    end
  end

  @spec dispatch_result(loop_ctx(), Context.t(), [map()], String.t(), map() | nil) ::
          :ok | {:error, term()}
  defp dispatch_result(lctx, context, [] = _tool_calls, text, usage) do
    # No tool calls: final answer
    updated_context = Context.append(context, Context.assistant(text))
    send(lctx.provider_pid, {:agent_context_update, updated_context})

    send(
      lctx.provider_pid,
      {:agent_event, %Event.AgentEnd{usage: normalize_usage(usage, lctx.model)}}
    )

    :ok
  end

  defp dispatch_result(lctx, context, tool_calls, text, _usage) do
    # Has tool calls: execute tools and continue the loop
    reqllm_tool_calls =
      Enum.map(tool_calls, fn tc ->
        ToolCall.new(tc.id, tc.name, Jason.encode!(tc.arguments))
      end)

    assistant_msg = Context.assistant(text, tool_calls: reqllm_tool_calls)
    context = Context.append(context, assistant_msg)

    context = execute_tools(lctx.provider_pid, context, tool_calls, lctx.tools)
    send(lctx.provider_pid, {:agent_context_update, context})

    # Continue the loop with updated context
    run_agent_loop(lctx, context)
  end

  @spec execute_tools(pid(), Context.t(), [map()], [ReqLLM.Tool.t()]) :: Context.t()
  defp execute_tools(provider_pid, context, tool_calls, available_tools) do
    initial_mode = approval_mode_from_config()

    {final_ctx, _mode} =
      Enum.reduce(tool_calls, {context, initial_mode}, fn tool_call, {ctx, approval_mode} ->
        before_content = capture_file_before(tool_call)

        {result_text, is_error, new_mode} =
          execute_with_approval(provider_pid, tool_call, available_tools, approval_mode)

        send(
          provider_pid,
          {:agent_event,
           %Event.ToolEnd{
             tool_call_id: tool_call.id,
             name: tool_call.name,
             result: result_text,
             is_error: is_error
           }}
        )

        maybe_emit_file_changed(provider_pid, tool_call, before_content, is_error)

        tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, result_text)
        {Context.append(ctx, tool_result_msg), new_mode}
      end)

    final_ctx
  end

  @typep approval_mode :: :none | :ask | :ask_all | :approve_all

  @spec execute_with_approval(pid(), map(), [ReqLLM.Tool.t()], approval_mode()) ::
          {String.t(), boolean(), approval_mode()}
  defp execute_with_approval(provider_pid, tool_call, available_tools, :none) do
    {result, is_error} = run_single_tool(tool_call, available_tools, provider_pid)
    {result, is_error, :none}
  end

  defp execute_with_approval(provider_pid, tool_call, available_tools, :approve_all) do
    {result, is_error} = run_single_tool(tool_call, available_tools, provider_pid)
    {result, is_error, :approve_all}
  end

  defp execute_with_approval(provider_pid, tool_call, available_tools, :ask_all) do
    request_approval(provider_pid, tool_call, available_tools)
  end

  defp execute_with_approval(provider_pid, tool_call, available_tools, :ask) do
    if Tools.destructive?(tool_call.name) do
      request_approval(provider_pid, tool_call, available_tools)
    else
      {result, is_error} = run_single_tool(tool_call, available_tools, provider_pid)
      {result, is_error, :ask}
    end
  end

  @spec approval_mode_from_config() :: approval_mode()
  defp approval_mode_from_config do
    case Options.get(:agent_tool_approval) do
      :none -> :none
      :all -> :ask_all
      :destructive -> :ask
    end
  rescue
    # Options agent not started (tests, standalone usage)
    _ -> :ask
  end

  @approval_timeout_ms 300_000

  @spec request_approval(pid(), map(), [ReqLLM.Tool.t()]) ::
          {String.t(), boolean(), :ask | :approve_all}
  defp request_approval(provider_pid, tool_call, available_tools) do
    # Send approval request through the event pipeline (Task → Provider → Session)
    send(
      provider_pid,
      {:agent_event,
       %Event.ToolApproval{
         tool_call_id: tool_call.id,
         name: tool_call.name,
         args: tool_call.arguments,
         reply_to: self()
       }}
    )

    # Block until the user responds (or timeout after 5 minutes)
    receive do
      {:tool_approval_response, _tool_call_id, :approve} ->
        {result, is_error} = run_single_tool(tool_call, available_tools, provider_pid)
        {result, is_error, :ask}

      {:tool_approval_response, _tool_call_id, :approve_all} ->
        {result, is_error} = run_single_tool(tool_call, available_tools, provider_pid)
        {result, is_error, :approve_all}

      {:tool_approval_response, _tool_call_id, :reject} ->
        {"Tool rejected by user", true, :ask}
    after
      @approval_timeout_ms ->
        {"Tool approval timed out", true, :ask}
    end
  end

  @file_tools ~w(edit_file write_file)

  @spec capture_file_before(map()) :: String.t() | nil
  defp capture_file_before(%{name: name, arguments: %{"path" => path}})
       when name in @file_tools do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp capture_file_before(_tool_call), do: nil

  @spec maybe_emit_file_changed(pid(), map(), String.t() | nil, boolean()) :: :ok
  defp maybe_emit_file_changed(provider_pid, tool_call, before_content, false = _is_error)
       when is_binary(before_content) do
    path = tool_call.arguments["path"]

    after_content =
      case File.read(path) do
        {:ok, content} -> content
        {:error, _} -> nil
      end

    if after_content && after_content != before_content do
      send(
        provider_pid,
        {:agent_event,
         %Event.ToolFileChanged{
           tool_call_id: tool_call.id,
           path: path,
           before_content: before_content,
           after_content: after_content
         }}
      )
    end

    :ok
  end

  defp maybe_emit_file_changed(_provider_pid, _tool_call, _before_content, _is_error), do: :ok

  @spec run_single_tool(map(), [ReqLLM.Tool.t()], pid() | nil) ::
          {String.t(), boolean()}
  defp run_single_tool(tool_call, available_tools, provider_pid) do
    case Enum.find(available_tools, fn t -> t.name == tool_call.name end) do
      nil ->
        {"Tool '#{tool_call.name}' not found", true}

      _tool when tool_call.name == "shell" and is_pid(provider_pid) ->
        run_shell_with_streaming(tool_call, provider_pid)

      tool ->
        case ReqLLM.Tool.execute(tool, tool_call.arguments) do
          {:ok, result} -> {format_tool_result(result), false}
          {:error, reason} -> {format_error(reason), true}
        end
    end
  end

  # Runs the shell tool with incremental output streaming via ToolUpdate events.
  @spec run_shell_with_streaming(map(), pid()) :: {String.t(), boolean()}
  defp run_shell_with_streaming(tool_call, provider_pid) do
    args = tool_call.arguments
    root = detect_project_root()
    timeout_secs = min(args["timeout"] || 30, 300)

    on_output = fn chunk ->
      send(
        provider_pid,
        {:agent_event,
         %Event.ToolUpdate{
           tool_call_id: tool_call.id,
           name: "shell",
           partial_result: chunk
         }}
      )

      :ok
    end

    case Shell.execute(args["command"], root, timeout_secs, on_output: on_output) do
      {:ok, result} -> {result, false}
      {:error, reason} -> {reason, true}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Checks if context needs compaction and performs it, notifying the subscriber.
  @spec maybe_compact_context(loop_ctx(), Context.t()) :: Context.t()
  defp maybe_compact_context(lctx, context) do
    compact_opts = [
      model: lctx.model,
      llm_client: summary_client(lctx.llm_client)
    ]

    case Compaction.maybe_compact(context, compact_opts) do
      {:compacted, new_context, summary_info} ->
        send(
          lctx.provider_pid,
          {:agent_event, %Event.TextDelta{delta: "\n📦 #{summary_info}\n"}}
        )

        send(lctx.provider_pid, {:agent_context_update, new_context})
        new_context

      {:ok, context} ->
        context
    end
  end

  # Wraps the streaming LLM client into a simpler function that returns {:ok, text}.
  # Used by the Compaction module which doesn't need streaming.
  @spec summary_client(llm_client()) :: Compaction.summary_fn()
  defp summary_client(llm_client) do
    fn model, messages, opts ->
      with {:ok, stream_response} <- llm_client.(model, messages, opts),
           {:ok, response} <- StreamResponse.process_stream(stream_response) do
        {:ok, ReqLLM.Response.text(response) || ""}
      end
    end
  end

  @spec build_stream_opts(String.t(), [ReqLLM.Tool.t()], String.t(), pos_integer()) :: keyword()
  defp build_stream_opts(model, tools, thinking_level, max_tokens) do
    opts = [tools: tools, max_tokens: max_tokens]

    # Enable Anthropic prompt caching when the model is Anthropic
    opts =
      if anthropic_model?(model) and prompt_cache_enabled?() do
        Keyword.put(opts, :provider_options, anthropic_prompt_cache: true)
      else
        opts
      end

    case Map.get(@thinking_levels, thinking_level) do
      budget when is_integer(budget) and budget > 0 ->
        # Merge thinking config into existing provider_options
        existing = Keyword.get(opts, :provider_options, [])

        merged =
          Keyword.merge(existing,
            additional_model_request_fields: %{
              thinking: %{type: "enabled", budget_tokens: budget}
            }
          )

        Keyword.put(opts, :provider_options, merged)

      _ ->
        opts
    end
  end

  @spec anthropic_model?(String.t()) :: boolean()
  defp anthropic_model?(model) do
    String.starts_with?(model, "anthropic:") or
      not String.contains?(model, ":")
  end

  @spec prompt_cache_enabled?() :: boolean()
  defp prompt_cache_enabled? do
    Options.get(:agent_prompt_cache)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  @spec build_system_prompt(String.t()) :: String.t()
  defp build_system_prompt(project_root) do
    base = resolve_base_prompt(project_root)
    instructions = Instructions.assemble(project_root)
    append = read_config_string(:agent_append_system_prompt)

    parts =
      [base, instructions, append]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    parts
  end

  @default_system_prompt_template """
  You are an AI coding assistant running inside Minga, a modal text editor. You help users by reading files, editing code, running shell commands, and writing new files.

  ## Available tools

  - read_file: Read file contents
  - write_file: Create or overwrite files (creates parent directories automatically)
  - edit_file: Make surgical edits (find exact text and replace). Read the file first to get exact text.
  - list_directory: List files and directories at a path
  - find: Find files by name or glob pattern. Prefer this over shell + find.
  - grep: Search file contents for a pattern. Returns file:line:content. Prefer this over shell + grep.
  - shell: Run shell commands in the project root

  ## Guidelines

  - Read files before editing them. The old_text in edit_file must match exactly.
  - Use find to discover files by name or extension, and grep to search file contents.
  - Use shell for running tests, linters, git commands, etc.
  - Be concise and direct. Show file paths clearly when working with files.
  - When you make changes, verify them by reading the result or running tests.
  """

  # Returns the base system prompt: either from config or the default template.
  # Config value can be a string prompt or a file path.
  @spec resolve_base_prompt(String.t()) :: String.t()
  defp resolve_base_prompt(project_root) do
    custom = read_config_string(:agent_system_prompt)

    base =
      if custom != "" do
        resolve_prompt_value(custom, project_root)
      else
        @default_system_prompt_template
      end

    # Always append environment info
    base <>
      "\n## Environment\n\n" <>
      "- Project root: #{project_root}\n" <>
      "- Current time: #{DateTime.utc_now() |> DateTime.to_iso8601()}"
  end

  # If the value looks like a file path, read it. Otherwise return as-is.
  @spec resolve_prompt_value(String.t(), String.t()) :: String.t()
  defp resolve_prompt_value(value, project_root) do
    expanded = expand_path(value, project_root)

    if File.regular?(expanded) do
      File.read!(expanded)
    else
      value
    end
  end

  @spec expand_path(String.t(), String.t()) :: String.t()
  defp expand_path("~/" <> rest, _project_root) do
    Path.join(System.user_home!(), rest)
  end

  defp expand_path(path, project_root) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(project_root, path)
    end
  end

  @spec read_config_string(atom()) :: String.t()
  defp read_config_string(key) do
    case Options.get(key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  # Sets the provider's API key env var if it's stored in the credentials
  # file but not yet in the environment. This lets ReqLLM find the key
  # without us having to thread it through every call.
  @spec ensure_api_key_in_env(String.t()) :: :ok
  defp ensure_api_key_in_env(model) do
    provider = Credentials.provider_from_model(model)

    case Credentials.resolve(provider) do
      {:ok, key, :file} ->
        # Key is in the credentials file but not in env; set it
        case Credentials.env_var_for(provider) do
          nil -> :ok
          var_name -> System.put_env(var_name, key)
        end

        :ok

      {:ok, _key, :env} ->
        # Already in env, nothing to do
        :ok

      :error ->
        # No key anywhere. The provider will fail on the first API call
        # with a clear error from the API (e.g. "authentication_error").
        Minga.Log.warning(
          :agent,
          "[Agent.Native] No API key found for #{provider}. " <>
            "Use /auth to configure one, or set #{Credentials.env_var_for(provider) || "the provider's env var"}."
        )

        :ok
    end
  end

  @default_max_tokens 16_384

  @spec read_config_max_tokens() :: pos_integer()
  defp read_config_max_tokens do
    Options.get(:agent_max_tokens)
  rescue
    _ -> @default_max_tokens
  catch
    :exit, _ -> @default_max_tokens
  end

  @default_max_retries 3

  @spec read_config_max_retries() :: non_neg_integer()
  defp read_config_max_retries do
    Options.get(:agent_max_retries)
  rescue
    _ -> @default_max_retries
  catch
    :exit, _ -> @default_max_retries
  end

  @spec read_config_model_list() :: [String.t()]
  defp read_config_model_list do
    Options.get(:agent_models)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Finds the next entry in the cycle after the current model.
  @spec next_in_cycle([String.t()], String.t()) :: String.t()
  defp next_in_cycle(model_list, current_model) do
    current_index =
      Enum.find_index(model_list, &String.starts_with?(&1, current_model)) || -1

    next_index = rem(current_index + 1, length(model_list))
    Enum.at(model_list, next_index)
  end

  # Parses "provider:model:thinking_level" or "provider:model" into {model_str, thinking | nil}.
  @spec parse_model_entry(String.t()) :: {String.t(), String.t() | nil}
  defp parse_model_entry(entry) do
    case String.split(entry, ":") do
      [provider, model, thinking] -> {"#{provider}:#{model}", thinking}
      _ -> {entry, nil}
    end
  end

  @spec detect_project_root() :: String.t()
  defp detect_project_root do
    case Minga.Project.root() do
      nil -> File.cwd!()
      root -> root
    end
  rescue
    _ -> File.cwd!()
  catch
    :exit, _ -> File.cwd!()
  end

  # Estimates token usage for the current context and emits a ContextUsage event.
  # The model name is stripped of the provider prefix for ModelLimits lookup.
  @spec emit_context_usage(loop_ctx(), Context.t()) :: :ok
  defp emit_context_usage(lctx, context) do
    estimated = TokenEstimator.estimate(context.messages)
    model_name = strip_provider_prefix(lctx.model)
    context_limit = ModelLimits.context_limit(model_name)

    send(
      lctx.provider_pid,
      {:agent_event,
       %Event.ContextUsage{
         estimated_tokens: estimated,
         context_limit: context_limit
       }}
    )

    :ok
  end

  @spec strip_provider_prefix(String.t()) :: String.t()
  defp strip_provider_prefix(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, name] -> name
      [name] -> name
    end
  end

  @spec emit_error_and_end(pid(), String.t()) :: :ok
  defp emit_error_and_end(provider_pid, message) do
    send(provider_pid, {:agent_event, %Event.Error{message: message}})
    send(provider_pid, {:agent_event, %Event.AgentEnd{usage: nil}})
    :ok
  end

  @spec extract_tool_calls(ReqLLM.Response.t()) :: [map()]
  defp extract_tool_calls(%{message: %{tool_calls: nil}}), do: []

  defp extract_tool_calls(%{message: %{tool_calls: tool_calls}}) when is_list(tool_calls) do
    Enum.map(tool_calls, &ToolCall.to_map/1)
  end

  defp extract_tool_calls(_), do: []

  @spec extract_text(ReqLLM.Response.t()) :: String.t()
  defp extract_text(%{message: %{content: content}}) when is_list(content) do
    content
    |> Enum.filter(fn part -> Map.get(part, :type, :text) == :text end)
    |> Enum.map_join("", fn part -> Map.get(part, :text, "") end)
  end

  defp extract_text(_), do: ""

  @spec extract_usage(ReqLLM.Response.t()) :: map() | nil
  defp extract_usage(%{usage: usage}) when is_map(usage), do: usage
  defp extract_usage(_), do: nil

  @spec normalize_usage(map() | nil, String.t()) :: Event.token_usage() | nil
  defp normalize_usage(nil, _model), do: nil

  defp normalize_usage(usage, model) when is_map(usage) do
    normalized = %{
      input: Map.get(usage, :input_tokens, 0) || Map.get(usage, :input, 0),
      output: Map.get(usage, :output_tokens, 0) || Map.get(usage, :output, 0),
      cache_read: Map.get(usage, :cache_read_input_tokens, 0) || Map.get(usage, :cache_read, 0),
      cache_write:
        Map.get(usage, :cache_creation_input_tokens, 0) || Map.get(usage, :cache_write, 0),
      cost: Map.get(usage, :total_cost, 0.0) || 0.0
    }

    {provider_atom, model_id} = parse_model_string(model)
    CostCalculator.ensure_cost(normalized, model_id, provider_atom)
  end

  @spec parse_model_string(String.t()) :: {atom(), String.t()}
  defp parse_model_string(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] -> {String.to_existing_atom(provider), id}
      _ -> {:unknown, model}
    end
  rescue
    ArgumentError -> {:unknown, model}
  end

  @spec format_tool_result(term()) :: String.t()
  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: Jason.encode!(result)

  defp format_tool_result(result), do: inspect(result)

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(reason), do: inspect(reason)

  @spec notify(pid(), Event.t()) :: Event.t()
  defp notify(subscriber, event) do
    send(subscriber, {:agent_provider_event, event})
    event
  end
end
