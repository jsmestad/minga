defmodule Minga.SystemObserver.TreeNode do
  @moduledoc """
  Render-oriented tree node derived from flat SystemObserver snapshots.

  SystemObserver keeps snapshots in a flat map keyed by PID because that is cheap to collect and easy to sample over time. The Observatory derives this tree when it needs hierarchy for rendering.
  """

  alias Minga.SystemObserver.ProcessSnapshot

  @enforce_keys [:pid, :snapshot, :children, :depth]
  defstruct [:pid, :snapshot, :children, :depth]

  @type t :: %__MODULE__{
          pid: pid(),
          snapshot: ProcessSnapshot.t(),
          children: [t()],
          depth: non_neg_integer()
        }

  @doc """
  Builds a supervision tree from a flat `%{pid => ProcessSnapshot.t()}` map.

  Returns `nil` when the snapshot has no root process. Children whose parent is missing from the map are ignored because they cannot be placed in the rendered tree safely.
  """
  @spec build_tree(%{pid() => ProcessSnapshot.t()}) :: t() | nil
  def build_tree(snapshots) when map_size(snapshots) == 0, do: nil

  def build_tree(snapshots) when is_map(snapshots) do
    with {root_pid, root_snapshot} <- find_root(snapshots) do
      children_by_parent = group_children_by_parent(snapshots)
      build_node(root_pid, root_snapshot, children_by_parent, 0)
    end
  end

  @doc "Returns the tree as a pre-order list of nodes."
  @spec flatten(t() | nil) :: [t()]
  def flatten(nil), do: []

  def flatten(%__MODULE__{children: children} = node) do
    [node | Enum.flat_map(children, &flatten/1)]
  end

  @spec find_root(%{pid() => ProcessSnapshot.t()}) :: {pid(), ProcessSnapshot.t()} | nil
  defp find_root(snapshots) do
    Enum.find(snapshots, fn {_pid, snapshot} -> snapshot.parent_pid == nil end)
  end

  @spec group_children_by_parent(%{pid() => ProcessSnapshot.t()}) :: %{
          pid() => [{pid(), ProcessSnapshot.t()}]
        }
  defp group_children_by_parent(snapshots) do
    snapshots
    |> Enum.reject(fn {_pid, snapshot} -> snapshot.parent_pid == nil end)
    |> Enum.group_by(fn {_pid, snapshot} -> snapshot.parent_pid end)
  end

  @spec build_node(
          pid(),
          ProcessSnapshot.t(),
          %{pid() => [{pid(), ProcessSnapshot.t()}]},
          non_neg_integer()
        ) :: t()
  defp build_node(pid, snapshot, children_by_parent, depth) do
    children =
      children_by_parent
      |> Map.get(pid, [])
      |> sort_children()
      |> Enum.map(fn {child_pid, child_snapshot} ->
        build_node(child_pid, child_snapshot, children_by_parent, depth + 1)
      end)

    %__MODULE__{pid: pid, snapshot: snapshot, children: children, depth: depth}
  end

  @spec sort_children([{pid(), ProcessSnapshot.t()}]) :: [{pid(), ProcessSnapshot.t()}]
  defp sort_children(children) do
    Enum.sort_by(children, fn {pid, snapshot} ->
      {snapshot.process_class || :worker, snapshot.registered_name || :zzz_unnamed,
       :erlang.pid_to_list(pid)}
    end)
  end
end
