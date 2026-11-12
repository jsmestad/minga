defmodule R0Definition.Helper do
  @moduledoc "Owned arithmetic helper for the stable-name recovery definition."
  @type revision :: :v3
  @spec revision() :: revision()
  def revision, do: :v3
  @spec valid?() :: boolean()
  def valid?, do: true
  @spec compute(integer(), integer()) :: integer()
  def compute(n, x), do: 30 + n + x
end

defmodule R0Definition.Left do
  @moduledoc "First v3 entry point, recovering retained legacy-instance data."
  @type model :: %{schema: pos_integer(), n: integer(), kind: :modern | :legacy}
  @type result :: {R0Definition.Helper.revision(), R0Definition.Helper.revision(), integer()}
  @spec upgrade(model()) :: {:ok, model()}
  def upgrade(model), do: {:ok, %{model | schema: 3}}
  @spec run(model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v3, R0Definition.Helper.revision(), 300 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  @moduledoc "Second v3 entry point sharing the same recovery helper."
  @type result :: R0Definition.Left.result()
  @spec run(R0Definition.Left.model(), integer(), map()) :: result()
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v3, R0Definition.Helper.revision(), 3000 + R0Definition.Helper.compute(model.n, input)}
  end
end
