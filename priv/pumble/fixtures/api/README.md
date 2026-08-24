# API request fixtures

These files record the **request contract** this adapter sends: method, path,
required headers, and body. Field **names** are `SUPPORTED` in
`docs/evidence/pumble_source_matrix.md`. Concrete identifier **values** are
`INFERRED` (`C_FAKE001`, `U_FAKE001`).

Success **response bodies** are not live recordings. Writes that the client
already treats as empty `2xx` use an empty raw body. JSON success bodies, when
present, are tagged `INFERRED` and must not be promoted to protocol fact.

No fixture covers `A-3`, `A-8`–`A-12`, `A-19`, or `A-20`: those operations are
not retained by the product.
