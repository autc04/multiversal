Multiversal Interfaces
======================

Interfaces to Apple's classic Mac OS APIs (pre-Carbon, i.e. 20th century),
encoded in YAML files along with a Ruby program to convert them

1. to C/C++ headers for use with Retro68.
2. to C++ headers for use as part of Executor 2000

The API definition files were automatically generated from the header files
that were originally included with Executor 2000.
As Executor was a clean-room implementation of Mac OS and is now available
under a liberal license, the resulting header files can be used and 
redistributed freely. The translator program can still be found in the separate
`multiversal-parser` repository.

JSON Schema
-----------

A JSON schema definition for the definition files is available in the file
`multiversal.schema.json`. When it's finished, it will serve as documentation
for the API definition YAML files.

If you're using `vscode` to edit the YAML files, you can set up automatic schema
validation (= error messages and completion hints as you type) by installing the
`YAML` extension and adding

    "yaml.schemas": {
        "multiversal.schema.json": "defs/*.yaml"
    }

to your vscode workspace settings (`.vscode/settings.json`). If you have checked
out the Multiversal Interfaces as a submodule of Executor 2000 or Retro68, add the
subdirectory to the relative paths:

    "yaml.schemas": {
        "multiversal/multiversal.schema.json": "multiversal/defs/*.yaml"
    }
