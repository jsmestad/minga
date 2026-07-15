defmodule Minga.Credo.EditorStateOwnership.DirectWriteRule do
  @moduledoc """
  Direct foreign-write classification for EX9012.

  This rule owns struct/map update, Map mutation, and Access-path attribution.
  Traversal and local type propagation remain in their focused modules.
  """

  alias Minga.Credo.EditorStateOwnership.Ownership
  alias Minga.Credo.EditorStateOwnership.Policy
  alias Minga.Credo.EditorStateOwnership.SourceEnvironment
  alias Minga.Credo.EditorStateOwnership.TypeFlow

  @typedoc "A direct-write finding emitted to the EX9012 reporter."
  @type finding :: %{
          violation: String.t(),
          target: String.t(),
          receiver: String.t(),
          ownership: Ownership.t(),
          module: String.t() | nil,
          function: String.t() | nil,
          line: pos_integer()
        }

  @doc "Checks a known receiver ownership against the current lexical owner."
  @spec check(Ownership.t() | nil, Macro.t(), keyword(), SourceEnvironment.t()) :: [finding()]
  def check(nil, _receiver, _meta, %SourceEnvironment{}), do: []

  def check(%Ownership{} = ownership, receiver, meta, %SourceEnvironment{} = env) do
    if env.module in ownership.owners do
      []
    else
      [
        %{
          violation: "direct_write",
          target: ownership.struct,
          receiver: Macro.to_string(receiver),
          ownership: ownership,
          module: env.module,
          function: env.function,
          line: meta[:line] || 1
        }
      ]
    end
  end

  @doc "Checks an explicit struct or map update."
  @spec check_update(
          Ownership.t() | nil,
          Macro.t(),
          Macro.t(),
          keyword(),
          TypeFlow.t(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: [finding()]
  def check_update(ownership, receiver, updates, meta, flow, env, policy) do
    if owner_produced_root_installation?(ownership, updates, flow, env, policy) do
      []
    else
      check(ownership, receiver, meta, env)
    end
  end

  @doc "Checks put_in/update_in using the complete non-pipelined receiver path."
  @spec check_access(
          atom(),
          [Macro.t()],
          keyword(),
          TypeFlow.t(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: [finding()]
  def check_access(kind, args, meta, flow, env, policy) when kind in [:put_in, :update_in] do
    receiver = List.first(args)
    path = TypeFlow.field_path(receiver)

    ownership =
      case kind do
        :put_in -> Policy.ownership_for_path(policy, TypeFlow.drop_updated_field(path))
        :update_in -> Policy.ownership_for_nested_path(policy, path)
      end

    check(
      ownership || TypeFlow.receiver_ownership(receiver, flow, env, policy),
      receiver,
      meta,
      env
    )
  end

  @doc "Checks put_in/update_in after normalizing a pipeline receiver."
  @spec check_piped_access(
          atom(),
          Macro.t(),
          [Macro.t()],
          keyword(),
          TypeFlow.t(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: [finding()]
  def check_piped_access(kind, receiver, args, meta, flow, env, policy)
      when kind in [:put_in, :update_in] do
    receiver_ownership = TypeFlow.receiver_ownership(receiver, flow, env, policy)
    receiver_path = TypeFlow.field_path(receiver) || TypeFlow.canonical_path(receiver_ownership)
    combined_path = TypeFlow.combine_paths(receiver_path, TypeFlow.access_path(List.first(args)))

    ownership =
      case kind do
        :put_in -> Policy.ownership_for_path(policy, TypeFlow.drop_updated_field(combined_path))
        :update_in -> Policy.ownership_for_nested_path(policy, combined_path)
      end

    check(ownership || receiver_ownership, receiver, meta, env)
  end

  @spec owner_produced_root_installation?(
          Ownership.t() | nil,
          Macro.t(),
          TypeFlow.t(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: boolean()
  defp owner_produced_root_installation?(
         %Ownership{struct: "MingaEditor.State"},
         updates,
         flow,
         env,
         policy
       )
       when is_list(updates) and updates != [] do
    Enum.all?(updates, &owner_produced_root_field?(&1, flow, env, policy))
  end

  defp owner_produced_root_installation?(_ownership, _updates, _flow, _env, _policy), do: false

  @spec owner_produced_root_field?(
          Macro.t(),
          TypeFlow.t(),
          SourceEnvironment.t(),
          Policy.t()
        ) :: boolean()
  defp owner_produced_root_field?({field, value}, flow, env, policy) when is_atom(field) do
    case Policy.ownership_for_path(policy, [field]) do
      nil -> false
      ownership -> owner_call?(value, ownership.owners, flow, env)
    end
  end

  defp owner_produced_root_field?(_update, _flow, _env, _policy), do: false

  @spec owner_call?(Macro.t(), [String.t()], TypeFlow.t(), SourceEnvironment.t()) :: boolean()
  defp owner_call?({{:., _, [module_ast, function]}, _, args}, owners, _flow, env)
       when is_atom(function) and is_list(args) do
    SourceEnvironment.module_name(module_ast, env) in owners
  end

  defp owner_call?(_value, _owners, _flow, _env), do: false
end
