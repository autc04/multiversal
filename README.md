Multiversal Interfaces
======================

Interfaces to Apple's classic MacOS APIs (pre-Carbon, i.e. 20th century),
encoded in YAML files along with a ruby program to convert them to C/C++
headers for use with Retro68.

The API definition files are generated from the header files in Executor 2000
by the the translator program in the separate `multiversal-parser` repository.

As Executor was a clean-room implementation of MacOS and is now available
under a liberal license, the resulting header files can be used and 
edistributed freely.

Also includes an option to generate replacements for the header files that
are part of executor. In the future, 