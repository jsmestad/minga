# Minga is a large brownfield project. Report substantial duplicate behavior, not repeated module wiring.
%{
  min_mass: 50,
  excluded_macros: [:alias, :import, :require, :use],
  ignored_attributes: [:default_notify]
}
