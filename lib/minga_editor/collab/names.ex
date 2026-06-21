defmodule MingaEditor.Collab.Names do
  @moduledoc """
  Per-session naming for the collab editor triad.

  Each attached client drives an independent editor session on the headless
  daemon. A session owns three processes: a `MingaEditor.Frontend.Manager`, a
  `MingaEditor.Renderer.Server`, and a `MingaEditor` GenServer. To let these
  resolve by session id instead of a single global module name, each is
  registered in `MingaEditor.Collab.Registry` under a `{session_id, role}` key
  and addressed with a via-tuple.

  ## The default session

  Single-session behaviour (one local editor, one renderer, one frontend) is
  preserved by `default_session_id/0`. The default session's triad is registered
  under both its via-tuples *and* the historical bare module names
  (`MingaEditor`, `MingaEditor.Frontend.Manager`,
  `MingaEditor.Renderer.Server`), so existing call sites that look up the global
  module name keep working unchanged.
  """

  @typedoc "Collab session identifier."
  @type session_id :: String.t()

  @typedoc "A process role within a session triad."
  @type role :: :editor | :frontend | :renderer

  @registry MingaEditor.Collab.Registry

  @default_session_id "default"

  @doc "The reserved session id used for the singleton/default editor."
  @spec default_session_id() :: session_id()
  def default_session_id, do: @default_session_id

  @doc "Returns true when `session_id` is the default/singleton session."
  @spec default_session?(session_id()) :: boolean()
  def default_session?(@default_session_id), do: true
  def default_session?(_session_id), do: false

  @doc "The registry module backing per-session via-tuples."
  @spec registry() :: module()
  def registry, do: @registry

  @doc """
  The GenServer name to register a session's process under for `role`.

  For the default session this is the historical bare module name so existing
  global lookups keep resolving. For any other session it is a via-tuple keyed
  by `{session_id, role}` in `MingaEditor.Collab.Registry`.
  """
  @spec name(session_id(), role()) :: GenServer.name()
  def name(@default_session_id, role), do: module_for_role(role)
  def name(session_id, role) when is_binary(session_id), do: via(session_id, role)

  @doc """
  Returns the via-tuple for `{session_id, role}` regardless of whether the
  session is the default. Useful when a non-default lookup is always wanted.
  """
  @spec via(session_id(), role()) :: {:via, Registry, {module(), {session_id(), role()}}}
  def via(session_id, role) when is_binary(session_id) do
    {:via, Registry, {@registry, {session_id, role}}}
  end

  @doc "Resolves the live pid for `{session_id, role}`, or nil if not running."
  @spec whereis(session_id(), role()) :: pid() | nil
  def whereis(@default_session_id, role), do: GenServer.whereis(module_for_role(role))

  def whereis(session_id, role) when is_binary(session_id) do
    case Registry.lookup(@registry, {session_id, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The historical bare module name for `role`."
  @spec module_for_role(role()) :: module()
  def module_for_role(:editor), do: MingaEditor
  def module_for_role(:frontend), do: MingaEditor.Frontend.Manager
  def module_for_role(:renderer), do: MingaEditor.Renderer.Server

  @doc """
  Lists the session ids that currently have a live editor registered.

  The default session is included when its bare-named editor is alive.
  """
  @spec list_session_ids() :: [session_id()]
  def list_session_ids do
    registered =
      Registry.select(@registry, [
        {{{:"$1", :editor}, :_, :_}, [], [:"$1"]}
      ])

    default = if GenServer.whereis(MingaEditor), do: [@default_session_id], else: []

    Enum.uniq(default ++ registered)
  end
end
