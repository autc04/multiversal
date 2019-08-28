%{
#include "HeaderParser.hpp"
#include <cctype>

bool atBOL;
#define YY_DECL yy::HeaderParser::symbol_type yylex (void)

static std::string strip(const char *p, const char *q)
{
    while(p < q && std::isspace(*p))
        ++p;
    while(p < q && std::isspace(q[-1]))
        --q;
    return std::string(p,q);
}

bool preambleRequested = true;


%}

%option noyywrap

%x preamble
%x executor_only

%%
    using hp = yy::HeaderParser;
    using token = hp::token;
    atBOL = false;

    if(preambleRequested) BEGIN(preamble);
    preambleRequested = false;

^"#if !defined(_"[A-Za-z0-9_]+_")"$  BEGIN(preamble);

<preamble>^"namespace Executor"  BEGIN(INITIAL);
<preamble>.|\n  ;

\n      atBOL = true;
[[:space:]]  /* */

"{"     return token::LEFTBRACE;
"}"     return token::RIGHTBRACE;
"["     return token::LEFTBRACKET;
"]"     return token::RIGHTBRACKET;
"("     return token::LEFTPAREN;
")"     return token::RIGHTPAREN;
";"     return token::SEMICOLON;
","     return token::COMMA;
"+"     return token::PLUS;
"-"     return token::MINUS;
"/"     return token::DIVIDE;
"*"     return token::STAR;
"="     return token::ASSIGN;
":"     return token::COLON;
"::"    return token::DOUBLECOLON;
"<<"    return token::SHIFTLEFT;
">>"    return token::SHIFTRIGHT;
"=="    return token::EQUAL;
"!="    return token::NOTEQUAL;
"&"     return token::AND;
"|"     return token::OR;
"^"     return token::XOR;
"~"     return token::COMPL;
"$"     return token::DOLLAR;
"<"     return token::LESS;
">"     return token::GREATER;

"enum"              return token::ENUM;
"struct"            return token::STRUCT;
"union"             return token::UNION;
"typedef"           return token::TYPEDEF;
"using"             return token::USING;
"extern"            return token::EXTERN;
"const"             return token::CONST;
"static_assert"     return token::STATIC_ASSERT;
"sizeof"            return token::SIZEOF;
"int"               return token::INT;
"unsigned"          return token::UNSIGNED;   
"short"             return token::SHORT;
"long"              return token::LONG;
"char"              return token::CHAR;
"signed"            return token::SIGNED;
"GUEST"             return token::GUEST;
"GUEST_STRUCT"      return token::GUEST_STRUCT;
"UPP"               return token::UPP;
"LowMemGlobal"      return token::LOWMEMGLOBAL;
"FOURCC"            return token::FOURCC;

"DISPATCHER_TRAP"      return token::DISPATCHER_TRAP;
"EXTERN_DISPATCHER_TRAP"      return token::EXTERN_DISPATCHER_TRAP;
"PASCAL_TRAP"          return token::PASCAL_TRAP;
"PASCAL_SUBTRAP"       return token::PASCAL_SUBTRAP;
"PASCAL_FUNCTION"      return token::PASCAL_FUNCTION;
"REGISTER_TRAP"        return token::REGISTER_TRAP;
"REGISTER_TRAP2"       return token::REGISTER_TRAP2;
"REGISTER_FLAG_TRAP"   return token::REGISTER_FLAG_TRAP;
"REGISTER_2FLAG_TRAP"  return token::REGISTER_2FLAG_TRAP;
"REGISTER_SUBTRAP"     return token::REGISTER_SUBTRAP;
"REGISTER_SUBTRAP2"    return token::REGISTER_SUBTRAP2;
"REGISTER_FUNCTION"    return token::REGISTER_FUNCTION;
"NOTRAP_FUNCTION"      return token::NOTRAP_FUNCTION;
"NOTRAP_FUNCTION2"     return token::NOTRAP_FUNCTION2;


[[:digit:]]+        return hp::make_INTLIT(yytext);
0x[[:xdigit:]]+     return hp::make_INTLIT(yytext);

\'.\'               return hp::make_CHARLIT(yytext);

[[:alpha:]_][[:alnum:]_]*   return hp::make_IDENTIFIER(yytext);

^" "*#.*(\\\n.*)*     return hp::make_EXECUTOR_ONLY(yytext);

^"BEGIN_EXECUTOR_ONLY"\n                   BEGIN(executor_only);
<executor_only>^"END_EXECUTOR_ONLY"\n      BEGIN(INITIAL); atBOL = true;
<executor_only>.*\n                        return hp::make_EXECUTOR_ONLY(std::string(yytext, yytext + yyleng - 1));

"/*"[^*]*("*"+[^*/]*)*"*"+"/" {
        if(atBOL)
            return hp::make_COMMENT(strip(yytext+2, yytext+yyleng-2));
        else
            return hp::make_RIGHTCOMMENT(strip(yytext+2, yytext+yyleng-2));
    }
"//".* {
        if(atBOL)
            return hp::make_COMMENT(strip(yytext+2,yytext+yyleng));
        else
            return hp::make_RIGHTCOMMENT(strip(yytext+2,yytext+yyleng));
    }


.  std::cout << "Lexer Error: " << yytext << std::endl; std::exit(1);

%%
