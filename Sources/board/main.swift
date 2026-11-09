// The `board` executable, which is a shell over `BoardCore` and nothing else.
//
// It is this thin on purpose. An executable target's `main.swift` carries
// top-level code, so no test target can import it — every line left here is a
// line nothing can exercise. The command itself is `BoardCore.run()`.

import BoardCore

run()
