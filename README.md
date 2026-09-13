# NvimToREPLColor.jl

Julia 1.13's REPL now [performs syntax highlighting](https://julialang.org/blog/2026/09/julia-1.13-highlights/#syntax_highlighting), and [lets you customise it](https://docs.julialang.org/en/v1/stdlib/REPL/#Syntax-Highlighting).
This is really cool!

What could be even cooler?
Well, loading your existing colorscheme from your favourite editor, which is of course Neovim!
(emacs heathens begone)

This package lets you do just that.
Note that this is **mostly vibe-coded** with Fable 5.1.
(But this README is written by hand!)

Install with:

```julia
] app dev https://github.com/penelopeysm/NvimToREPLColor.jl
```

Then run this from your shell with:

```julia
nvim2juliarepl
```

It will run Neovim to find out what colour each highlight group is set to in your configuration, and generate the appropriate TOML file so that you can use it in your REPL.
You can use `nvim2juliarepl -h` to see all options.

**Note:** Neovim, especially with tree-sitter installed, has many more syntax highlighting groups than Julia's REPL.
For example, tree-sitter will define extra syntax groups for things like built-in types, etc., but there is no way to identify and highlight these specifically in the REPL.
So this is really a best-effort attempt to reproduce your colorscheme.
It won't be perfect.
However, it should be good enough for a first pass.
You can always tweak the generated TOML yourself if you want.
Improvements to this are very welcome!

## Examples

In the screenshot below, the left side is my Neovim, and the right side is the Julia REPL.

<img width="1467" height="425" alt="comparison" src="https://github.com/user-attachments/assets/174431a3-e877-4781-ae5f-cecf76345206" />

(If you're wondering what my colorscheme is, it's [mostly Edge with some personal modifications that I like](https://github.com/penelopeysm/edge).)

And here is an example of [Catppuccin Latte](https://catppuccin.com/):

<img width="1467" height="422" alt="comparison-latte" src="https://github.com/user-attachments/assets/25dd9f76-ad11-4080-b74a-c975ef0eaa3c" />

Here is the code in the example if you want to use it for your own side-by-side comparison:

```julia
begin
    # comment: keywords, funcdef, typedec, operators
    function foo(x::Int, y::Float64 = 2.0)::Float64
        z = x + y            # assignment, operator
        z += 1               # opassignment
        return z >= 3 && !isnan(z)   # comparator, builtin (&&), funcall
    end
    struct Point{T <: Real}   # type, keyword
        x::T
        y::T
    end
    s = "string with \n escape and $(1 + 2)"   # string, backslash, interp
    c = 'a'                    # char, char_delim
    r = r"^\d+$"               # regex
    cmd = `ls -la`             # cmd, cmd_delim
    sym = :symbol              # symbol
    @time sum([1, 2, 3])       # macro, funcall, number, brackets
    xs .+ 1                    # broadcast
    t = true; n = nothing      # bool, singleton_identifier
    d = Dict("a" => 1, "b" => 2.5e3)   # parentheses, curlies, number
    f = [(i, j) for i in 1:3, j in 1:2 if i != j]   # rainbow, comparator
end
```
