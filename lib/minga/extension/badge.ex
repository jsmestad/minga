defmodule Minga.Extension.Badge do
  @moduledoc """
  ETS-backed registry for extension-owned badges on file tree entries and tabs.

  Extensions register small visual indicators (colored dots, short text)
  on file tree entries by path and on tabs by buffer PID. The emit
  pipeline reads this registry when building file tree and tab bar
  protocol data.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup

  @file_table __MODULE__
  @tab_table Module.concat(__MODULE__, Tabs)

  @typedoc "Animation hint for badges."
  @type animation :: :static | :pulse

  @typedoc "A file tree badge entry."
  @type file_badge :: %{
          extension: atom(),
          path: String.t(),
          color: non_neg_integer(),
          text: String.t(),
          animation: animation()
        }

  @typedoc "A tab badge entry."
  @type tab_badge :: %{
          extension: atom(),
          buffer: pid(),
          color: non_neg_integer()
        }

  @type table :: atom()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @spec set_file(atom(), String.t(), keyword()) :: :ok
  @spec set_file(table(), atom(), String.t(), keyword()) :: :ok
  def set_file(extension_name, path, opts \\ []),
    do: set_file(@file_table, extension_name, path, opts)

  def set_file(file_table, extension_name, path, opts)
      when is_atom(extension_name) and is_binary(path) do
    abs_path = Path.expand(path)

    entry = %{
      extension: extension_name,
      path: abs_path,
      color: Keyword.get(opts, :color, 0x51AFEF),
      text: Keyword.get(opts, :text, ""),
      animation: Keyword.get(opts, :animation, :static)
    }

    :ets.insert(file_table, {{extension_name, abs_path}, entry})
    :ok
  end

  @spec set_tab(atom(), pid(), keyword()) :: :ok
  @spec set_tab(table(), atom(), pid(), keyword()) :: :ok
  def set_tab(extension_name, buffer_pid, opts \\ []),
    do: set_tab(@tab_table, extension_name, buffer_pid, opts)

  def set_tab(tab_table, extension_name, buffer_pid, opts)
      when is_atom(extension_name) and is_pid(buffer_pid) do
    entry = %{
      extension: extension_name,
      buffer: buffer_pid,
      color: Keyword.get(opts, :color, 0x51AFEF)
    }

    :ets.insert(tab_table, {{extension_name, buffer_pid}, entry})
    :ok
  end

  @spec remove_file(atom(), String.t()) :: :ok
  @spec remove_file(table(), atom(), String.t()) :: :ok
  def remove_file(extension_name, path), do: remove_file(@file_table, extension_name, path)

  def remove_file(file_table, extension_name, path) when is_atom(extension_name) do
    :ets.delete(file_table, {extension_name, Path.expand(path)})
    :ok
  end

  @spec remove_tab(atom(), pid()) :: :ok
  @spec remove_tab(table(), atom(), pid()) :: :ok
  def remove_tab(extension_name, buffer_pid),
    do: remove_tab(@tab_table, extension_name, buffer_pid)

  def remove_tab(tab_table, extension_name, buffer_pid) when is_atom(extension_name) do
    :ets.delete(tab_table, {extension_name, buffer_pid})
    :ok
  end

  @spec badges_for_path(String.t()) :: [file_badge()]
  @spec badges_for_path(table(), String.t()) :: [file_badge()]
  def badges_for_path(path), do: badges_for_path(@file_table, path)

  def badges_for_path(file_table, path) when is_binary(path) do
    if table_ready?(file_table) do
      abs_path = Path.expand(path)

      :ets.tab2list(file_table)
      |> Enum.filter(fn {_key, entry} -> entry.path == abs_path end)
      |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @spec badges_for_buffer(pid()) :: [tab_badge()]
  @spec badges_for_buffer(table(), pid()) :: [tab_badge()]
  def badges_for_buffer(buffer_pid), do: badges_for_buffer(@tab_table, buffer_pid)

  def badges_for_buffer(tab_table, buffer_pid) when is_pid(buffer_pid) do
    if table_ready?(tab_table) do
      :ets.tab2list(tab_table)
      |> Enum.filter(fn {_key, entry} -> entry.buffer == buffer_pid end)
      |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @spec all_file_badges() :: [file_badge()]
  @spec all_file_badges(table()) :: [file_badge()]
  def all_file_badges, do: all_file_badges(@file_table)

  def all_file_badges(file_table) do
    if table_ready?(file_table) do
      :ets.tab2list(file_table) |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @spec all_tab_badges() :: [tab_badge()]
  @spec all_tab_badges(table()) :: [tab_badge()]
  def all_tab_badges, do: all_tab_badges(@tab_table)

  def all_tab_badges(tab_table) do
    if table_ready?(tab_table) do
      :ets.tab2list(tab_table) |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @spec remove_all(atom()) :: :ok
  @spec remove_all(table(), table(), atom()) :: :ok
  def remove_all(extension_name), do: remove_all(@file_table, @tab_table, extension_name)

  def remove_all(file_table, tab_table, extension_name) when is_atom(extension_name) do
    if table_ready?(file_table),
      do: :ets.match_delete(file_table, {{extension_name, :_}, :_})

    if table_ready?(tab_table),
      do: :ets.match_delete(tab_table, {{extension_name, :_}, :_})

    :ok
  end

  @spec unregister_source(ContributionCleanup.contribution_source()) :: :ok
  def unregister_source({:extension, name}) when is_atom(name), do: remove_all(name)
  def unregister_source(_source), do: :ok

  @impl true
  @spec init(keyword()) :: {:ok, table()}
  def init(opts) do
    table = Keyword.get(opts, :name, @file_table)
    create_owned_table(table)
    create_owned_table(tabs_table(table))

    ContributionCleanup.register(:extension_badges, fn source ->
      unregister_source(source)
    end)

    {:ok, table}
  end

  @spec tabs_table(table()) :: table()
  defp tabs_table(@file_table), do: @tab_table
  defp tabs_table(table), do: Module.concat(table, Tabs)

  @spec table_ready?(table()) :: boolean()
  defp table_ready?(table), do: :ets.whereis(table) != :undefined

  @spec create_owned_table(table()) :: :ok
  defp create_owned_table(table) do
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end
end
