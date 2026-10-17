-module(extraction_ffi).
-export([shout/1]).

shout(Text) -> string:uppercase(Text).
