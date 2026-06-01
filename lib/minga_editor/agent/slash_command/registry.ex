defmodule MingaEditor.Agent.SlashCommand.Registry do
  @moduledoc """
  Source-owned registry for extension-contributed agent slash commands.

  Built-in slash commands remain static in `MingaEditor.Agent.SlashCommand`. Extension declarations are stored here so cleanup and reload no longer depend on scanning running manifests.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Manifest
  alias MingaEditor.Agent.SlashCommand.Command

  @typedoc "Source that contributed slash commands."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Registry entry for one slash command."
  @type entry :: %{
          source: source(),
          id: String.t(),
          command: Command.t()
        }

  @type state :: [entry()]

  @doc "Starts the slash command registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc "Registers a source-owned batch of slash command declarations. Same-source batches replace prior entries."
  @spec register_many(source(), [{atom() | String.t(), String.t(), keyword()}], keyword()) :: :ok
  def register_many(source, commands, opts \\ []) when is_list(commands) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register_many, source, commands})
  end

  @doc "Removes all slash commands owned by a source."
  @spec unregister_source(source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  @doc false
  @spec unregister_source(GenServer.server(), source()) :: :ok
  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Returns all registered extension slash commands in deterministic registration order."
  @spec commands() :: [Command.t()]
  def commands, do: commands(__MODULE__)

  @doc false
  @spec commands(GenServer.server()) :: [Command.t()]
  def commands(server) do
    GenServer.call(server, :commands)
  catch
    :exit, _ -> []
  end

  @doc "Returns registry entries in deterministic registration order."
  @spec entries() :: [entry()]
  def entries, do: entries(__MODULE__)

  @doc false
  @spec entries(GenServer.server()) :: [entry()]
  def entries(server) do
    GenServer.call(server, :entries)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    Minga.Events.subscribe(:extension_agent_contributions_started)
    ContributionCleanup.register(:agent_slash_command_registry, &__MODULE__.unregister_source/1)
    {:ok, seed_from_running_extensions([])}
  end

  @impl true
  def handle_call({:register_many, source, commands}, _from, state) do
    entries = normalize_commands(source, commands)
    {:reply, :ok, replace_source(state, source, entries)}
  end

  def handle_call({:unregister_source, source}, _from, state) do
    {:reply, :ok, Enum.reject(state, &(&1.source == source))}
  end

  def handle_call(:commands, _from, state) do
    {:reply, Enum.map(state, & &1.command), state}
  end

  def handle_call(:entries, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(
        {:minga_event, :extension_agent_contributions_started,
         %{source: source, manifest: %Manifest{} = manifest}},
        state
      ) do
    entries = normalize_commands(source, manifest.slash_commands)
    {:noreply, replace_source(state, source, entries)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec seed_from_running_extensions(state()) :: state()
  defp seed_from_running_extensions(state) do
    if Process.whereis(Minga.Extension.Registry) do
      Minga.Extension.Registry.all()
      |> Enum.filter(fn {_name, entry} -> entry.status == :running and entry.manifest != nil end)
      |> Enum.reduce(state, fn {name, entry}, acc ->
        replace_source(
          acc,
          {:extension, name},
          normalize_commands({:extension, name}, entry.manifest.slash_commands)
        )
      end)
    else
      state
    end
  rescue
    _ -> state
  catch
    :exit, _ -> state
  end

  @spec normalize_commands(source(), [{atom() | String.t(), String.t(), keyword()}]) :: [entry()]
  defp normalize_commands(source, commands) do
    commands
    |> Enum.with_index()
    |> Enum.flat_map(fn {command, index} -> normalize_command(source, command, index) end)
  end

  @spec normalize_command(source(), term(), non_neg_integer()) :: [entry()]
  defp normalize_command(source, {name, description, opts}, index)
       when (is_atom(name) or is_binary(name)) and is_binary(description) and is_list(opts) do
    [
      %{
        source: source,
        id: Integer.to_string(index),
        command: %Command{
          name: command_name(name),
          description: description,
          execute: Keyword.get(opts, :command)
        }
      }
    ]
  end

  defp normalize_command(_source, _command, _index), do: []

  @spec command_name(atom() | String.t()) :: String.t()
  defp command_name(name) when is_atom(name), do: Atom.to_string(name)
  defp command_name(name) when is_binary(name), do: name

  @spec replace_source(state(), source(), [entry()]) :: state()
  defp replace_source(state, source, entries) do
    state
    |> Enum.reject(&(&1.source == source))
    |> Kernel.++(entries)
  end
end
