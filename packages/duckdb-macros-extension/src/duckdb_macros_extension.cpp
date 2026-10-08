#define DUCKDB_EXTENSION_MAIN

#include "duckdb_macros_extension.hpp"
#include "duckdb.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/function/scalar_function.hpp"
#include <duckdb/parser/parsed_data/create_scalar_function_info.hpp>

#include "duckdb/parser/grammar_extension.hpp"
#include "duckdb/parser/extension_node.hpp"
#include "duckdb/parser/expression/extension_expression.hpp"
#include "duckdb/parser/statement/custom_statement.hpp"
#include "duckdb/parser/statement/select_statement.hpp"
#include "duckdb/parser/peg/transformer/parse_result.hpp"
#include "duckdb/parser/peg/transformer/peg_transformer.hpp"
#include "duckdb/parser/peg/transformer/transform_result.hpp"

namespace duckdb {

inline void DuckdbMacrosScalarFun(DataChunk &args, ExpressionState &state, Vector &result) {
	auto &name_vector = args.data[0];
	UnaryExecutor::Execute<string_t, string_t>(name_vector, result, args.size(), [&](string_t name) {
		return StringVector::AddString(result, "...........🦆 " + name.GetString());
	});
}

static unique_ptr<TransformResultValue> WrapExpr(unique_ptr<ParsedExpression> expr) {
	return make_uniq<TypedTransformResult<unique_ptr<ParsedExpression>>>(std::move(expr));
}

// MacroInvocation <- Identifier '!' '(' List(Expression)? ')'      (name=0, '!'=1, '('=2, args=3, ')'=4)
static unique_ptr<TransformResultValue> TransformMacroInvocation(PEGTransformer &transformer,
                                                                 ParseResult &parse_result) {
	auto &list = parse_result.Cast<ListParseResult>();
	auto name = list.Child<IdentifierParseResult>(0).identifier.GetIdentifierName();
	vector<ExtensionNode> args;
	auto &opt = list.Child<OptionalParseResult>(3);
	if (opt.HasResult()) {
		for (auto &arg : PEGTransformerFactory::ExtractParseResultsFromList(opt.GetResult())) {
			args.push_back(
			    ExtensionNode::FromExpression(transformer.Transform<unique_ptr<ParsedExpression>>(arg.get())));
		}
	}
	auto node = make_uniq<ExtensionExpression>("macro_ref", std::move(args), "{\"name\":\"" + name + "\"}");
	return WrapExpr(std::move(node));
}

// Shared builder for `define macro name!(params) returning <kind> as <body>` (one rule per kind):
//   'define'(0) 'macro'(1) Ident(2) '!'(3) '('(4) List(MacroParam)?(5) ')'(6) 'returning'(7) <kind>(8) 'as'(9) body(10)
static unique_ptr<TransformResultValue> BuildMacroDef(ListParseResult &list, const string &returning,
                                                      ExtensionNode body) {
	auto name = list.Child<IdentifierParseResult>(2).identifier.GetIdentifierName();

	// params -> JSON array of {name, type}, where type is an AST fragment kind (expr/ident/type/query/...)
	string params_json = "[";
	auto &opt = list.Child<OptionalParseResult>(5);
	if (opt.HasResult()) {
		auto params = PEGTransformerFactory::ExtractParseResultsFromList(opt.GetResult());
		for (idx_t i = 0; i < params.size(); i++) {
			// MacroParam <- '$' Identifier ':' Identifier      (name=1, type=3)
			auto &p = params[i].get().Cast<ListParseResult>();
			params_json += (i > 0 ? "," : "");
			params_json += "{\"name\":\"" + p.Child<IdentifierParseResult>(1).identifier.GetIdentifierName() +
			               "\",\"type\":\"" + p.Child<IdentifierParseResult>(3).identifier.GetIdentifierName() + "\"}";
		}
	}
	params_json += "]";

	vector<ExtensionNode> children;
	children.push_back(std::move(body));
	auto stmt = make_uniq<CustomStatement>("macro_def", std::move(children),
	                                       "{\"name\":\"" + name + "\",\"params\":" + params_json +
	                                           ",\"returning\":\"" + returning + "\"}");
	unique_ptr<SQLStatement> result = std::move(stmt);
	return make_uniq<TypedTransformResult<unique_ptr<SQLStatement>>>(std::move(result));
}

// ... 'returning' 'expr' 'as' Expression  (body is a plain expression)
static unique_ptr<TransformResultValue> TransformDefineMacroExpr(PEGTransformer &transformer,
                                                                 ParseResult &parse_result) {
	auto &list = parse_result.Cast<ListParseResult>();
	auto body = transformer.Transform<unique_ptr<ParsedExpression>>(list.GetChild(10));
	return BuildMacroDef(list, "expr", ExtensionNode::FromExpression(std::move(body)));
}

// ... 'returning' 'query' 'as' SelectStatement  (body is a whole query, stored as a statement node)
static unique_ptr<TransformResultValue> TransformDefineMacroQuery(PEGTransformer &transformer,
                                                                  ParseResult &parse_result) {
	auto &list = parse_result.Cast<ListParseResult>();
	auto select = transformer.Transform<unique_ptr<SelectStatement>>(list.GetChild(10));
	return BuildMacroDef(list, "query", ExtensionNode::FromStatement(std::move(select)));
}

// ... 'returning' 'table' 'as' BaseTableRef  (body is a table reference)
static unique_ptr<TransformResultValue> TransformDefineMacroTable(PEGTransformer &transformer,
                                                                  ParseResult &parse_result) {
	auto &list = parse_result.Cast<ListParseResult>();
	auto table_ref = transformer.Transform<unique_ptr<TableRef>>(list.GetChild(10));
	return BuildMacroDef(list, "table", ExtensionNode::FromTableRef(std::move(table_ref)));
}

template <unique_ptr<TransformResultValue> (*FINALIZE)(PEGTransformer &, ParseResult &)>
static unique_ptr<TransformProcess> StartTransform(PEGTransformer &transformer, ParseResult &parse_result) {
	return make_uniq<FinalizeTransformProcess>(transformer, parse_result, FINALIZE);
}

//! The lexical-macro syntax, as a grammar extension (enable with `SET active_grammar_extensions = ['duckdb_macros']`).
//!
//! Macro references use Rust-style `name!(...)`. Metavariables `$x` are NOT a distinct node: in
//! expression positions they parse as DuckDB's native named parameters (ParameterExpression), so
//! parsing never has to tell a metavar from a prepared-statement parameter. duckbuild-cli
//! disambiguates at resolution (a `$x` in a macro body must resolve to exactly one of the macro's
//! declared params or an outer parameter; name shadowing is disallowed).
//!
//! Each `returning <kind>` is its own statement rule, so the body parses with the kind-appropriate
//! sub-grammar and is stored as the matching ExtensionNode (any AST hierarchy, not just expressions).
class MacroGrammarExtension final : public GrammarExtension {
public:
	MacroGrammarExtension() : GrammarExtension("duckdb_macros", "Lexical macro definitions and `name!(...)` calls") {
	}

	vector<GrammarChange> GetChanges() const override {
		vector<GrammarChange> changes;
		changes.push_back(GrammarChange::AddRule("MacroInvocation <- Identifier '!' '(' List(Expression)? ')'",
		                                         StartTransform<TransformMacroInvocation>));
		changes.push_back(GrammarChange::AddRule("MacroParam <- '$' Identifier ':' Identifier"));
		changes.push_back(GrammarChange::AddRule(
		    "DefineMacroExpr <- 'define' 'macro' Identifier '!' '(' List(MacroParam)? ')' 'returning' 'expr' 'as' "
		    "Expression",
		    StartTransform<TransformDefineMacroExpr>));
		changes.push_back(GrammarChange::AddRule(
		    "DefineMacroQuery <- 'define' 'macro' Identifier '!' '(' List(MacroParam)? ')' 'returning' 'query' 'as' "
		    "SelectStatementInternal",
		    StartTransform<TransformDefineMacroQuery>));
		changes.push_back(GrammarChange::AddRule(
		    "DefineMacroTable <- 'define' 'macro' Identifier '!' '(' List(MacroParam)? ')' 'returning' 'table' 'as' "
		    "BaseTableRef",
		    StartTransform<TransformDefineMacroTable>));
		// one statement rule per return kind (keyword-led, no collision)
		changes.push_back(GrammarChange::PrependChoice("Statement", "DefineMacroExpr"));
		changes.push_back(GrammarChange::PrependChoice("Statement", "DefineMacroQuery"));
		changes.push_back(GrammarChange::PrependChoice("Statement", "DefineMacroTable"));
		// prepended, so `name!(...)` beats the `!` factorial reading
		changes.push_back(GrammarChange::PrependChoice("SingleExpression", "MacroInvocation"));
		return changes;
	}
};

static void LoadInternal(ExtensionLoader &loader) {
	GrammarExtension::Register(loader.GetDatabaseInstance(), make_shared_ptr<MacroGrammarExtension>());

	// Register a scalar function
	auto duckdb_macros_scalar_function =
	    ScalarFunction("duckdb_macros", {LogicalType::VARCHAR}, LogicalType::VARCHAR, DuckdbMacrosScalarFun);

	loader.RegisterFunction(duckdb_macros_scalar_function);
}

void DuckdbMacrosExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}
std::string DuckdbMacrosExtension::Name() {
	return "duckdb_macros";
}

std::string DuckdbMacrosExtension::Version() const {
#ifdef EXT_VERSION_DUCKDB_MACROS
	return EXT_VERSION_DUCKDB_MACROS;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(duckdb_macros, loader) {
	duckdb::LoadInternal(loader);
}
}
