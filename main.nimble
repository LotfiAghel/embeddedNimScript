# Package

version       = "0.1.0"
author        = "lotfi aghel "
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = ""
bin           = @["test"]
backend             = "c"

# Dependencies

requires "nim >= 0.20.2"
requires "constructor"
requires "ws"
requires "compiler"