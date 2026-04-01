defmodule MingaEditor.UI.Highlight.Grammar do
  @moduledoc """
  Delegate to `Minga.Language.Grammar`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  All functionality is delegated to the canonical location.
  """

  defdelegate init_registry(), to: Minga.Language.Grammar
  defdelegate register_language(filetype, language), to: Minga.Language.Grammar
  defdelegate language_for_filetype(filetype), to: Minga.Language.Grammar
  defdelegate query_path(language), to: Minga.Language.Grammar

  @doc "Alias for `query_path/1` (backward compat)."
  defdelegate highlight_query_path(language), to: Minga.Language.Grammar, as: :query_path

  defdelegate injection_query_path(language), to: Minga.Language.Grammar
  defdelegate read_query(language), to: Minga.Language.Grammar
  defdelegate read_injection_query(language), to: Minga.Language.Grammar
  defdelegate supported_languages(), to: Minga.Language.Grammar
  defdelegate dynamic_grammar_path(name), to: Minga.Language.Grammar
end
