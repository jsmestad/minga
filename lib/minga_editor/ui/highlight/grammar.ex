defmodule MingaEditor.UI.Highlight.Grammar do
  @moduledoc """
  Delegate to `Minga.Language.Grammar`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  All functionality is delegated to the canonical location.
  """

  @spec init_registry() :: term()
  def init_registry, do: Minga.Language.Grammar.init_registry()

  @spec register_language(term(), term()) :: term()
  def register_language(filetype, language),
    do: Minga.Language.Grammar.register_language(filetype, language)

  @spec unregister_language(term()) :: term()
  def unregister_language(filetype), do: Minga.Language.Grammar.unregister_language(filetype)
  @spec language_for_filetype(term()) :: term()
  def language_for_filetype(filetype), do: Minga.Language.Grammar.language_for_filetype(filetype)
  @spec query_path(term()) :: term()
  def query_path(language), do: Minga.Language.Grammar.query_path(language)

  @doc "Alias for `query_path/1` (backward compat)."
  @spec highlight_query_path(term()) :: term()
  def highlight_query_path(language), do: Minga.Language.Grammar.query_path(language)

  @spec injection_query_path(term()) :: term()
  def injection_query_path(language), do: Minga.Language.Grammar.injection_query_path(language)
  @spec read_query(term()) :: term()
  def read_query(language), do: Minga.Language.Grammar.read_query(language)
  @spec read_injection_query(term()) :: term()
  def read_injection_query(language), do: Minga.Language.Grammar.read_injection_query(language)
  @spec supported_languages() :: term()
  def supported_languages, do: Minga.Language.Grammar.supported_languages()
  @spec dynamic_grammar_path(term()) :: term()
  def dynamic_grammar_path(name), do: Minga.Language.Grammar.dynamic_grammar_path(name)
end
