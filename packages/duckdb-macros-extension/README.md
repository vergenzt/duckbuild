# duckdb-macros-extension

A DuckDB extension that teaches the **PEG parser** to accept Rust-inspired **lexical
macros** — `name!(...)` calls with `$`-sigiled, fragment-typed, hygienic metavariables — so
they survive `json_serialize_sql` as AST nodes. The macros are **never executed by DuckDB**. `duckbuild-cli` reads the serialized
AST, resolves invocations, and inlines everything into plain DuckDB SQL before anything
runs.

That "never executed" property is important because it means macro nodes only need
to **parse → serialize → round-trip**. They never reach the binder, optimizer, or
execution engine, so we skip ~90% of what a first-class AST node normally requires.

---

## Status — working end-to-end (proof of concept)

The parse → serialize path is implemented and verified. The generic parser-extension seam
lives in the DuckDB fork (branch `peg-parser-extension-api`); this extension registers the
macro grammar + transforms against it in `Load()`. **Nothing macro-specific is in the fork.**

`json_serialize_sql('define macro incr!($x: expr) returning expr as $x + 1')` →

```json
{"statements":[{"type":"CUSTOM_STATEMENT","tag":"macro_def",
  "named_param_map":[{"key":"x","value":1}],
  "children":[{"class":"FUNCTION","function_name":"+","arguments":[
    {"expression":{"class":"PARAMETER","type":"VALUE_PARAMETER","identifier":"x"}},
    {"expression":{"class":"CONSTANT","value":1}}]}],
  "properties":"{\"name\":\"incr\",\"params\":[{\"name\":\"x\",\"type\":\"expr\"}],\"returning\":\"expr\"}"}]}
```

`json_serialize_sql('SELECT incr!(a, b) FROM t')` → a `macro_ref` node with the two args as
structured child expressions.

**Done:** `define macro name!(...)` (typed params + return kind), `name!(...)` invocations,
and `$x` metavariables inside bodies. Invocations and definitions parse to
`macro_ref` / `macro_def` escape nodes (`ExtensionExpression` / `CustomStatement`) that
round-trip through `json_serialize_sql`.

### Metavariables reuse named parameters (no new node, no shadowing)

A metavariable `$x` is **not** a distinct AST node. In expression positions it parses as
DuckDB's native **named parameter** (`ParameterExpression`) — so the parser never has to tell a
metavar from a prepared-statement parameter, and nothing is shadowed. See `SELECT $x` above: a
plain `PARAMETER`. Invocations avoid the `$` collision entirely by using Rust-style
`name!(...)`, which needs a real node since it isn't otherwise-valid SQL.

Disambiguation is deferred to **resolution** (`duckbuild-cli`): a `$x` inside a macro body must
resolve to exactly one of the macro's declared params (metavar namespace) or an enclosing
parameter — name shadowing across the two namespaces is disallowed.

**Not yet:** `$x` in *non-expression* positions (an `ident`/`type`/`table` metavar, e.g.
`from $tbl`) still needs small grammar additions (reusing the parameter node, no new node type).
Fragment kinds are currently accepted as any identifier at parse time (the fixed list below is
not enforced); recursive/nested expansion and hygiene checks are CLI-side and unimplemented.

---

## Surface syntax

Definition — a new top-level statement. The macro name carries a `!` suffix (Rust-style);
parameters are `$`-sigiled and typed by AST fragment kind:

```sql
define macro incr!($x: expr) returning expr as $x + 1;

define macro count_where!($tbl: ident, $pred: expr) returning expr
  as (select count(*) from $tbl where $pred);
```

Invocation — `name!(...)`, usable anywhere the declared return fragment is legal:

```sql
select incr!(a), count_where!(events, ts > now() - interval 1 day) from t;
```

Inside a body, `$x` is just DuckDB's named-parameter syntax (see below), so it needs no special
parsing — `$x + 1` parses natively.

### Fragment kinds (the metavariable "type" system)

The `: kind` on a parameter and the `returning <kind>` are **not** SQL data types
(`INTEGER`, `VARCHAR`). They are **AST fragment kinds** — the category of syntax the
metavariable stands in for, à la Rust's `macro_rules!` fragment specifiers
(`$x:expr`, `$t:ty`). Start with a lean, fixed list:

| Fragment | Stands for (DuckDB AST) | Where an invocation returning it may appear |
|---|---|---|
| `expr` | `ParsedExpression` | any expression position |
| `ident` | identifier (`ColumnReference` / name) | table/column/name positions |
| `type` | `LogicalType` name | type positions (casts, columns) |
| `literal` | constant `ParsedExpression` | literal positions |

Kept deliberately small; `query`/`table` (i.e. `QueryNode` / `TableRef`) are obvious later
additions. Fragment kinds drive both **typing** (return kind = where the invocation is
legal) and the basis for **hygiene** (a metavar reference in a body must resolve to a
declared parameter of a compatible kind — enforced by `duckbuild-cli` at resolution).

---

## Architecture: the four parser layers

DuckDB's PEG/matcher parser makes three of the four layers already data- or registry-driven.
Only serialization is hard-closed.

| Layer | Current state | Change needed |
|---|---|---|
| **Tokenizer** | `$` is already a single-byte operator token (`base_tokenizer.cpp`), so `$foo` → `OPERATOR($) + IDENTIFIER(foo)`. | **None** (confirm dollar-quote scanning ignores bare `$foo`). |
| **Grammar** | Built once/DB in `ParserCache::GetMatcher()` from `INLINED_PEG_GRAMMAR`; `MatcherFactory` already exposes `ParseRules()` + `AddRuleOverride`. Not extension-aware. | Small hook: consult a per-DB registry of grammar fragments. |
| **Transformer** | `PEGTransformerFactory` dispatches via a **name-keyed map** (`trampoline_transform_functions[rule]` / `GetTrampolineOps`); handlers are function pointers. | Small hook: `RegisterTrampoline(rule, ops)`, consulted from `GetTransformerFactory()`. |
| **Serialization** | `serialize_parsed_expression.cpp` is auto-generated (`generate_serialization.py`) — a closed `switch (ExpressionClass)`, no `EXTENSION` escape. | The one real closed door — needs a generic escape node. |

---

## The minimal fork change (patch plan)

Goal: the fork gains **generic, feature-agnostic plumbing** (plausibly upstreamable);
everything macro-specific lives in this extension. Four edits, none mentioning "macro":

### 1. A per-DB PEG-parser-extension registry (`DBConfig`)

A registry holding:
- grammar fragments (PEG text) to append,
- `(ruleName → TransformFrameOps)` trampoline handlers.

(No serialize callbacks needed — the escape node is self-describing; see step 4.)

Registering calls the existing `ParserCache::Invalidate()` so the per-DB matcher and
transformer factory rebuild. Extensions register during their `Load()`, before first parse.

### 2. Designated grammar extension points (one-time core edit)

Add empty, extension-fed alternatives at the two recursion points macros need, so
extensions never again touch a core rule:

```
# core grammar, added once:
TopLevelStatement <- ... / ExtensionStatementRule
BaseExpression    <- ... / ExtensionExprRule
# ExtensionStatementRule / ExtensionExprRule resolve to alternatives contributed by the registry
```

This is what lets a metavar `$x` appear inside an expression body, and a `define macro`
appear at statement level, purely additively.

### 3. Consult the registry in the cache builders

- `ParserCache::GetMatcher()` — after loading `INLINED_PEG_GRAMMAR`, `ParseRules()` each
  registered fragment and wire its alternatives into the extension-point rules.
- `ParserCache::GetTransformerFactory()` — insert each registered trampoline into the map.

### 4. One generic escape node (the closed-door fix) — DONE

Add a single `ExpressionClass::EXTENSION` value + a generic, **self-describing**
`ExtensionExpression`:

```cpp
// lives in the fork, generic — src/.../parser/expression/extension_expression.hpp
class ExtensionExpression : public ParsedExpression {
  string tag;                                   // e.g. "macro_ref", "metavar"
  vector<unique_ptr<ParsedExpression>> children;// structured sub-expressions
  string properties;                            // extension-defined metadata (JSON by convention)
  // only ToString / Copy / Equals / Hash / Serialize / Deserialize — never Bind/Execute
};
```

Because the node is self-describing, its Serialize/Deserialize/Copy/Equals/Hash are all
**generated** from one `parsed_expression.json` spec entry (`make generate-files`) — no
per-tag callback, no hand-written serializer case. And because it's a normal
`ParsedExpression` in the tree, the generated serializer recurses into it → it round-trips
through `json_serialize_sql` for free. **This is the only place an enum value is added,
once.** Every macro node kind afterward rides on it via `tag` + `properties`.

Statement-level: the existing `ExtensionStatement` is the legacy `ParserExtension` wrapper
(opaque parse-data, serialization deliberately throws), so it is *not* reused. `macro_def`
gets a parallel self-describing statement escape node (same pattern, still to build).

---

## What lives in this extension (zero further fork edits)

- **Grammar fragment**, hung off the extension points:
  ```
  ExtensionStatementRule <- DefineMacroStatement
  ExtensionExprRule      <- MacroInvocation / Metavar

  DefineMacroStatement <- 'define' 'macro' Metavar '(' MacroParamList? ')'
                          'returning' FragmentType 'as' Expression
  MacroParamList <- MacroParam (',' MacroParam)*
  MacroParam     <- Metavar ':' FragmentType
  MacroInvocation<- Metavar '(' ArgList? ')'
  Metavar        <- '$' Identifier
  FragmentType   <- 'expr' / 'ident' / 'type' / 'literal'
  ```
  (reuses core `Identifier` / `Expression` / arg-list rules wholesale)
- **Trampoline transforms** producing tagged escape nodes (`children` = structured
  sub-expressions, `properties` = JSON metadata):
  `define macro …` → statement node `{tag:"macro_def", children:[body], properties:{name, params:[{name,frag}], returning}}`
  `$name(args)` → `ExtensionExpression{tag:"macro_ref", children:[args…], properties:{name}}`
  `$x` → `ExtensionExpression{tag:"metavar", properties:{name}}`
- The **fragment-kind list** and `properties` JSON schema.

(No serialize callbacks — nodes are self-describing and serialize generically.)

### Serialized AST shape (illustrative)

`json_serialize_sql('define macro $incr($x: expr) returning expr as $x + 1')` →

```json
{"statements":[{"class":"EXTENSION","tag":"macro_def",
  "payload":{"name":"incr","returning":"expr",
    "params":[{"name":"x","frag":"expr"}],
    "body":{"class":"FUNCTION","function_name":"+","children":[
      {"class":"EXTENSION","tag":"metavar","payload":{"name":"x"}},
      {"class":"CONSTANT","value":1}]}}}]}
```

---

## Resolution (out of scope for the extension — `duckbuild-cli`)

The extension only makes macros **parse and serialize**. `duckbuild-cli` (Rust) owns:
collecting `macro_def` nodes, type-checking invocation args against parameter fragment
kinds, enforcing hygiene (metavars resolve only to declared params; no implicit capture),
recursively substituting `metavar`/`macro_ref` nodes, and emitting plain DuckDB SQL.
