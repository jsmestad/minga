defmodule Minga.Extension.Instance.Contributions do
  @moduledoc "Registration, callback admission, finalization, and cleanup for one Instance."

  alias Minga.Command
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Instance.Artifact
  alias Minga.Log

  @type result :: :ok | {:error, term()}

  @doc "Runs setup callbacks which must complete before a runtime child starts."
  @spec prepare_runtime(atom(), Artifact.t(), keyword(), keyword()) :: result()
  def prepare_runtime(name, artifact, config, opts) do
    with :ok <- register_options(name, artifact.module, config),
         {:ok, _setup} <- call_init(artifact.module, config) do
      register_modeline_segments(artifact.module, name, opts)
    end
  end

  @doc "Registers all runtime contributions after the child is alive."
  @spec register_runtime(atom(), Artifact.t(), keyword()) :: result()
  def register_runtime(name, artifact, opts) do
    command_registry = Keyword.get(opts, :command_registry, Minga.Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

    with :ok <- register_commands(artifact.module, name, command_registry, opts),
         :ok <- register_keybinds(artifact.module, name, keymap),
         :ok <- register_event_handlers(artifact.module, name, opts) do
      CodeLease.activate_source(artifact.source, artifact.owned_modules, server: code_lease(opts))
    end
  end

  @doc "Registers lazy command/key stubs which activate through the captured Instance."
  @spec register_stub(
          GenServer.server(),
          atom(),
          Minga.Extension.Entry.t(),
          Artifact.t(),
          keyword(),
          keyword()
        ) :: result()
  def register_stub(instance, name, declaration, artifact, config, opts) do
    command_registry = Keyword.get(opts, :command_registry, Command.Registry)
    keymap = Keyword.get(opts, :keymap, Minga.Keymap.Active)

    with :ok <- register_options(name, artifact.module, config),
         :ok <-
           register_stub_commands(instance, name, declaration, artifact.module, command_registry) do
      register_stub_keybinds(name, artifact.module, keymap)
    end
  end

  @doc "Runs one source finalizer inside an Instance-owned bounded worker."
  @spec finalize(atom(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def finalize(name, family, context, opts) do
    source = {:extension, name}
    cleanup_opts = opts |> Keyword.take([:callbacks]) |> Keyword.put(:context, context)

    lifecycle_span(name, :quiesce, fn ->
      ContributionCleanup.finalize_source(source, family, cleanup_opts)
    end)
  end

  @doc "Removes all source-owned contributions exactly once per cleanup attempt."
  @spec cleanup(atom(), keyword()) :: :ok | {:error, [map()]}
  def cleanup(name, opts) do
    source = {:extension, name}

    callback_registry =
      Keyword.get(opts, :callback_registry, Minga.Extension.CallbackRegistry.default_table())

    callbacks =
      opts
      |> Keyword.get(:callbacks, %{})
      |> Map.put_new(:callback_registry, fn cleanup_source ->
        Minga.Extension.CallbackRegistry.unregister_source(cleanup_source, callback_registry)
      end)
      |> ContributionCleanup.merge_callbacks()

    cleanup_opts = [
      command_registry: Keyword.get(opts, :command_registry, Minga.Command.Registry),
      keymap: Keyword.get(opts, :keymap, Minga.Keymap.Active),
      callbacks: callbacks
    ]

    lifecycle_span(name, :cleanup, fn ->
      ContributionCleanup.unregister_source(source, cleanup_opts)
    end)
  end

  @spec lifecycle_span(atom(), atom(), (-> result)) :: result when result: var
  defp lifecycle_span(name, phase, fun) do
    Minga.Telemetry.span_with_stop_metadata(
      [:minga, :extension, :lifecycle],
      %{extension: name, phase: phase},
      fn ->
        result = fun.()
        metadata = if match?({:error, _}, result), do: %{outcome: :error}, else: %{outcome: :ok}
        {result, metadata}
      end
    )
  end

  @doc "Runs extension option validation."
  @spec register_options(atom(), module(), keyword()) :: result()
  def register_options(name, module, config) do
    if function_exported?(module, :__option_schema__, 0) do
      Minga.Config.register_extension_schema(name, module.__option_schema__(), config)
    else
      :ok
    end
  rescue
    error -> {:error, "__option_schema__/0 crashed: #{Exception.message(error)}"}
  end

  @spec call_init(module(), keyword()) :: {:ok, term()} | {:error, term()}
  defp call_init(module, config) do
    case module.init(config) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, "init failed: #{inspect(reason)}"}
      other -> {:error, "init returned unexpected value: #{inspect(other)}"}
    end
  rescue
    error -> {:error, "init crashed: #{Exception.message(error)}"}
  end

  @spec register_commands(module(), atom(), GenServer.server(), keyword()) :: result()
  defp register_commands(module, name, registry, opts) do
    Enum.reduce_while(schema(module, :__command_schema__), :ok, fn spec, :ok ->
      command = command_from_spec(spec, name, opts)

      case Command.Registry.register_command(registry, {:extension, name}, command) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  rescue
    error -> {:error, {:command_registration_failed, Exception.message(error)}}
  end

  @spec command_from_spec(Minga.Extension.command_spec(), atom(), keyword()) :: Command.t()
  defp command_from_spec({name, description, command_opts}, extension, opts) do
    {module, function} = Keyword.fetch!(command_opts, :execute)
    admission = code_lease(opts)

    %Command{
      name: name,
      description: description,
      requires_buffer: Keyword.get(command_opts, :requires_buffer, false),
      execute: fn state ->
        source = {:extension, extension}
        result = CallbackInvoker.invoke(source, module, function, [state], :command, admission)
        {:extension_callback, source, module, function, result}
      end
    }
  end

  @spec register_modeline_segments(module(), atom(), keyword()) :: result()
  defp register_modeline_segments(module, extension, opts) do
    Enum.reduce_while(schema(module, :__modeline_segment_schema__), :ok, fn
      {name, segment_opts, {callback_module, callback_function}}, :ok ->
        callback =
          modeline_callback(extension, callback_module, callback_function, code_lease(opts))

        case Minga.Config.ModelineSegments.register(
               name,
               segment_opts,
               callback,
               {:extension, extension}
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:modeline_segment_rejected, name, reason}}}
        end
    end)
  rescue
    error -> {:error, {:modeline_segment_registration_failed, Exception.message(error)}}
  end

  @spec modeline_callback(atom(), module(), atom(), GenServer.server()) :: (map() -> term())
  defp modeline_callback(extension, module, function, admission) do
    fn context ->
      source = {:extension, extension}

      result =
        CallbackInvoker.invoke(source, module, function, [context], :modeline_segment, admission)

      {:extension_callback, source, module, function, result}
    end
  end

  @spec register_keybinds(module(), atom(), GenServer.server()) :: result()
  defp register_keybinds(module, extension, keymap) do
    Enum.reduce_while(schema(module, :__keybind_schema__), :ok, fn
      {mode, key, command, description, bind_opts}, :ok ->
        case Minga.Keymap.Active.bind(
               keymap,
               mode,
               key,
               command,
               description,
               Keyword.put(bind_opts, :source, {:extension, extension})
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:keybind_registration_failed, key, reason}}}
        end
    end)
  rescue
    error -> {:error, {:keybind_registration_failed, :schema, Exception.message(error)}}
  end

  @spec register_event_handlers(module(), atom(), keyword()) :: result()
  defp register_event_handlers(module, name, opts) do
    CallbackRegistry.register_extension(name, schema(module, :__editor_event_handler_schema__),
      registry: Keyword.get(opts, :callback_registry, CallbackRegistry.default_table()),
      artifact_admission: Keyword.get(opts, :artifact_admission, ArtifactAdmission)
    )
  end

  @spec register_stub_commands(
          GenServer.server(),
          atom(),
          Minga.Extension.Entry.t(),
          module(),
          GenServer.server()
        ) :: result()
  defp register_stub_commands(instance, extension, declaration, module, registry) do
    Enum.reduce_while(schema(module, :__command_schema__), :ok, fn
      {name, description, command_opts}, :ok ->
        requires_buffer = Keyword.get(command_opts, :requires_buffer, false)

        command = %Command{
          name: name,
          description: description,
          requires_buffer: requires_buffer,
          execute: fn state ->
            case safe_lazy_start(instance, declaration, extension) do
              {:ok, _pid} -> execute_autoloaded(registry, extension, name, state)
              {:error, _reason} -> state
            end
          end
        }

        case Command.Registry.register_command(registry, {:extension, extension}, command) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:stub_command_rejected, name, reason}}}
        end
    end)
  end

  @spec safe_lazy_start(GenServer.server(), Minga.Extension.Entry.t(), atom()) ::
          {:ok, pid()} | {:error, term()}
  defp safe_lazy_start(instance, declaration, extension) do
    case Minga.Extension.Instance.start_deferred(instance, declaration) do
      {:ok, _pid} = started ->
        started

      {:error, reason} = error ->
        Log.warning(:config, "Extension #{extension} lazy activation failed: #{inspect(reason)}")
        error
    end
  catch
    :exit, reason ->
      failure = {:authority_call_exit, extension, reason}
      Log.warning(:config, "Extension #{extension} lazy activation failed: #{inspect(failure)}")
      {:error, failure}
  end

  @spec execute_autoloaded(GenServer.server(), atom(), atom(), term()) :: term()
  defp execute_autoloaded(registry, extension, name, state) do
    case Command.Registry.lookup(registry, name) do
      {:ok, command} ->
        command.execute.(state)

      :error ->
        Log.warning(
          :config,
          "Extension #{extension} lazy activation missing command #{name} after start"
        )

        state
    end
  rescue
    error ->
      reason = {:command_activation_exception, Exception.message(error)}
      log_lazy_command_failure(extension, name, reason)
      state
  catch
    :exit, reason ->
      log_lazy_command_failure(extension, name, {:command_activation_exit, reason})
      state

    kind, reason ->
      log_lazy_command_failure(extension, name, {kind, reason})
      state
  end

  @spec log_lazy_command_failure(atom(), atom(), term()) :: :ok
  defp log_lazy_command_failure(extension, name, reason) do
    Log.warning(
      :config,
      "Extension #{extension} lazy command #{name} failed: #{inspect(reason)}"
    )
  end

  @spec register_stub_keybinds(atom(), module(), GenServer.server()) :: result()
  defp register_stub_keybinds(extension, module, keymap) do
    register_keybinds(module, extension, keymap)
  end

  @spec schema(module(), atom()) :: [term()]
  defp schema(module, function) do
    if function_exported?(module, function, 0), do: apply(module, function, []), else: []
  end

  @spec code_lease(keyword()) :: GenServer.server()
  defp code_lease(opts), do: Keyword.get(opts, :code_lease, CodeLease)
end
