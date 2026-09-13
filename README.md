# NvimToREPLColor.jl

Julia 1.13's REPL now performs syntax highlighting, and lets you customise it. This is really cool!

What could be even cooler? Well, loading your existing colorscheme from your favourite editor, which is of course Neovim! (emacs heathens begone)

This (admittedly vibe-coded) package lets you do just that.
It will run Neovim to find out what colour each highlight group is set to in your configuration, and generate the appropriate TOML file so that you can use it in your REPL.

Install with:

```julia
] app dev https://github.com/penelopeysm/NvimToREPLColor.jl
```

Then run this from your shell with:

```julia
nvim2juliarepl
```

You can use `nvim2juliarepl -h` to see all options.

**Note:** Neovim has more syntax highlighting groups than Julia's REPL, so this is really a best-effort attempt to reproduce your colorscheme.
It won't be perfect, especially if you are using treesitter's highlighting as well.
However, it should be good enough for a first pass!

Improvements to this are very welcome!
