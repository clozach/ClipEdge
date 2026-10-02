build:
    ./tools/build.sh

test:
    ./tools/test.sh

install: build
    ./tools/install.sh

run:
    open "$HOME/Applications/ClipEdge.app"

demo: build
    open .build/ClipEdge.app --args --demo

watch:
    node tools/watch.mjs
