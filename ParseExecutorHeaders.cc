#include "HeaderParser.hpp"
#include <iostream>
#include <regex>
#include <vector>
#include <unordered_set>
#include <stdio.h>
#include "yaml-cpp/yaml.h"

extern std::vector<YAML::Node> things;
extern std::unordered_map<std::string, int> names;


class SpecialStyle
{
    std::regex regex;
    std::function<void (YAML::Emitter&)> fun;
public:
    template<typename T>
    SpecialStyle(std::string s, T manip)
    {
        regex = std::regex(s);
        fun = [manip](YAML::Emitter& yamlout) { yamlout << manip; };
    }

    void apply(YAML::Emitter& yamlout, const std::string& path) const
    {
        if(std::regex_match(path, regex))
            fun(yamlout);
    }
};

const std::vector<SpecialStyle> specialStyles =
{
    { ".*/comment", YAML::Literal },
    { ".*/code", YAML::Literal },
    { ".*/m68k-inline", YAML::Flow },
    { ".*/m68k-inline/", YAML::Hex },
    { ".*/trap", YAML::Hex }
};

void output(YAML::Emitter& yamlout, const YAML::Node& node, std::string path)
{
    yamlout << YAML::Block;
    yamlout << YAML::Auto;
    yamlout << YAML::Dec;
    for(const auto& s : specialStyles)
        s.apply(yamlout, path);

    if(node.IsSequence())
    {
        yamlout << YAML::BeginSeq;

        for(const auto& x : node)
            output(yamlout, x, path + "/");

        yamlout << YAML::EndSeq;
    }
    else if(node.IsMap())
    {
        yamlout << YAML::BeginMap;
        for(const auto& entry : node)
        {
            const auto& key = entry.first;
            const auto& value = entry.second;
            yamlout << key;
            output(yamlout, value, path + "/" + key.as<std::string>());
        }
        yamlout << YAML::EndMap;
    }
    else
    {
        YAML::Node n = node;
        for(const auto& s : specialStyles)
            s.apply(yamlout, path);
        
        std::string scalar = n.Scalar();

        if(scalar == "on" || scalar == "off")
            yamlout << YAML::DoubleQuoted;

        /*char *endptr;
        std::string scalar = n.Scalar();
        long long parsed = std::strtoll(scalar.c_str(), &endptr, 0);
        if(!scalar.empty() && !*endptr)
        {
            yamlout << parsed;
        }
        else*/
            yamlout << n;

        yamlout << YAML::Auto;
    }
    
}

extern FILE *yyin;

int main(int argc, char *argv[])
{
    YAML::Node override;
    bool haveOverride = false;
    try
    {
        override = YAML::LoadFile(argv[2]);
        haveOverride = true;
    }
    catch(YAML::BadFile)
    {
    }

    yyin = fopen(argv[1], "r");
    yy::HeaderParser parser;

    parser.parse();
    YAML::Emitter yamlout;


    std::unordered_map<std::string, std::vector<int>> overrideMap;
    std::unordered_set<int> usedOverrides;

    if(haveOverride)
    {
        int index = 0;
        for(const auto& thing : override)
        {
            std::string name;
            for(auto n : thing)
            {
                if(n.second.IsMap() && n.second["name"])
                    name = n.second["name"].as<std::string>();
            }
            if(!name.empty())
                overrideMap[name].push_back(index);
                        
            index++;
        }
    }

    yamlout << YAML::BeginSeq;
    bool first = true;
    for(const auto& thing : things)
    {
        std::string name;
        for(auto n : thing)
        {
            if(n.second.IsMap() && n.second["name"])
                name = n.second["name"].as<std::string>();
        }
        if(!first)
            yamlout << YAML::Newline << YAML::Newline << YAML::Comment("####") << YAML::Newline;
        first = false;

        if(!name.empty())
        {
            if(auto p = overrideMap.find(name); p != overrideMap.end())
            {
                for(int idx : p->second)
                {
                    output(yamlout, override[idx], "");
                    usedOverrides.insert(idx);
                }
                continue;
            }
        }

        output(yamlout, thing, "");
    }

    if(haveOverride)
    {
        int index = 0;
        for(const auto& thing : override)
        {
            if(usedOverrides.find(index++) != usedOverrides.end())
                continue;
            yamlout << YAML::Newline << YAML::Newline << YAML::Comment("####") << YAML::Newline;
            output(yamlout, thing, "");
        }
    }
    yamlout << YAML::EndSeq;

    std::cout << yamlout.c_str() << std::endl;


    return 0;
}