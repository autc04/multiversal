#include "HeaderParser.hpp"
#include <iostream>
#include "yaml-cpp/yaml.h"

extern 	YAML::Emitter yamlout;

int main()
{
    yy::HeaderParser parser;
    
    yamlout << YAML::BeginSeq;
    parser.parse();
    yamlout << YAML::EndSeq;

    std::cout << yamlout.c_str() << std::endl;

    /*yy::HeaderParser::symbol_type token;
    extern const char* yytext;
    extern int yyleng;

    for(;;)
    {
        auto tok = yylex();
        if(!tok.token())
            break;
        std::cout << tok.token() << ": " << std::string(yytext, yytext+yyleng) << "\n";
    }*/

   /* YAML::Emitter out;
    out << YAML::BeginSeq;
    out << "foo" << "bar" << "baz";

    YAML::Node node;
    node["quuxbar"] = "quux";
    node["quuxbaz"] = "quux";
    
    YAML::Node node2 = {};//YAML::Node(YAML::NodeType::Sequence);
    //node[0] = "a";
    node2.push_back("a");
    node2.push_back("b");
    
    node["quux"] = node2;

    YAML::Node node3 = node2;
    node2 = {};

    node3.push_back("c");

    out << node;

    out << YAML::EndSeq;

    std::cout << out.c_str() << std::endl;*/


    return 0;
}