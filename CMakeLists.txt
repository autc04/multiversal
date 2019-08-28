cmake_minimum_required(VERSION 3.13)
project(MultiversalHeaders)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED 17)

set(CMAKE_PROGRAM_PATH ${CMAKE_PROGRAM_PATH} "/usr/local/opt/bison/bin")
find_package(BISON 3.0.2)
find_package(FLEX)

bison_target(HeaderParser HeaderParser.yy ${CMAKE_CURRENT_BINARY_DIR}/HeaderParser.cpp)
flex_target(HeaderLexer HeaderLexer.l  ${CMAKE_CURRENT_BINARY_DIR}/HeaderLexer.cc)
add_flex_bison_dependency(HeaderLexer HeaderParser)

add_executable(ParseExecutorHeaders ParseExecutorHeaders.cc HeaderLexer.cc HeaderParser.cpp)
target_include_directories(ParseExecutorHeaders PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(ParseExecutorHeaders yaml-cpp)

set(YAML_CPP_BUILD_TESTS NO)
set(YAML_CPP_BUILD_TOOLS NO)
add_subdirectory(yaml-cpp)
