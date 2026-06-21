[
  (message_body)
  (enum_body)
  ; This vendored grammar has no `oneof_body`/`service_body`/`rpc_body` wrapper
  ; nodes; `service`, `oneof`, and `rpc` inline their `{ ... }` block directly,
  ; so capture those parent nodes to indent their contents.
  (service)
  (oneof)
  (rpc)
  (block_lit)
] @indent

"}" @outdent
