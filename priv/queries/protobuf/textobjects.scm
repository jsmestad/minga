(message (message_body) @class.inside) @class.around
(enum (enum_body) @class.inside) @class.around
; This vendored grammar has no `service_body` node; `service` holds its members
; inline, so only the outer `service` node is available for the textobject.
(service) @class.around

(rpc (message_or_enum_type) @parameter.inside) @function.inside
(rpc (message_or_enum_type) @parameter.around) @function.around

(comment) @comment.inside
(comment)+ @comment.around
