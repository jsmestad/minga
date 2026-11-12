defmodule R0Definition.Helper do
  def revision, do: :v3
  def valid?, do: true
  def compute(n, x), do: 30 + n + x
end

defmodule R0Definition.Left do
  def upgrade(model), do: {:ok, %{model | schema: 3}}
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v3, R0Definition.Helper.revision(), 300 + R0Definition.Helper.compute(model.n, input)}
  end
end

defmodule R0Definition.Right do
  def run(model, input, context) do
    R0.Gate.before_helper(context)
    {:v3, R0Definition.Helper.revision(), 3000 + R0Definition.Helper.compute(model.n, input)}
  end
end
