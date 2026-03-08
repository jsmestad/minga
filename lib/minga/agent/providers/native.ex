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

  require Logger

  alias Minga.Agent.Event
  alias Minga.Agent.Tools
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

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    model = Keyword.get(opts, :model, @default_model)
    thinking_level = Keyword.get(opts, :thinking_level, "off")
    project_root = Keyword.get(opts, :project_root) || detect_project_root()

    llm_client = Keyword.get(opts, :llm_client, &ReqLLM.stream_text/3)
    tools = Keyword.get(opts, :tools) || Tools.all(project_root: project_root)
    system_prompt = build_system_prompt(project_root)
    context = Context.new([Context.system(system_prompt)])

    state = %{
      subscriber: subscriber,
      model: model,
      context: context,
      tools: tools,
      project_root: project_root,
      thinking_level: thinking_level,
      llm_client: llm_client,
      task: nil,
      streaming: false
    }

    Logger.info("[Agent.Native] started with model=#{model} root=#{project_root}")

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
    Logger.info("[Agent.Native] aborted current operation")
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
    Logger.info("[Agent.Native] new session started")

    {:reply, :ok, state}
  end

  def handle_call(:get_state, _from, state) do
    session_state = %{
      model: %{
        id: state.model,
        name: state.model,
        provider: "native"
      },
      is_streaming: state.streaming,
      token_usage: nil
    }

    {:reply, {:ok, session_state}, state}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    if Map.has_key?(@thinking_levels, level) do
      Logger.info("[Agent.Native] thinking level set to #{level}")
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

    Logger.info("[Agent.Native] thinking level cycled to #{next_level}")
    {:reply, {:ok, %{"level" => next_level}}, %{state | thinking_level: next_level}}
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
    Logger.error("[Agent.Native] agent loop error: #{inspect(reason)}")
    notify(state.subscriber, %Event.Error{message: format_error(reason)})
    notify(state.subscriber, %Event.AgentEnd{usage: nil})
    {:noreply, %{state | task: nil, streaming: false}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # Task crashed
    Logger.error("[Agent.Native] agent task crashed: #{inspect(reason)}")
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
    stream_opts = build_stream_opts(lctx.tools, lctx.thinking_level)

    case lctx.llm_client.(lctx.model, context.messages, stream_opts) do
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
    send(lctx.provider_pid, {:agent_event, %Event.AgentEnd{usage: normalize_usage(usage)}})
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
    Enum.reduce(tool_calls, context, fn tool_call, ctx ->
      {result_text, is_error} = run_single_tool(tool_call, available_tools)

      # Emit tool end event
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

      # Append tool result to context for the next LLM call
      tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, result_text)
      Context.append(ctx, tool_result_msg)
    end)
  end

  @spec run_single_tool(map(), [ReqLLM.Tool.t()]) :: {String.t(), boolean()}
  defp run_single_tool(tool_call, available_tools) do
    case Enum.find(available_tools, fn t -> t.name == tool_call.name end) do
      nil ->
        {"Tool '#{tool_call.name}' not found", true}

      tool ->
        case ReqLLM.Tool.execute(tool, tool_call.arguments) do
          {:ok, result} -> {format_tool_result(result), false}
          {:error, reason} -> {format_error(reason), true}
        end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec build_stream_opts([ReqLLM.Tool.t()], String.t()) :: keyword()
  defp build_stream_opts(tools, thinking_level) do
    opts = [tools: tools]

    case Map.get(@thinking_levels, thinking_level) do
      budget when is_integer(budget) and budget > 0 ->
        Keyword.put(opts, :provider_options,
          additional_model_request_fields: %{
            thinking: %{type: "enabled", budget_tokens: budget}
          }
        )

      _ ->
        opts
    end
  end

  @spec build_system_prompt(String.t()) :: String.t()
  defp build_system_prompt(project_root) do
    agents_md = read_agents_md(project_root)

    """
    You are an AI coding assistant running inside Minga, a modal text editor. You help users by reading files, editing code, running shell commands, and writing new files.

    ## Available tools

    - read_file: Read file contents
    - write_file: Create or overwrite files (creates parent directories automatically)
    - edit_file: Make surgical edits (find exact text and replace). Read the file first to get exact text.
    - list_directory: List files and directories at a path
    - shell: Run shell commands in the project root

    ## Guidelines

    - Read files before editing them. The old_text in edit_file must match exactly.
    - Use shell for running tests, linters, git commands, etc.
    - Be concise and direct. Show file paths clearly when working with files.
    - When you make changes, verify them by reading the result or running tests.

    ## Environment

    - Project root: #{project_root}
    - Current time: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    #{if agents_md, do: "\n## Project Instructions\n\n#{agents_md}", else: ""}
    """
  end

  @spec read_agents_md(String.t()) :: String.t() | nil
  defp read_agents_md(project_root) do
    path = Path.join(project_root, "AGENTS.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
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

  @spec normalize_usage(map() | nil) :: Event.token_usage() | nil
  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input: Map.get(usage, :input_tokens, 0) || Map.get(usage, :input, 0),
      output: Map.get(usage, :output_tokens, 0) || Map.get(usage, :output, 0),
      cache_read: Map.get(usage, :cache_read_input_tokens, 0) || Map.get(usage, :cache_read, 0),
      cache_write:
        Map.get(usage, :cache_creation_input_tokens, 0) || Map.get(usage, :cache_write, 0),
      cost: Map.get(usage, :total_cost, 0.0) || 0.0
    }
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
