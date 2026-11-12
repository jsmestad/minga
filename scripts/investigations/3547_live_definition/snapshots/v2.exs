defmodule R0Definition.Helper do
  @moduledoc "Owned arithmetic helper for the stable-name v2 definition."
  @type revision :: :v2
  @spec revision() :: revision()
  def revision, do: :v2
  @spec valid?() :: boolean()
  def valid?, do: true
  @spec compute(integer(), integer()) :: integer()
  def compute(n, x), do: 20 + n + x
end

defmodule R0Definition.Left do
  @moduledoc "First v2 entry point, deliberately incompatible with legacy instances."
  @type model :: %{schema: pos_integer(), n: integer(), kind: :modern | :legacy}
  @type result :: {R0Definition.Helper.revision(), R0Definition.Helper.revision(), integer()}
  @spec upgrade(model()) :: {:ok, model()} | {:error, :legacy_schema}
  def upgrade(%{kind: :legacy}), do: {:error, :legacy_schema}
  def upgrade(model), do: {:ok, %{model | schema: 2}}
  @spec run(model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v2, R0Definition.Helper.revision(), 200 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  @moduledoc "Second v2 entry point sharing the same owned helper."
  @type result :: R0Definition.Left.result()
  @spec run(R0Definition.Left.model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v2, R0Definition.Helper.revision(), 2000 + R0Definition.Helper.compute(model.n, input)}
  end
end
