defmodule Minga.Test.EditingModelCase do
  @moduledoc """
  Case template that pins the editing model before each test.

  Use this in test modules that create editors directly via
  `MingaEditor.start_link` (without going through `EditorCase`) and need
  a specific editing model for key dispatch.

      use Minga.Test.EditingModelCase, async: true
      @moduletag editing_model: :vim

  The editing model defaults to `:vim` if no tag is set. CUA tests
  opt in with `@moduletag editing_model: :cua` or per-test with
  `@tag editing_model: :cua`.

  For tests that use `EditorCase`, the editing model is passed to
  `MingaEditor.start_link` via the `editing_model:` option and doesn't
  need this case template.
  """

  use ExUnit.CaseTemplate

  setup context do
    model = Map.get(context, :editing_model, :vim)
    Minga.Config.Options.set(:editing_model, model)
    :ok
  end
end
