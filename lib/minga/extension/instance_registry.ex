defmodule Minga.Extension.InstanceRegistry do
  @moduledoc """
  Unique process names for per-extension roots, runtime supervisors, and instances.

  The extension name identifies one stable lifecycle mailbox. Runtime process PIDs
  are deliberately not registered here because they are implementation details
  owned by that instance.
  """

  @type role :: :root | :runtime | :instance
  @type registry :: atom()

  @default_await_timeout_ms 5_000

  @doc "Builds the unique registry child specification."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.child_spec({Registry, keys: :unique, name: name}, id: name)
  end

  @doc "Starts a unique Registry used by the extension process trees."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Registry.start_link(keys: :unique, name: name)
  end

  @doc "Returns a via tuple for the production instance authority."
  @spec via(atom()) :: {:via, Registry, {registry(), {role(), atom()}}}
  def via(name) when is_atom(name), do: via(__MODULE__, :instance, name)

  @doc "Returns a via tuple for a role in an explicit registry."
  @spec via(registry(), role(), atom()) :: {:via, Registry, {registry(), {role(), atom()}}}
  def via(registry, role, name)
      when is_atom(registry) and role in [:root, :runtime, :instance] and is_atom(name) do
    {:via, Registry, {registry, {role, name}}}
  end

  @doc "Looks up one registered per-extension process."
  @spec whereis(registry(), role(), atom()) :: pid() | nil
  def whereis(registry, role, name) do
    case Process.whereis(registry) do
      nil ->
        nil

      _pid ->
        case Registry.lookup(registry, {role, name}) do
          [{pid, _value}] -> pid
          [] -> nil
        end
    end
  end

  @doc "Waits event-first for a process registration, closing the lookup/register race."
  @spec await(registry(), role(), atom(), timeout()) :: {:ok, pid()} | {:error, term()}
  def await(registry, role, name, timeout \\ @default_await_timeout_ms)
      when is_atom(registry) and role in [:root, :runtime, :instance] and is_atom(name) do
    ref = make_ref()
    key = {:registration_waiter, role, name, ref}
    {:ok, _owner} = Registry.register(registry, key, nil)

    result =
      case whereis(registry, role, name) do
        pid when is_pid(pid) ->
          {:ok, pid}

        nil ->
          receive do
            {__MODULE__, :registered, ^role, ^name, pid} when is_pid(pid) -> {:ok, pid}
          after
            timeout -> {:error, {:authority_unavailable, name, :registration_timeout}}
          end
      end

    Registry.unregister(registry, key)
    result
  end

  @doc "Notifies processes waiting for a newly registered lifecycle authority."
  @spec notify_waiters(registry(), role(), atom(), pid()) :: :ok
  def notify_waiters(registry, role, name, pid) do
    registry
    |> Registry.select([
      {{{:registration_waiter, role, name, :_}, :"$1", :_}, [], [:"$1"]}
    ])
    |> Enum.each(&send(&1, {__MODULE__, :registered, role, name, pid}))

    :ok
  end

  @doc "Lists extension names which currently have a root."
  @spec root_names(registry()) :: [atom()]
  def root_names(registry \\ __MODULE__) do
    registry
    |> Registry.select([{{{:root, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  @doc "Returns the instance registry associated with an extension root supervisor."
  @spec registry_for_root(GenServer.server()) :: registry()
  def registry_for_root(Minga.Extension.RootSupervisor), do: __MODULE__
  def registry_for_root(Minga.Extension.Supervisor), do: __MODULE__

  def registry_for_root(root) when is_atom(root) do
    String.to_atom("#{root}.InstanceRegistry")
  end

  def registry_for_root(root) when is_pid(root) do
    case Process.info(root, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] -> registry_for_root(name)
      _other -> __MODULE__
    end
  end
end
