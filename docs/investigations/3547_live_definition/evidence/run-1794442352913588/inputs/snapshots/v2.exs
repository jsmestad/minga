defmodule R0Definition.Helper do
  def revision, do: :v2
  def valid?, do: true
  def compute(n, x), do: 20 + n + x
end

defmodule R0Definition.Left do
  def upgrade(%{kind: :legacy}), do: {:error, :legacy_schema}
  def upgrade(model), do: {:ok, %{model | schema: 2}}
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v2, R0Definition.Helper.revision(), 200 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v2, R0Definition.Helper.revision(), 2000 + R0Definition.Helper.compute(model.n, input)}
  end
end
