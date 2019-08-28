#include "HeaderParser.hpp"
#include <iostream>
#include "yaml-cpp/yaml.h"

extern std::vector<YAML::Node> things;
extern std::unordered_map<std::string, int> names;

int main()
{
    yy::HeaderParser parser;

    parser.parse();
    YAML::Emitter yamlout;

    yamlout << YAML::BeginSeq;
    bool first = true;
    for(const auto& n : things)
    {
        if(!first)
            yamlout << YAML::Newline << YAML::Newline << YAML::Comment("####") << YAML::Newline;
        first = false;
        yamlout << n;
    }
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