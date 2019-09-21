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
%token<std::string> COMMONDEFS;

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
%token DOUBLECOLON "::";
%token SHIFTLEFT "<<";
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
%token EXTERN_DISPATCHER_TRAP "EXTERN_DISPATCHER_TRAP";
%token PASCAL_TRAP "PASCAL_TRAP";
%token PASCAL_SUBTRAP "PASCAL_SUBTRAP";
%token PASCAL_FUNCTION "PASCAL_FUNCTION";
%token REGISTER_TRAP "REGISTER_TRAP";
%token REGISTER_TRAP2 "REGISTER_TRAP2";
%token REGISTER_FLAG_TRAP "REGISTER_FLAG_TRAP";
%token REGISTER_2FLAG_TRAP "REGISTER_2FLAG_TRAP";
%token REGISTER_SUBTRAP "REGISTER_SUBTRAP";
%token REGISTER_SUBTRAP2 "REGISTER_SUBTRAP2";
%token REGISTER_FUNCTION "REGISTER_FUNCTION";
%token NOTRAP_FUNCTION "NOTRAP_FUNCTION";
%token NOTRAP_FUNCTION2 "NOTRAP_FUNCTION2";
%token FILE_TRAP "FILE_TRAP";
%token HFS_TRAP "HFS_TRAP";
%token FILE_SUBTRAP "FILE_SUBTRAP";
%token HFS_SUBTRAP "HFS_SUBTRAP";
%token LOWMEM_ACCESSOR "LOWMEM_ACCESSOR";

%token FOURCC "FOURCC";
%token TICK "TICK";

%left "-"
%left "<<";
%left "|";


%code requires {
	#include "yaml-cpp/yaml.h"
	#include <unordered_map>
	#include <sstream>

	struct RegConv
	{
		std::string ret;
		std::vector<std::string> args;

		explicit operator bool() const
		{
			return !ret.empty() || !args.empty();
		}
	};

	struct RegConvAndExtras
	{
		RegConv conv;
		std::string extras;
	};
}
%code provides {
	yy::HeaderParser::symbol_type yylex();
}
%code {
	#include <stack>

	std::vector<YAML::Node> things;
	std::unordered_map<std::string, int> names;
	int gAnonymousIndex = 0;
	std::unordered_map<std::string, std::vector<YAML::Node>> commonDefs;

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
			things[idx].begin()->second["name"] = newName;
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

	void handleTypedef(
			const std::string& comments,
			const std::string& type_pre, 
			const std::vector<std::pair<std::string, std::string>>& declaratorList,
			const std::string& rcomment)
	{
		bool first = true;
		for(auto [typeOpPost, name] : declaratorList)
		{
			YAML::Node node;
			node["name"] = name;
			node["type"] = type_pre + typeOpPost;
			if(first)
				addComment(node, false, comments);
			first = false;
			declare(wrap("typedef", node));
		}
		addComment(things.back(), true, rcomment);
	}
	void handleTypedef(
		const std::string& comments,
		YAML::Node& type, 
		const std::vector<std::pair<std::string, std::string>>& declaratorList,
		const std::string& rcomment)

	{
		std::string typeName = "";
		if(type.begin()->second["name"])
			typeName = type.begin()->second["name"].as<std::string>();
		
		if(typeName.empty())
		{
			for(auto [typeOpPost, name] : declaratorList)
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
			type.begin()->second["name"] = typeName;
		}
		declare(type);

		bool first = true;
		for(auto [typeOpPost, name] : declaratorList)
		{
			if(name == typeName)
			{
				if(!typeOpPost.empty())
					;
			}
			else
			{
				YAML::Node node;
				node["name"] = name;
				node["type"] = typeName + typeOpPost;
				if(first)
					addComment(node, false, comments);
				first = false;
				declare(wrap("typedef", node));
			}
		}
		addComment(things.back(), true, rcomment);
	}

	void setRegisterArgs(YAML::Node& n, const RegConv& regconv)
	{
		auto args = n["args"];
		if(regconv.ret != "void")
			n["returnreg"] = regconv.ret;

		for(int i = 0; i < args.size(); i++)
			args[i]["register"] = regconv.args[i];
		if(!args.size())
			n.remove("args");
	}

	int toInt(std::string str)
	{
		return strtol(str.c_str(), nullptr, 0);
	}

	std::string mbcomma(std::string str)
	{
		if(str.empty())
			return "";
		else
			return str + ", ";
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
	|	lowmem_accessor
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
	|	enum_values1 "," rcomment
		{ $$ = $1; addComment($$.back(), $3); }
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
	|	IDENTIFIER
	|	"-" expression { $$ = "-" + $2; }
	|	"(" expression ")" { $$ = $2; }
	|	expression "-" expression { $$ = $1 + " - " + $3; }
	|	expression "<<" expression { $$ = $1 + " << " + $3; }
	|	expression "|" expression { $$ = $1 + " | " + $3; }
	|	"sizeof" "(" IDENTIFIER ")" { $$ = "sizeof(" + $3 + ")"; }
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
				node["members"] = sequence(*$3);
			$$ = wrap($1 ? "union" : "struct", node);
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
	|	struct_members COMMONDEFS ";"	{ 
			YAML::Node n;
			n["common"] = $2;
			$$ = std::move($1); $$.push_back(std::move(n)); 
		}
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
	|	comments struct_or_union "{" struct_members "}" IDENTIFIER ";" rcomment
		{
			$$["name"] = $6;
			$$[$2 ? "union" : "struct"] = sequence($4);
			addComment($$, false, $1, $8);
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
		"UPP" "<" type "(" argument_list ")" funptr_callconv ">"
		{
			YAML::Node node;
			if($3 != "void")
				node["return"] = $3;
			if($5 && $5.size() > 0)
				node["args"] = $5;
			if($7.conv)
				setRegisterArgs(node, $7.conv);
			if(!$7.extras.empty())
				node["executor_extras"] = $7.extras;

			$$ = wrap("funptr", node);
		}
	;

%type <RegConvAndExtras> funptr_callconv;
funptr_callconv:
		%empty { $$ = {}; }
	|	"," IDENTIFIER "<" regcall_conv regcall_extras ">"
		{ $$ = { $4, $5 }; }
	;

typedef:
		comments "typedef" type_pre typedef_declarator_list ";" rcomment
		{ handleTypedef($1, $3, $4, $6); }
	|	comments "typedef" complex_type typedef_declarator_list ";" rcomment
		{ handleTypedef($1, $3, $4, $6); }
	|	comments "using" IDENTIFIER "=" type ";" rcomment
		{ handleTypedef($1, $5, { {"", $3} }, $7); }
	|	comments "using" IDENTIFIER "=" complex_type ";" rcomment
		{ handleTypedef($1, $5, { {"", $3} }, $7); }
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
		argument { if($1 && $1.size()) $$.push_back($1); }
	|	argument_list1 "," argument { $$ = std::move($1); $$.push_back($3); }
	;

%type <YAML::Node> argument;
argument:
		type
		{
			if($1 == "void")
				$$ = {};
			else
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
		{
			YAML::Node node;
			node["name"] = $7;
			node["type"] = $5;
			node["address"] = $9;
			
			addComment(node, false, $1, $12);
			declare(wrap("lowmem", node));
		}
	;

lowmem_accessor:
		LOWMEM_ACCESSOR "(" IDENTIFIER ")" ";"
	;

trap:
		comments "DISPATCHER_TRAP" "(" IDENTIFIER "," INTLIT "," selector_location ")" ";" rcomment
		{
			YAML::Node node;
			node["name"] = $4;
			node["trap"] = $6;
			node["selector-location"] = $8;
			
			addComment(node, false, $1, $11);
			declare(wrap("dispatcher", node));
		}
	|	comments "EXTERN_DISPATCHER_TRAP" "(" IDENTIFIER "," INTLIT "," selector_location ")" ";" rcomment
	|	"PASCAL_TRAP" "(" IDENTIFIER "," INTLIT ")" ";"
		{
			renameThing("C_"+$3, $3);
			auto& n = thingByName($3).begin()->second;
			n["trap"] = $5;
			n["executor"] = "C_";
		}
	|	"NOTRAP_FUNCTION" "(" IDENTIFIER ")" ";"
		{
			renameThing("C_"+$3, $3);
			auto& n = thingByName($3).begin()->second;
			n["executor"] = "C_";
		}
	|	"NOTRAP_FUNCTION2" "(" IDENTIFIER ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
		}
	|	"PASCAL_SUBTRAP" "(" IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER ")" ";"
		{
			renameThing("C_"+$3, $3);
			auto& n = thingByName($3).begin()->second;
			n["dispatcher"] = $9;
			n["selector"] = $7;
			n["executor"] = "C_";
		}
	|	"REGISTER_TRAP2" "(" IDENTIFIER "," INTLIT "," regcall_conv regcall_extras ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["trap"] = $5;
			setRegisterArgs(n, $7);
			if(!$8.empty())
				n["executor_extras"] = $8;
		}
	|	"REGISTER_FLAG_TRAP" "("
			IDENTIFIER "," IDENTIFIER "," IDENTIFIER "," 
			INTLIT "," 
			type_pre type_op "(" argument_list ")" ","
			regcall_conv regcall_extras ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["trap"] = $9;
			renameThing($3, $5);
			setRegisterArgs(n, $17);
			
			n["variants"] = std::vector<std::string>{ $5, $7 };
			if($3 != $5)
				n["executor"] = $3;
			if(!$18.empty())
				n["executor_extras"] = $18;
		}
	|	"REGISTER_2FLAG_TRAP" "("
			IDENTIFIER "," 
			IDENTIFIER "," IDENTIFIER "," IDENTIFIER "," IDENTIFIER ","
			INTLIT "," 
			type_pre type_op "(" argument_list ")" ","
			regcall_conv regcall_extras ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["trap"] = $13;
			renameThing($3, $5);
			setRegisterArgs(n, $21);

			n["variants"] = std::vector<std::string>{ $5, $7, $9, $11 };
			if($3 != $5)
				n["executor"] = $3;
			if(!$22.empty())
				n["executor_extras"] = $22;
		}
	|	"REGISTER_SUBTRAP" "(" IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER "," regcall_conv regcall_extras ")" ";"
		{
			renameThing("C_"+$3, $3);
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["dispatcher"] = $9;
			n["selector"] = $7;
			setRegisterArgs(n, $11);
			n["executor"] = "C_";
			if(!$12.empty())
				n["executor_extras"] = $12;
		}
	|	"REGISTER_SUBTRAP2" "(" IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER "," regcall_conv regcall_extras ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["dispatcher"] = $9;
			n["selector"] = $7;
			setRegisterArgs(n, $11);
			if(!$12.empty())
				n["executor_extras"] = $12;
		}
	|	"FILE_TRAP" "(" IDENTIFIER "," IDENTIFIER "," INTLIT ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["file_trap"] = true;
			n["trap"] = $7;
			n["returnreg"] = "D0";
			n["args"][0]["register"] = "A0";
			n["args"][1]["register"] = "TrapBit<0x400>";
			n["variants"] = std::vector<std::string>{ $3 + "Sync", $3 + "Async" };
		}
	|	"HFS_TRAP" "(" IDENTIFIER "," IDENTIFIER "," IDENTIFIER "," INTLIT ")" ";"
		{
			auto& mfs = thingByName($3).begin()->second;
			auto& hfs = thingByName($5).begin()->second;

			mfs["executor"] = true;
			mfs["file_trap"] = "mfs";
			mfs["trap"] = $9;
			mfs["returnreg"] = "D0";
			mfs["args"][0]["register"] = "A0";
			mfs["args"][1]["register"] = "TrapBit<0x400>";
			mfs["variants"] = std::vector<std::string>{ $3 + "Sync", $3 + "Async" };
			
			hfs["executor"] = true;
			hfs["file_trap"] = "hfs";
			hfs["trap"] = toInt($9) | 0x200;
			hfs["returnreg"] = "D0";
			hfs["args"][0]["register"] = "A0";
			hfs["args"][1]["register"] = "TrapBit<0x400>";
			hfs["variants"] = std::vector<std::string>{ $5 + "Sync", $5 + "Async" };
		}
	|	"FILE_SUBTRAP" "(" IDENTIFIER "," IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER ")" ";"
		{
			auto& n = thingByName($3).begin()->second;
			n["executor"] = true;
			n["file_trap"] = true;
			n["trap"] = $7;
			n["dispatcher"] = $11;
			n["selector"] = $9;
			n["returnreg"] = "D0";
			n["args"][0]["register"] = "A0";
			n["args"][1]["register"] = "TrapBit<0x400>";
			n["variants"] = std::vector<std::string>{ $3 + "Sync", $3 + "Async" };
		}
	|	"HFS_SUBTRAP" "(" IDENTIFIER "," IDENTIFIER "," IDENTIFIER "," INTLIT "," INTLIT "," IDENTIFIER ")" ";"
		{
			auto& mfs = thingByName($3).begin()->second;
			auto& hfs = thingByName($5).begin()->second;

			mfs["executor"] = true;
			mfs["file_trap"] = "mfs";
			mfs["trap"] = $9;
			mfs["dispatcher"] = $13;
			mfs["selector"] = $11;
			mfs["returnreg"] = "D0";
			mfs["args"][0]["register"] = "A0";
			mfs["args"][1]["register"] = "TrapBit<0x400>";
			mfs["variants"] = std::vector<std::string>{ $3 + "Sync", $3 + "Async" };

			hfs["executor"] = true;
			hfs["file_trap"] = "hfs";
			hfs["trap"] = toInt($9) | 0x200;
			hfs["dispatcher"] = $13;
			hfs["selector"] = $11;
			hfs["returnreg"] = "D0";
			hfs["args"][0]["register"] = "A0";
			hfs["args"][1]["register"] = "TrapBit<0x400>";
			hfs["variants"] = std::vector<std::string>{ $5 + "Sync", $5 + "Async" };
		}
	;

%type <std::string> selector_location;
selector_location:
		IDENTIFIER
	|	IDENTIFIER "<" INTLIT ">" { $$ = $1 + "<" + $3 + ">"; }
	;

%type <RegConv> regcall_conv;
regcall_conv:
		IDENTIFIER "(" regcall_args ")"
		{ $$ = {$1, std::move($3)}; }
	;

%type <std::vector<std::string>> regcall_args;
regcall_args:
		%empty	{ $$ = {}; }
	|	regcall_args1
	;

%type <std::vector<std::string>> regcall_args1;
regcall_args1:
		regcall_arg	{ $$ = { $1 }; }
	|	regcall_args1 "," regcall_arg
		{ $$ = std::move($1); $$.push_back($3); }
	;

%type <std::string> regcall_arg;
regcall_arg:
		IDENTIFIER
	|	IDENTIFIER "<" IDENTIFIER ">" { $$ = $1 + "<" + $3 + ">"; }
	|	IDENTIFIER "<" INTLIT ">"
		{
			$$ = $1 + "<" + $3 + ">";
		}
	|	IDENTIFIER "<" IDENTIFIER "," IDENTIFIER ">" 
		{
			if($1 == "Out" || $1 == "InOut")
				$$ = $1 + "<" + $5 + ">";
			else
				$$ = $1 + "<" + $3 + ", " + $5 + ">";
		}
	;

%type <std::string> regcall_extras;
regcall_extras:
		%empty { $$ = ""; }
	|	regcall_extras "," IDENTIFIER { $$ = mbcomma($1) + $3; }
	|	regcall_extras "," IDENTIFIER "<" IDENTIFIER ">"
		{ $$ = mbcomma($1) + $3 + "<" + $5 + ">"; }
	|	regcall_extras "," IDENTIFIER "::" IDENTIFIER "<" IDENTIFIER ">"
		{ $$ = mbcomma($1) + $3 + "::" + $5 + "<" + $7 + ">"; }
	;

function:
		comments opt_extern type_pre type_op IDENTIFIER "(" argument_list ")" ";" rcomment
		{
			YAML::Node node;
			node["name"] = $5;
			if($3 + $4 != "void")
				node["return"] = $3 + $4;
			if($7 && $7.size() > 0)
				node["args"] = $7;
			addComment(node, false, $1, $10);
			declare(wrap("function", node));
		}
	;

opt_extern:
		%empty
	|	"extern"
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
					+ ($1.empty() ? $2 : "/* " + $1 + " */\n" + $2);
			}
			else
			{
				YAML::Node node;
				node["code"] = $1.empty() ? $2 : "/* " + $1 + " */\n" + $2;
				declare(wrap("executor_only", node));
			}
		}
	;
%%
