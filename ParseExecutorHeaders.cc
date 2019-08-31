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


    return 0;
}