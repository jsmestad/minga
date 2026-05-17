defmodule Minga.Config.ModelineSegment do
  @moduledoc """
  A custom modeline segment registered by user config or an extension.

  The renderer decides where the segment appears from the configured segment lists. The segment's own `side` is the default placement when the user has not explicitly listed the segment on either side.
  """

  @enforce_keys [:name, :side, :priority, :render, :source]
  defstruct [:name, :side, :priority, :render, :source]

  @typedoc "Modeline side used for default placement."
  @type side :: :left | :right

  @typedoc "A normalized modeline draw segment."
  @type render_segment ::
          {String.t(), non_neg_integer(), non_neg_integer(), keyword(), atom() | nil}

  @typedoc "Context passed to modeline segment render functions."
  @type context :: map()

  @typedoc "Custom segment render function."
  @type render_fun :: (context() -> [render_segment()] | render_segment() | nil)

  @type t :: %__MODULE__{
          name: atom(),
          side: side(),
          priority: integer(),
          render: render_fun(),
          source: atom() | {:extension, atom()}
        }

  @type validation_error :: {:invalid_side, term()} | {:invalid_priority, term()}

  @doc "Builds a custom modeline segment descriptor."
  @spec new(atom(), keyword(), render_fun(), atom() | {:extension, atom()}) ::
          {:ok, t()} | {:error, validation_error()}
  def new(name, opts, render, source)
      when is_atom(name) and is_list(opts) and is_function(render, 1) do
    with {:ok, side} <- side_from_opts(opts),
         {:ok, priority} <- priority_from_opts(opts) do
      {:ok,
       %__MODULE__{
         name: name,
         side: side,
         priority: priority,
         render: render,
         source: source
       }}
    end
  end

  @spec side_from_opts(keyword()) :: {:ok, side()} | {:error, {:invalid_side, term()}}
  defp side_from_opts(opts) do
    case Keyword.get(opts, :side, :right) do
      :left -> {:ok, :left}
      :right -> {:ok, :right}
      other -> {:error, {:invalid_side, other}}
    end
  end

  @spec priority_from_opts(keyword()) :: {:ok, integer()} | {:error, {:invalid_priority, term()}}
  defp priority_from_opts(opts) do
    case Keyword.get(opts, :priority, 50) do
      priority when is_integer(priority) -> {:ok, priority}
      other -> {:error, {:invalid_priority, other}}
    end
  end
end
