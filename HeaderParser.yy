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
%token<std::string> EXECUTOR_ONLY;

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

%left EXECUTOR_ONLY;
%right COMMENT;

%code requires {
	#include "yaml-cpp/yaml.h"
	#include <unordered_map>
	#include <sstream>
}
%code provides {
	yy::HeaderParser::symbol_type yylex();
}
%code {
	#include <stack>

	std::vector<YAML::Node> things;
	std::unordered_map<std::string, int> names;
	int gAnonymousIndex = 0;

	std::ostringstream executorOnly;

	void declare(YAML::Node node)
	{
		things.push_back(std::move(node));
		if(node.begin()->second["name"])
			names[node.begin()->second["name"].as<std::string>()] = things.size() - 1;
	}

	void renameThing(const std::string& name, const std::string& newName)
	{
		auto p = names.find(name);
		if(p != names.end())
		{
			int idx = p->second;
			names.erase(p);
			names[newName] = idx;
		}
	}

	YAML::Node& thingByName(const std::string& name)
	{
		return things[names[name]];
	}

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
		"{" declarations "}" postamble
    ;

postamble:
		%empty
	|	postamble EXECUTOR_ONLY
	;

declarations:
		%empty
	|	declarations declaration
	;

%type <std::string> comments;
comments:
		%empty { $$ = ""; }
	|	comments COMMENT
		{ $$ = concatComments($1, $2); }
	;

%type <std::string> rcomment;
rcomment:
		%empty { $$ = ""; }
	|	RIGHTCOMMENT
	;

declaration:
		enum_decl
	|	struct_decl
	|	typedef
	|	lowmem
	|	trap
	|	function
	|	size_assertion
	|	executor_only
	;

enum_decl:
		comments enum ";" rcomment
		{
			addComment($2, true, $1, $4);
			declare($2);
		}
	;

%type <YAML::Node> enum;
enum:
		"enum" optional_identifier "{" enum_values "}"
		{
			YAML::Node node;
			if(!$2.empty())
				node["name"] = $2;
			node["values"] = sequence($4);
			$$ = wrap("enum", node);
		}
	;

%type <std::vector<YAML::Node>> enum_values;
enum_values:
		%empty { }
	|	enum_values1
	|	enum_values1 ","
	;

%type <std::vector<YAML::Node>> enum_values1;
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

%type <YAML::Node> enum_value;
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

%type <std::string> expression;
expression:
		INTLIT
	|	CHARLIT
	|	"FOURCC" "(" CHARLIT "," CHARLIT "," CHARLIT "," CHARLIT ")"
		{ 
			auto q = [](const std::string& a) { return a.substr(1, a.size()-2); };
			$$ = "'" + q($3) + q($5) + q($7) + q($9) + "'";
		}
	|	IDENTIFIER
	|	"-" expression { $$ = "-" + $2; }
	|	"(" expression ")" { $$ = $2; }
	;

struct_decl:
		comments struct ";" rcomment
		{
			addComment($2, true, $1, $4);
			declare($2);
		}
	;

%type <YAML::Node> struct;
struct:
		struct_or_union IDENTIFIER optional_struct_body
		{
			YAML::Node node;
			node["name"] = $2;
			if($3)
			{
				node["members"] = sequence(*$3);
				$$ = wrap($1 ? "union" : "struct", node);
			}
			else
				$$ = wrap("forward_struct", node);
		}
	|	struct_or_union "{" struct_members "}"
		{
			YAML::Node node;
			node["members"] = sequence($3);
			$$ = wrap($1 ? "union" : "struct", node);
		}
	;

%type <std::optional<std::vector<YAML::Node>>> optional_struct_body;
optional_struct_body:
		%empty {}
	|	"{"	struct_members "}"	{ $$ = $2; }
	;

%type <std::string> optional_identifier;
optional_identifier:
		%empty {}
	|	IDENTIFIER
	;

%type <bool> struct_or_union;
struct_or_union:
		"struct" { $$ = false; }
	|	"union" { $$ = true; }
	;

%type <std::vector<YAML::Node>> struct_members;
struct_members:
		%empty { $$ = {}; }
	|	"GUEST_STRUCT" ";" { $$ = {}; }
	|	struct_members struct_member
		{ $$ = std::move($1); $$.push_back($2); }
	;

%type <YAML::Node> struct_member;
struct_member:
		comments type_pre type_op IDENTIFIER type_post ";" rcomment
		{
			$$["name"] = $4;
			$$["type"] = $2 + $3 + $5;
			addComment($$, false, $1, $7);
		}
	;

%type <std::string> type;
type:
		type_pre type_op type_post { $$ = $1 + $2 + $3; }
	;

%type <std::string> type_pre;
type_pre:
		"GUEST" "<" type ">" { $$ = $3; }
	|	IDENTIFIER
	|	intlike_type
		{
			if($1 != 5)
				$1 &= ~1;
			switch($1)
			{
				case 0:	$$ = "int32_t"; break;
				case 2: $$ = "uint32_t"; break;
				case 4:	$$ = "char"; break;
				case 5: $$ = "int8_t"; break;
				case 6: $$ = "uint8_t"; break;
				case 8: $$ = "int16_t"; break;
				case 10: $$ = "uint16_t"; break;
				case 16: $$ = "int32_t"; break;
				case 18: $$ = "uint32_t"; break;
				default: $$ = "invalid_int_type"; break;
			}
		}
	|	"const" type_pre { $$ = "const " + $2; }
	;

%type <std::string> type_op;
type_op:
		%empty	{}
	|	type_op "*"	{ $$ = $1 + "*"; }
	;

%type <int> intlike_type;
intlike_type:
		intlike_type_elem 
	|	intlike_type intlike_type_elem { $$ = $1 | $2; }
	;

%type <int> intlike_type_elem;
intlike_type_elem:
		INT { $$ = 0; }
	|	SIGNED { $$ = 1; }
	|	UNSIGNED { $$ = 2; }
	|	CHAR { $$ = 4; }
	|	SHORT { $$ = 8; }
	|	LONG { $$ = 16; }
	;

%type <std::string> type_post;
type_post:
		%empty {}
	|	type_post "[" expression "]" { $$ = $1 + "[" + $3 + "]"; }
	;

%type <YAML::Node> funptr;
funptr:
		"UPP" "<" type "(" argument_list ")" ">"
		{
			YAML::Node node;
			node["return"] = $3;
			if($5.size())
				node["args"] = $5;
			$$ = wrap("funptr", node);
		}
	;

typedef:
		comments "typedef" type_pre typedef_declarator_list ";" rcomment
		{
			bool first = true;
			for(auto [typeOpPost, name] : $4)
			{
				YAML::Node node;
				node["name"] = name;
				node["type"] = $3 + typeOpPost;
				if(first)
					addComment(node, false, $1);
				first = false;
				declare(wrap("typedef", node));
			}
			addComment(things.back(), true, $6);
		}
	|	comments "typedef" complex_type typedef_declarator_list ";" rcomment
		{
			std::string typeName = "";
			if($3.begin()->second["name"])
				typeName = $3.begin()->second["name"].as<std::string>();
			
			if(typeName.empty())
			{
				for(auto [typeOpPost, name] : $4)
				{
					if(typeOpPost.empty())
					{
						typeName = name;
						break;
					}
				}
				if(typeName.empty())
				{
					std::ostringstream str;
					str << "_anonymous" << ++gAnonymousIndex;	// FIXME: file name?
					typeName = str.str();
				}
				$3.begin()->second["name"] = typeName;
			}
			declare($3);

			bool first = true;
			for(auto [typeOpPost, name] : $4)
			{
				if(name == typeName)
				{
					if(!typeOpPost.empty())
						error("contradictory: " + name);
				}
				else
				{
					YAML::Node node;
					node["name"] = name;
					node["type"] = typeName + typeOpPost;
					if(first)
						addComment(node, false, $1);
					first = false;
					declare(wrap("typedef", node));
				}
			}
			addComment(things.back(), true, $6);
		}

	|	"using" IDENTIFIER "=" "UPP" "<" type "(" argument_list ")" ">"*/
	;

%type <YAML::Node> complex_type;
complex_type:
		struct
	|	enum
	|	funptr
	;

%type <std::vector<std::pair<std::string, std::string>>> typedef_declarator_list;
typedef_declarator_list:
		type_op IDENTIFIER type_post
		{ $$ = { {$1 + $3, $2} }; }
	|	typedef_declarator_list "," type_op IDENTIFIER type_post
		{ $$ = std::move($1); $$.emplace_back($3 + $5, $4); }
	;

%type <YAML::Node> argument_list;
argument_list:
		%empty	{}
	|	argument_list1
	;

%type <YAML::Node> argument_list1;
argument_list1:
		argument { $$.push_back($1); }
	|	argument_list1 "," argument { $$ = std::move($1); $$.push_back($3); }
	;

%type <YAML::Node> argument;
argument:
		type
		{
			$$["type"] = $1;
		}
	|	type_pre type_op IDENTIFIER type_post
		{
			$$["name"] = $3;
			$$["type"] = $1 + $2 + $4;
		}
	;

lowmem:
		comments "const" "LowMemGlobal" "<" type ">" IDENTIFIER "{" INTLIT "}" ";" rcomment
	;

trap:
		"DISPATCHER_TRAP" "(" IDENTIFIER "," INTLIT "," IDENTIFIER ")" ";"
	|	"PASCAL_TRAP" "(" IDENTIFIER "," INTLIT ")" ";"
		{
			renameThing("C_"+$3, $3);
			thingByName($3).begin()->second["trap"] = $5;
		}
	|	"PASCAL_FUNCTION" "(" IDENTIFIER ")" ";"
	|	"PASCAL_SUBTRAP" "(" IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER ")" ";"
		{
			renameThing("C_"+$3, $3);
			auto& fun = thingByName($3);
			fun.begin()->second["dispatcher"] = $9;
			fun.begin()->second["trap"] = $5;
			fun.begin()->second["selector"] = $7;
		}
	;

function:
		comments "extern" type_pre type_op IDENTIFIER "(" argument_list ")" ";" rcomment
		{
			YAML::Node node;
			node["name"] = $5;
			node["return"] = $3 + $4;
			if($7.size())
				node["args"] = $7;
			addComment(node, false, $1, $10);
			declare(wrap("function", node));
		}
	;

size_assertion:
		"static_assert" "(" "sizeof" "(" IDENTIFIER ")" EQUAL INTLIT ")" ";"
		{
			things[names[$5]].begin()->second["size"] = $8;
		}
	;

executor_only:
		comments EXECUTOR_ONLY
		{
			if(things.size() && things.back().begin()->first.as<std::string>() == "executor_only")
			{				
				things.back().begin()->second["code"]
					= things.back().begin()->second["code"].as<std::string>() + "\n"
					+ ($1.empty() ? $2 : "// " + $1 + "\n" + $2);
			}
			else
			{
				YAML::Node node;
				node["code"] = $1.empty() ? $2 : "// " + $1 + "\n" + $2;
				declare(wrap("executor_only", node));
			}
		}
	;
%%
