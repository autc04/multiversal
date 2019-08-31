mkdir -p defs
mkdir -p out
for x in "$1"/src/include/*.h;
    do ./build/ParseExecutorHeaders < $x > defs/`basename -s .h "$x"`.yaml;
done