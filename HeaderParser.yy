%require "3.0.2"
%defines

%define api.parser.class {HeaderParser}
%skeleton "lalr1.cc"

%define api.token.constructor
%define api.value.type variant
%define parse.assert
%define parse.error verbose

%token<std::string> IDENTIFIER;
%token<std::string> STRINGLIT;
%token<std::string> INTLIT;
%token<std::string> CHARLIT;
%token<std::string> COMMENT;
%token<std::string> RIGHTCOMMENT;

%token LEFTBRACE "{";
%token RIGHTBRACE "}";
%token LEFTBRACKET "[";
%token RIGHTBRACKET "]";
%token LEFTPAREN "(";
%token RIGHTPAREN ")";
%token SEMICOLON ";";
%token COMMA ",";
%token PLUS "+";
%token MINUS "-";
%token DIVIDE "/";
%token STAR "*";
%token ASSIGN "=";
%token COLON ":";
%token SHIFTLEFT "<<";
%token SHIFTRIGHT ">>";
%token EQUAL "==";
%token NOTEQUAL "!=";
%token AND "&";
%token OR "|";
%token XOR "^";
%token COMPL "~";
%token DOLLAR "$";
%token LESS "<";
%token GREATER ">";

%token ENUM "enum";
%token STRUCT "struct";
%token UNION "union";
%token TYPEDEF "typedef";
%token USING "using";
%token EXTERN "extern";
%token CONST "const";
%token STATIC_ASSERT "static_assert";
%token SIZEOF "sizeof";

%token INT "int";
%token UNSIGNED "unsigned";
%token SHORT "short";
%token LONG "long";
%token CHAR "char";
%token SIGNED "signed";

%token GUEST "GUEST";
%token GUEST_STRUCT "GUEST_STRUCT";
%token UPP "UPP";
%token LOWMEMGLOBAL "LowMemGlobal";

%token DISPATCHER_TRAP "DISPATCHER_TRAP";
%token PASCAL_TRAP "PASCAL_TRAP";
%token PASCAL_SUBTRAP "PASCAL_SUBTRAP";
%token PASCAL_FUNCTION "PASCAL_FUNCTION";

%token FOURCC "FOURCC";

%type <YAML::Node>	declaration enum struct typedef lowmem trap function size_assertion enum_value
%type <std::vector<YAML::Node>>	enum_values enum_values1
%type <std::string> comments rcomment
%type <std::vector<YAML::Node>>	struct_members
%type <YAML::Node> struct_member
%type <std::string> expression

%code requires {
	#include "yaml-cpp/yaml.h"
}
%code provides {
	yy::HeaderParser::symbol_type yylex();
}
%code {
	#include <stack>

	YAML::Emitter yamlout;

    void yy::HeaderParser::error(std::string const& err)
	{
		std::cout << err << std::endl;
	}

	template<typename T>
	T popstack(std::stack<T>& s)
	{
		T x = std::move(s.top());
		s.pop();
		return x;
	}

	YAML::Node wrap(std::string s, YAML::Node n)
	{
		YAML::Node d;
		d[s] = n;
		return d;
	}

	template<typename Seq>
	YAML::Node sequence(const Seq& seq)
	{
		YAML::Node seqnode;
		for(const auto& n : seq)
			seqnode.push_back(n);
		return seqnode;
	}

	std::string concatComments(const std::string& a, const std::string& b)
	{
		return a.empty() ? b : a + "\n" + b;
	}

	void addComment(YAML::Node& node, const std::string& comment)
	{
		if(comment.empty())
			return;
		if(node["comment"])
			node["comment"] = node["comment"].as<std::string>()
				+ "\n" + comment;
		else
			node["comment"] = comment;

	}

	void addComment(YAML::Node& node, bool wrapped, const std::string& comment)
	{
		if(!wrapped)
		{
			addComment(node, comment);
			return;
		}

		if(!node || node.size() == 0)
			return;
		addComment(node.begin()->second, comment);

	}

	void addComment(YAML::Node& node, bool wrapped, const std::string& pre, const std::string& right)
	{
		addComment(node, wrapped, pre);
		addComment(node, wrapped, right);
	}
}

%%
%start header;

header: 
		"{" declarations "}"
    ;

declarations:
		%empty
	|	declarations comments declaration rcomment
		{
			if($3.size())
			{
				addComment($3, true, $2, $4);
				yamlout << $3;
			}
		}
	;

comments:
		%empty { $$ = ""; }
	|	comments COMMENT
		{ $$ = concatComments($1, $2); }
	;

rcomment:
		%empty { $$ = ""; }
	|	RIGHTCOMMENT
	;


declaration:
		enum ";"
	|	struct ";"
	|	typedef	";"
	|	lowmem ";"
	|	trap ";"
	|	function ";"
	|	size_assertion ";"
	;

enum:
		"enum" "{" enum_values "}"
		{
			$$ = wrap("enum", wrap("values", sequence($3)));
		}
	;

enum_values:
		%empty { }
	|	enum_values1
	|	enum_values1 ","
	;

enum_values1:
		comments enum_value rcomment
		{
			addComment($2, false, $1, $3);
			$$ = { $2 };
		}
	|	enum_values1 "," rcomment comments enum_value rcomment
		{
			addComment($1.back(), false, $3);
			addComment($5, false, $4, $6);
			$1.push_back($5);
			$$ = std::move($1);
		}
	;

enum_value:
		IDENTIFIER
		{
			$$["name"] = $1;
		}
	|	IDENTIFIER "=" expression
		{
			$$["name"] = $1;
			$$["value"] = $3;
		}
	;

expression:
		INTLIT
	|	CHARLIT
	|	"FOURCC" "(" CHARLIT "," CHARLIT "," CHARLIT "," CHARLIT ")"
		{ 
			auto q = [](const std::string& a) { return a.substr(1, a.size()-2); };
			$$ = "'" + q($3) + q($5) + q($7) + q($9) + "'";
		}
	;

struct:
		"struct" IDENTIFIER "{"	struct_members "}"
		{
			YAML::Node node;
			node["name"] = $2;
			node["members"] = sequence($4);
			$$ = wrap("struct", node);
		}
	;

struct_members:
		%empty { $$ = {}; }
	|	"GUEST_STRUCT" ";" { $$ = {}; }
	|	struct_members struct_member
		{ $$ = std::move($1); $$.push_back($2); }
	;

struct_member:
		comments type_pre IDENTIFIER type_post ";" rcomment
		{
			$$["name"] = $3;
		}
	;

type:
		type_pre type_post
	;
	
type_pre:
		"GUEST" "<" type ">"
	|	IDENTIFIER
	|	intlike_type
	|	type_pre "*"
	|	"const" type_pre
	|	enum
	|	struct
	;

intlike_type:
		intlike_type_elem
	|	intlike_type intlike_type_elem
	;

intlike_type_elem:
		INT
	|	UNSIGNED
	|	SHORT
	|	LONG
	|	CHAR
	|	SIGNED
	;

type_post:
		%empty
	|	type_post "[" expression "]"
	;

typedef:
		"typedef" type_pre IDENTIFIER type_post
	|	"using" IDENTIFIER "=" type
	|	"typedef" "UPP" "<" type "(" argument_list ")" ">" IDENTIFIER
	|	"using" IDENTIFIER "=" "UPP" "<" type "(" argument_list ")" ">"
	;

argument_list:
		%empty
	|	argument_list1
	;

argument_list1:
		argument
	|	argument_list1 "," argument
	;

argument:
		type
	|	type IDENTIFIER
	;

lowmem:
		"const" "LowMemGlobal" "<" type ">" IDENTIFIER "{" INTLIT "}"
	;

trap:
		"DISPATCHER_TRAP" "(" IDENTIFIER "," INTLIT "," IDENTIFIER ")"
	|	"PASCAL_TRAP" "(" IDENTIFIER "," INTLIT ")"
	|	"PASCAL_FUNCTION" "(" IDENTIFIER ")"
	|	"PASCAL_SUBTRAP" "(" IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER ")"
	;

function:
		"extern" type_pre IDENTIFIER "(" argument_list ")"
	;

size_assertion:
		"static_assert" "(" "sizeof" "(" IDENTIFIER ")" EQUAL INTLIT ")"
	;
%%
