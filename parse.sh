mkdir -p defs
mkdir -p out
for x in "$1"/src/include/*.h; do
    name=`basename -s .h "$x"`
    if [ "$name" = "ExMacTypes" ]; then
        name=MacTypes
    fi
    echo $name
    ./build/ParseExecutorHeaders $x overrides/$name.yaml > defs/$name.yaml;
done