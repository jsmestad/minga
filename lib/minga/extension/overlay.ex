defmodule Minga.Extension.Overlay do
  @moduledoc """
  Registry for extension-owned overlays on the editor surface.

  Extensions register overlays anchored to buffer positions. The Layer 2
  emit pipeline reads this registry during chrome sync and converts
  buffer positions to screen coordinates for the frontend.

  Overlays are source-tagged for `ContributionCleanup` integration:
  when an extension crashes or reloads, all its overlays are removed
  automatically.

  ## Usage from an extension

      Minga.Extension.Overlay.set(:ghost_cursors, "cursor_1", buffer_pid,
        position: {42, 10},
        content: "Claude",
        style: %{fg: 0x7C3AED, opacity: 102},
        shape: :cursor_with_label
      )

      Minga.Extension.Overlay.remove(:ghost_cursors, "cursor_1")
  """

  alias Minga.Extension.ContributionCleanup

  @table __MODULE__

  @typedoc "Overlay shape hint for the frontend renderer."
  @type shape :: :cursor | :cursor_with_label | :label | :indicator

  @typedoc "Overlay style options."
  @type style :: %{
          optional(:fg) => non_neg_integer(),
          optional(:opacity) => 0..255
        }

  @typedoc "A registered overlay entry."
  @type entry :: %{
          extension: atom(),
          overlay_id: term(),
          buffer: pid(),
          position: {non_neg_integer(), non_neg_integer()},
          content: String.t(),
          style: style(),
          shape: shape()
        }

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts \\ []) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    ContributionCleanup.register(:extension_overlays, fn source ->
      unregister_source(source)
    end)

    {:ok, self()}
  end

  @doc "Initializes the overlay registry. Called during application startup."
  @spec init() :: :ok
  def init do
    unless :ets.whereis(@table) != :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      ContributionCleanup.register(:extension_overlays, fn source ->
        unregister_source(source)
      end)
    end

    :ok
  end

  @doc """
  Registers or updates an overlay.

  The overlay is keyed by `{extension_name, overlay_id}`. Calling
  `set/4` with the same key replaces the previous overlay.
  """
  @spec set(atom(), term(), pid(), keyword()) :: :ok
  def set(extension_name, overlay_id, buffer_pid, opts)
      when is_atom(extension_name) and is_pid(buffer_pid) do
    entry = %{
      extension: extension_name,
      overlay_id: overlay_id,
      buffer: buffer_pid,
      position: Keyword.fetch!(opts, :position),
      content: Keyword.get(opts, :content, ""),
      style: Keyword.get(opts, :style, %{}),
      shape: Keyword.get(opts, :shape, :indicator)
    }

    :ets.insert(@table, {{extension_name, overlay_id}, entry})
    :ok
  end

  @doc "Removes a specific overlay."
  @spec remove(atom(), term()) :: :ok
  def remove(extension_name, overlay_id) when is_atom(extension_name) do
    :ets.delete(@table, {extension_name, overlay_id})
    :ok
  end

  @doc "Removes all overlays for an extension."
  @spec remove_all(atom()) :: :ok
  def remove_all(extension_name) when is_atom(extension_name) do
    :ets.match_delete(@table, {{extension_name, :_}, :_})
    :ok
  end

  @doc "Returns all overlays for a specific buffer."
  @spec for_buffer(pid()) :: [entry()]
  def for_buffer(buffer_pid) when is_pid(buffer_pid) do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, entry} -> entry.buffer == buffer_pid end)
      |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @doc "Returns all registered overlays."
  @spec all() :: [entry()]
  def all do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table) |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @doc "Returns true if no overlays are registered."
  @spec empty?() :: boolean()
  def empty? do
    :ets.whereis(@table) == :undefined or :ets.info(@table, :size) == 0
  end

  @doc "Removes all overlays owned by a contribution source."
  @spec unregister_source(ContributionCleanup.contribution_source()) :: :ok
  def unregister_source({:extension, name}) when is_atom(name) do
    remove_all(name)
  end

  def unregister_source(_source), do: :ok
end
