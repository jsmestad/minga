# Board frontend source

Board-specific frontend code lives here because Board is an experiment owned by the `minga_board` extension. Do not move these types, decoders, renderers, or action helpers back into shared protocol, core semantic UI, or default frontend parity paths.

The shared frontends target generic semantic UI and extension primitives. Board runtime payloads now flow through the generic frontend-extension envelope; the Board decoders, renderers, and action helpers stay in this extension-owned tree instead of returning to core protocol or frontend parity paths.
